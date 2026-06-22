import SwiftUI
import AVFoundation
import os

@MainActor
public final class VoiceTransformViewModel: NSObject, ObservableObject {
    enum Step {
        case persona
        case record
        case transforming
        case review
    }

    private struct PreparedClip {
        let audioURL: URL
        let videoURL: URL
    }

    @Published var step: Step = .persona
    @Published var selectedPersona: VoicePersona = VoicePersona.all[0]
    @Published var isRecording = false
    @Published var seconds: TimeInterval = 0
    @Published var waveformBars: [Double] = Array(repeating: 0.16, count: 54)
    @Published var statusLine = "Tap to record"
    @Published var playProgress: Double = 0
    @Published var isPlaying = false
    @Published var isSending = false

    public var onDismiss: (() -> Void)?
    public var onInsert: ((URL, @escaping (Error?) -> Void) -> Void)?

    private let log = Logger(subsystem: "com.aaron.voiceMixer", category: "flow")
    private let service: ConvertService
    private let recorder: AudioRecorder
    private var conversionTask: Task<Void, Never>?
    /// Identity of the in-flight conversion; stale tasks/waiters check it and no-op.
    private var conversionToken: UUID?
    private var recordTimer: Timer?
    private var levelTimer: Timer?
    private var statusTimer: Timer?
    private var playbackTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var preparedClip: PreparedClip?
    /// Last successful recording, retained only after a transient conversion
    /// failure so the user can retry without re-recording.
    private var lastRecordedURL: URL?
    private var statusIndex = 0

    private let transformStatuses = [
        "Uploading your voice…",
        "Analyzing tone & cadence…",
        "Applying voice model…",
        "Rendering new audio…",
    ]

    public init(service: ConvertService, recorder: AudioRecorder = AudioRecorder()) {
        self.service = service
        self.recorder = recorder
        super.init()
        recorder.didReachMaxDuration = { [weak self] recordedURL in
            Task { @MainActor in
                self?.recordingReachedMaxDuration(recordedURL)
            }
        }
    }

    deinit {
        conversionTask?.cancel()
        recordTimer?.invalidate()
        levelTimer?.invalidate()
        statusTimer?.invalidate()
        playbackTimer?.invalidate()
        audioPlayer?.stop()
    }

    public func cancel() {
        stopPlayback()
        cancelConversion()
        if isRecording {
            _ = recorder.stopRecording()
        }
        onDismiss?()
    }

    /// Collapsing to compact preserves an in-flight/ready conversion; only idle steps reset.
    public func handlePresentationCollapse() {
        switch step {
        case .transforming, .review:
            return
        case .persona, .record:
            goBack()
        }
    }

    /// On resign (dim/lock/app-switch) never cancel an in-flight conversion. Don't
    /// deactivate the session under an active recording — finalize the take instead.
    public func handleResignActivePreservingConversion() {
        if isRecording {
            stopAndConvert()
        } else if isPlaying {
            stopPlayback()
        }
    }

    func nextFromPersona() {
        step = .record
        statusLine = "Tap to record"
        seedWaveform()
    }

    public func goBack() {
        stopPlayback()
        lastRecordedURL = nil
        switch step {
        case .persona:
            cancel()
        case .record:
            leaveRecordStep()
            step = .persona
        case .transforming:
            cancelConversion()
            returnToRecordStep()
        case .review:
            preparedClip = nil
            returnToRecordStep()
        }
    }

    private func leaveRecordStep() {
        if isRecording {
            _ = recorder.stopRecording()
            stopRecordingTimers()
            isRecording = false
        }
    }

    private func returnToRecordStep() {
        step = .record
        statusLine = "Tap to record"
    }

    func recordButtonTapped() {
        if isRecording {
            stopAndConvert()
        } else if let retryURL = lastRecordedURL {
            // Retry the previous recording after a transient failure.
            lastRecordedURL = nil
            startConversion(from: retryURL)
        } else {
            beginRecording()
        }
    }

    func redo() {
        stopPlayback()
        preparedClip = nil
        lastRecordedURL = nil
        step = .record
        statusLine = "Tap to record"
        seedWaveform()
    }

    func togglePlayback() {
        guard let audioURL = preparedClip?.audioURL else { return }
        if isPlaying {
            stopPlayback(resetProgress: true)
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: audioURL)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            isPlaying = true
            playProgress = 0
            startPlaybackTimer()
        } catch {
            log.error("PLAYBACK: failed \(error.localizedDescription)")
            statusLine = "Preview failed"
        }
    }

    func send() {
        guard let videoURL = preparedClip?.videoURL, let onInsert else {
            statusLine = "Nothing to send"
            return
        }

        stopPlayback()
        isSending = true
        statusLine = "Inserting…"
        onInsert(videoURL) { [weak self] error in
            Task { @MainActor in
                self?.handleInsertCompletion(error)
            }
        }
    }

    private func handleInsertCompletion(_ error: Error?) {
        isSending = false
        if let error {
            handleInsertFailure(error)
        } else {
            handleInsertSuccess()
        }
    }

    private func handleInsertFailure(_ error: Error) {
        log.error("SEND: insertAttachment error \(error.localizedDescription)")
        statusLine = "Insert failed: \(error.localizedDescription)"
    }

    private func handleInsertSuccess() {
        log.info("SEND: insertAttachment completed")
        statusLine = "Added to message — tap Send in Messages"
        preparedClip = nil
        step = .persona
        seedWaveform()
        onDismiss?()
    }

    private func beginRecording() {
        preparedClip = nil
        stopPlayback()

        switch AudioRecorder.micPermission {
        case .granted:
            startRecordingFlow()
        case .denied, .undetermined:
            statusLine = "Open the voiceMix app to enable microphone access"
        }
    }

    private func startRecordingFlow() {
        do {
            try recorder.startRecording()
            log.info("REC: startRecording success")
            seconds = 0
            isRecording = true
            statusLine = "Tap to stop"
            waveformBars = Array(repeating: 0.10, count: 54)
            startRecordingTimers()
        } catch {
            log.error("REC: startRecording threw \(error.localizedDescription)")
            statusLine = "Couldn't start recording"
        }
    }

    private func stopAndConvert() {
        // Read the wall-clock backstop before stopping clears the start time:
        // if the run-loop cap timer fired late (e.g. extension suspended), the
        // clip may have run past the cap and is enforced downstream by size.
        if recorder.hasExceededMaxDuration {
            log.info("REC: stop with clip past max duration (timer delivered late)")
        }
        guard let recordedURL = recorder.stopRecording() else {
            stopRecordingTimers()
            isRecording = false
            statusLine = "Recording failed"
            return
        }
        startConversion(from: recordedURL)
    }

    private func recordingReachedMaxDuration(_ recordedURL: URL?) {
        guard let recordedURL else {
            stopRecordingTimers()
            isRecording = false
            statusLine = "Recording failed"
            return
        }
        startConversion(from: recordedURL)
    }

    /// Conservative client-side ceiling on the recorded upload, mirroring the
    /// backend's 10MB convert limit (`LiveConvertService.maxUploadBytes`). At
    /// 120s the mp4 encode is the app's #1 crash path, so we fail fast here
    /// rather than attempt a doomed upload + encode for an oversized take.
    private static let maxRecordingBytes = 10 * 1024 * 1024

    private func startConversion(from recordedURL: URL) {
        stopRecordingTimers()
        isRecording = false

        // Fail fast on an oversized take before the upload + heavy mp4 encode.
        if let size = try? FileManager.default.attributesOfItem(atPath: recordedURL.path)[.size] as? Int,
           size > Self.maxRecordingBytes {
            log.error("CONVERT: recording too large \(size) bytes > \(Self.maxRecordingBytes)")
            handleConversionFailure(ConvertServiceError.fileTooLarge(bytes: size), recordedURL: recordedURL)
            return
        }

        step = .transforming
        statusIndex = 0
        statusLine = transformStatuses[0]
        startStatusTimer()

        let token = UUID()
        conversionToken = token

        conversionTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let clip = try await self.prepareClip(from: recordedURL)
                try Task.checkCancellation()
                guard self.conversionToken == token else { return }
                self.finishConversion(with: clip)
            } catch is CancellationError {
                guard self.conversionToken == token else { return }
                self.handleConversionCancellation()
            } catch {
                guard self.conversionToken == token else { return }
                self.log.error("CONVERT: failed \(String(describing: error))")
                self.stopStatusTimer()
                self.handleConversionFailure(error, recordedURL: recordedURL)
                self.conversionTask = nil
                self.conversionToken = nil
            }
        }
        conversionTask = task
        Self.holdBackgroundActivity(for: task, token: token, isCurrent: { [weak self] in
            await MainActor.run { self?.conversionToken == token }
        })
    }

    /// Best-effort background window for the encode if the screen dims/locks
    /// (`performExpiringActivity` is the extension-legal `beginBackgroundTask`).
    /// Cancels the task on expiry; does not prevent jetsam.
    private static func holdBackgroundActivity(for task: Task<Void, Never>,
                                              token: UUID,
                                              isCurrent: @escaping @Sendable () async -> Bool) {
        ProcessInfo.processInfo.performExpiringActivity(withReason: "voiceMix conversion") { expired in
            if expired {
                task.cancel()
                return
            }
            dispatchPrecondition(condition: .notOnQueue(.main))

            // Hold the assertion (block this background queue) until conversion ends.
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                guard await isCurrent() else { done.signal(); return }
                _ = await task.value
                done.signal()
            }
            _ = done.wait(timeout: .now() + 180)  // failsafe against a hung encode
        }
    }

    private func finishConversion(with clip: PreparedClip) {
        preparedClip = clip
        stopStatusTimer()
        step = .review
        statusLine = "Transformed · \(formattedDuration)"
        conversionTask = nil
        conversionToken = nil
    }

    private func handleConversionCancellation() {
        stopStatusTimer()
        statusLine = "Tap to record"
        conversionTask = nil
        conversionToken = nil
    }

    /// Maps a `ConvertServiceError` to distinct user-visible copy. On transient
    /// failures (502 / network) we KEEP the selected persona and the recorded
    /// clip so the user can retry by tapping record again, rather than being
    /// dropped silently back to an empty record screen.
    private func handleConversionFailure(_ error: Error, recordedURL: URL) {
        let transient: Bool
        switch error {
        case ConvertServiceError.httpStatus(404, _):
            statusLine = "Voice unavailable — try another"
            transient = false
        case ConvertServiceError.httpStatus(413, _),
             ConvertServiceError.httpStatus(422, _),
             ConvertServiceError.fileTooLarge:
            statusLine = "Recording too long or large"
            transient = false
        case ConvertServiceError.httpStatus(502, _),
             ConvertServiceError.httpStatus(503, _):
            statusLine = "Voice engine busy — tap to retry"
            transient = true
        case ConvertServiceError.network:
            statusLine = "No connection — tap to retry"
            transient = true
        case ConvertServiceError.httpStatus(let code, _):
            statusLine = "Convert failed (\(code))"
            transient = false
        default:
            statusLine = "Convert failed"
            transient = false
        }

        // Always return to the record screen so the user can act on the status.
        // The persona is never reset here. On transient failures we keep the
        // last recording around so a retry doesn't require re-recording.
        lastRecordedURL = transient ? recordedURL : nil
        step = .record
    }

    private func prepareClip(from recordedURL: URL) async throws -> PreparedClip {
        let response = try await service.convert(audioURL: recordedURL,
                                                 voiceId: selectedPersona.voiceId,
                                                 engine: selectedPersona.engine)
        try Task.checkCancellation()
        guard let audioUrl = URL(string: response.audioUrl) else {
            throw ConvertServiceError.invalidAudioURL
        }
        let convertedAudioURL = try await service.fetchAudio(audioUrl)
        try Task.checkCancellation()
        let renderer = WaveformVideoRenderer()
        await updatePreviewWaveform(using: renderer, audioURL: convertedAudioURL)
        let videoURL = try await renderer.makeVideo(fromAudio: convertedAudioURL,
                                                    personaName: selectedPersona.name)
        return PreparedClip(audioURL: convertedAudioURL, videoURL: videoURL)
    }

    private func updatePreviewWaveform(using renderer: WaveformVideoRenderer, audioURL: URL) async {
        let sentAudioBars = await renderer.displayBars(fromAudio: audioURL)
        if !sentAudioBars.isEmpty {
            waveformBars = sentAudioBars
        }
    }

    private func cancelConversion() {
        conversionTask?.cancel()
        conversionTask = nil
        // Invalidate the identity so the cancelled task (and its background
        // waiter) can't mutate state for this superseded conversion.
        conversionToken = nil
        stopStatusTimer()
    }

    private func scheduledMainActorTimer(interval: TimeInterval,
                                         tick: @escaping @MainActor (VoiceTransformViewModel) -> Void) -> Timer {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                tick(self)
            }
        }
    }

    private func startRecordingTimers() {
        recordTimer?.invalidate()
        levelTimer?.invalidate()

        recordTimer = scheduledMainActorTimer(interval: 0.1) { model in
            guard model.isRecording else { return }
            model.seconds += 0.1
        }

        levelTimer = scheduledMainActorTimer(interval: 0.1) { model in
            guard model.isRecording else { return }
            model.pushLiveLevel(model.recorder.normalizedLevel())
        }
    }

    private func stopRecordingTimers() {
        recordTimer?.invalidate()
        levelTimer?.invalidate()
        recordTimer = nil
        levelTimer = nil
    }

    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = scheduledMainActorTimer(interval: 0.85) { model in
            model.statusIndex = min(model.statusIndex + 1, model.transformStatuses.count - 1)
            model.statusLine = model.transformStatuses[model.statusIndex]
        }
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = scheduledMainActorTimer(interval: 1.0 / 20.0) { model in
            guard let player = model.audioPlayer else { return }
            if player.duration > 0 {
                model.playProgress = min(1, player.currentTime / player.duration)
            }
            if !player.isPlaying {
                model.audioPlayerDidFinishPlaying(player, successfully: true)
            }
        }
    }

    private func stopPlayback(resetProgress: Bool = false) {
        audioPlayer?.stop()
        audioPlayer = nil
        playbackTimer?.invalidate()
        playbackTimer = nil
        isPlaying = false
        if resetProgress {
            playProgress = 0
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func pushLiveLevel(_ level: Double) {
        let animated = min(1, max(0.05, level + Double.random(in: -0.025...0.035)))
        waveformBars.append(animated)
        if waveformBars.count > 54 {
            waveformBars.removeFirst(waveformBars.count - 54)
        }
    }

    private func seedWaveform() {
        waveformBars = (0..<54).map { index in
            let wave = abs(sin(Double(index) * 0.52) * cos(Double(index) * 0.21))
            return max(0.08, 0.22 + wave * 0.48)
        }
    }

    var formattedDuration: String {
        let total = max(1, Int(seconds.rounded()))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

extension VoiceTransformViewModel: AVAudioPlayerDelegate {
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            playbackTimer?.invalidate()
            playbackTimer = nil
            audioPlayer = nil
            isPlaying = false
            playProgress = 1
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !isPlaying {
                playProgress = 0
            }
        }
    }
}

public struct VoiceTransformView: View {
    @ObservedObject var model: VoiceTransformViewModel
    @State private var personaScrollPositionID: String?
    @State private var personaAllowsMultiItemScroll = false
    @State private var personaScrollUnlockToken = UUID()

    public init(model: VoiceTransformViewModel) {
        self.model = model
        _personaScrollPositionID = State(initialValue: model.selectedPersona.id)
    }

    public var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x161619), Color(hex: 0x0C0C0E)],
                           startPoint: .top,
                           endPoint: .bottom)
                .ignoresSafeArea()

            Circle()
                .fill(model.selectedPersona.color2.opacity(0.22))
                .blur(radius: 32)
                .frame(width: 300, height: 180)
                .offset(y: -230)

            VStack(spacing: 0) {
                navBar
                    .layoutPriority(1)
                currentPage
                    .animation(.snappy(duration: 0.42), value: pageIndex)
            }
            .padding(.top, 10)
        }
        .preferredColorScheme(.dark)
    }

    private var pageIndex: Int {
        switch model.step {
        case .persona: return 0
        case .record, .transforming: return 1
        case .review: return 2
        }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch model.step {
        case .persona:
            personaPage
        case .record, .transforming:
            recordPage
        case .review:
            reviewPage
        }
    }

    private var title: String {
        switch model.step {
        case .persona: return "Choose a Voice"
        case .record: return model.selectedPersona.name
        case .transforming: return "Transforming"
        case .review: return "Preview"
        }
    }

    private var navBar: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            HStack {
                leftNav
                Spacer()
                rightNav
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 52)
    }

    @ViewBuilder
    private var leftNav: some View {
        switch model.step {
        case .persona:
            Button("Cancel") { model.cancel() }
                .font(.system(size: 17))
                .foregroundStyle(Color(hex: 0x0A84FF))
        case .record, .review:
            Button { model.goBack() } label: {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 17))
            }
            .foregroundStyle(Color(hex: 0x0A84FF))
        case .transforming:
            EmptyView()
        }
    }

    @ViewBuilder
    private var rightNav: some View {
        switch model.step {
        case .persona:
            Button("Next") { model.nextFromPersona() }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hex: 0xFF9500))
        case .review:
            Button("Send") { model.send() }
                .disabled(model.isSending)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(model.isSending ? .white.opacity(0.28) : Color(hex: 0x0A84FF))
        case .record, .transforming:
            EmptyView()
        }
    }

    private var personaPage: some View {
        VStack(spacing: 14) {
            personaCarousel

            HStack(spacing: 5) {
                ForEach(VoicePersona.all) { persona in
                    Capsule()
                        .fill(model.selectedPersona == persona ? model.selectedPersona.color2 : .white.opacity(0.22))
                        .frame(width: model.selectedPersona == persona ? 16 : 6, height: 6)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.vertical, 8)
    }

    private var personaCarousel: some View {
        GeometryReader { geo in
            let cardWidth: CGFloat = 146
            let sidePadding = max(0, (geo.size.width - cardWidth) / 2)
            if #available(iOS 17.0, *) {
                snapCarousel(cardWidth: cardWidth, sidePadding: sidePadding)
            } else {
                legacyCarousel(cardWidth: cardWidth, sidePadding: sidePadding)
            }
        }
        .frame(height: 188)
    }

    @available(iOS 17.0, *)
    private func snapCarousel(cardWidth: CGFloat, sidePadding: CGFloat) -> some View {
        let itemSpacing: CGFloat = 18
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: itemSpacing) {
                    ForEach(VoicePersona.all) { persona in
                        personaButton(persona) {
                            let unlockToken = UUID()
                            personaScrollUnlockToken = unlockToken
                            personaAllowsMultiItemScroll = true
                            withAnimation(.snappy(duration: 0.28)) {
                                personaScrollPositionID = persona.id
                                model.selectedPersona = persona
                                proxy.scrollTo(persona.id, anchor: .center)
                            }
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 420_000_000)
                                if personaScrollUnlockToken == unlockToken {
                                    personaAllowsMultiItemScroll = false
                                }
                            }
                        }
                        .frame(width: cardWidth)
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            let distance = min(abs(phase.value), 1)
                            return content
                                .scaleEffect(1 - distance * 0.16)
                                .opacity(1 - distance * 0.46)
                        }
                        .id(persona.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, sidePadding)
                .padding(.vertical, 18)
            }
            .scrollContentBackground(.hidden)
            .scrollTargetBehavior(PersonaCarouselCenterTargetBehavior(itemStride: cardWidth + itemSpacing,
                                                                      limitsToSingleStep: !personaAllowsMultiItemScroll))
            .scrollPosition(id: Binding(
                get: { personaScrollPositionID },
                set: { newID in
                    personaScrollPositionID = newID
                    if let newID,
                       let persona = VoicePersona.all.first(where: { $0.id == newID }) {
                        model.selectedPersona = persona
                    }
                }
            ), anchor: .center)
            .onAppear {
                let unlockToken = UUID()
                personaScrollUnlockToken = unlockToken
                personaAllowsMultiItemScroll = true
                personaScrollPositionID = model.selectedPersona.id
                DispatchQueue.main.async {
                    proxy.scrollTo(model.selectedPersona.id, anchor: .center)
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 420_000_000)
                    if personaScrollUnlockToken == unlockToken {
                        personaAllowsMultiItemScroll = false
                    }
                }
            }
        }
    }

    private func legacyCarousel(cardWidth: CGFloat, sidePadding: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(VoicePersona.all) { persona in
                        personaButton(persona)
                            .frame(width: cardWidth)
                            .scaleEffect(model.selectedPersona == persona ? 1 : 0.84)
                            .opacity(model.selectedPersona == persona ? 1 : 0.54)
                            .animation(.easeOut(duration: 0.25), value: model.selectedPersona)
                            .id(persona.id)
                    }
                }
                .padding(.horizontal, sidePadding)
                .padding(.vertical, 18)
            }
            .scrollContentBackground(.hidden)
            .onAppear { proxy.scrollTo(model.selectedPersona.id, anchor: .center) }
            .onChange(of: model.selectedPersona) { _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(model.selectedPersona.id, anchor: .center)
                }
            }
        }
    }

    private func personaButton(_ persona: VoicePersona, onSelect: (() -> Void)? = nil) -> some View {
        let selected = model.selectedPersona == persona
        return Button {
            if let onSelect {
                onSelect()
            } else {
                withAnimation(.snappy(duration: 0.28)) {
                    personaScrollPositionID = persona.id
                    model.selectedPersona = persona
                }
            }
        } label: {
            VStack(spacing: 9) {
                PersonaAvatarView(persona: persona,
                                  size: selected ? 112 : 88,
                                  selected: selected)
                    .frame(width: 112, height: 112)

                Text(persona.name)
                    .font(.system(size: selected ? 16 : 14, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? .white : .white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(width: 146, height: 150)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var recordPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            NeonWaveformView(mode: recordWaveformMode,
                             bars: model.waveformBars,
                             progress: 0)
                .frame(height: 92)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)

            statusView
                .frame(height: 24)
                .padding(.bottom, 4)

            recordControl
                .frame(height: 72)

            Text(model.isRecording ? "Tap to stop" : model.step == .transforming ? "" : "Tap to record")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.35))
                .frame(height: 14)
                .padding(.top, 2)
                .padding(.bottom, 6)
        }
    }

    private var recordWaveformMode: NeonWaveformView.Mode {
        if model.step == .transforming { return .transforming }
        if model.isRecording { return .recording }
        return .ready
    }

    private var statusView: some View {
        Group {
            if model.isRecording {
                HStack(spacing: 9) {
                    Circle()
                        .fill(Color(hex: 0xFF9500))
                        .frame(width: 9, height: 9)
                    Text(model.formattedDuration)
                        .font(.system(size: 19, weight: .semibold, design: .default).monospacedDigit())
                }
                .foregroundStyle(.white)
            } else if model.step == .transforming {
                Text(model.statusLine)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.70))
            } else {
                Text(model.statusLine)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
    }

    @ViewBuilder
    private var recordControl: some View {
        if model.step == .transforming {
            transformingControl
        } else if model.isRecording {
            stopRecordingButton
        } else {
            startRecordingButton
        }
    }

    private var transformingControl: some View {
        ProgressView()
            .tint(model.selectedPersona.color2)
            .scaleEffect(1.45)
    }

    private var stopRecordingButton: some View {
        Button { model.recordButtonTapped() } label: {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.50), lineWidth: 4)
                    .frame(width: 68, height: 68)
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(hex: 0xFF9500))
                    .shadow(color: Color(hex: 0xFF9500).opacity(0.70), radius: 18)
                    .frame(width: 26, height: 26)
            }
        }
        .buttonStyle(.plain)
    }

    private var startRecordingButton: some View {
        Button { model.recordButtonTapped() } label: {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.70), lineWidth: 3)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(Color(hex: 0xFF9500))
                    .shadow(color: Color(hex: 0xFF9500).opacity(0.70), radius: 24)
                    .frame(width: 54, height: 54)
            }
        }
        .buttonStyle(.plain)
    }

    private var reviewPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            NeonWaveformView(mode: model.isPlaying ? .playing : .ready,
                             bars: model.waveformBars,
                             progress: model.playProgress)
                .frame(height: 92)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)

            Text("Transformed · \(model.formattedDuration)")
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.50))
                .padding(.bottom, 8)

            HStack(spacing: 28) {
                reviewAction(label: "Redo", size: 54, action: { model.redo() }) {
                    Circle()
                        .fill(.white.opacity(0.10))
                        .frame(width: 54, height: 54)
                        .overlay {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.white.opacity(0.70))
                        }
                }

                reviewAction(label: model.isPlaying ? "Playing" : "Preview",
                             size: 80,
                             action: { model.togglePlayback() }) {
                    Circle()
                        .fill(LinearGradient(colors: [model.selectedPersona.color1, model.selectedPersona.color2],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                        .shadow(color: model.selectedPersona.color2.opacity(0.55), radius: 28)
                        .frame(width: 80, height: 80)
                        .overlay {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: model.isPlaying ? 0 : 2)
                        }
                }

                Color.clear.frame(width: 54)
            }
            .frame(height: 102)
            .padding(.bottom, 6)
        }
    }

    private func reviewAction<Icon: View>(label: String,
                                          size: CGFloat,
                                          action: @escaping () -> Void,
                                          @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 10) {
            Button(action: action) {
                icon()
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.40))
        }
        .frame(width: size)
    }

}

@available(iOS 17.0, *)
private struct PersonaCarouselCenterTargetBehavior: ScrollTargetBehavior {
    let itemStride: CGFloat
    let limitsToSingleStep: Bool

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard itemStride > 0 else { return }
        guard limitsToSingleStep else { return }

        let proposedIndex = (target.rect.minX / itemStride).rounded()
        let currentIndex = (context.originalTarget.rect.minX / itemStride).rounded()
        let targetIndex = max(currentIndex - 1, min(currentIndex + 1, proposedIndex))

        let maxOffset = max(0, context.contentSize.width - context.containerSize.width)
        let maxIndex = (maxOffset / itemStride).rounded()
        let centeredOffset = max(0, min(targetIndex, maxIndex)) * itemStride
        target.rect.origin.x = max(0, min(centeredOffset, maxOffset))
    }
}

struct PersonaAvatarView: View {
    let persona: VoicePersona
    let size: CGFloat
    let selected: Bool

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [persona.color1, persona.color2],
                                 startPoint: .topLeading,
                                 endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay { avatarContent }
            .shadow(color: selected ? persona.color2.opacity(0.65) : .black.opacity(0.40),
                    radius: selected ? 20 : 8,
                    y: selected ? 0 : 4)
    }

    /// Prefers the persona's cartoon art; falls back to the SF Symbol placeholder when the
    /// artwork hasn't shipped yet — so every slot renders sensibly either way.
    @ViewBuilder
    private var avatarContent: some View {
        if let image = personaImage {
            // Inset inside the gradient so the colored ring stays visible around the art.
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size * 0.82, height: size * 0.82)
                .clipShape(Circle())
                .accessibilityLabel(persona.name)
        } else {
            Image(systemName: persona.placeholderSymbol)
                .font(.system(size: size * 0.40, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityLabel(persona.name)
        }
    }

    /// The persona's cartoon from the (extension) app bundle, or nil when no asset is present.
    private var personaImage: UIImage? {
        guard let imageName = persona.imageName else { return nil }
        return UIImage(named: imageName)
    }
}

struct NeonWaveformView: View {
    enum Mode {
        case recording
        case transforming
        case ready
        case playing
    }

    let mode: Mode
    let bars: [Double]
    let progress: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private struct BarStyle {
        let amplitude: Double
        let color: Color
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let count = 54
        let gap = size.width / CGFloat(count)
        let barWidth = max(2.5, gap * 0.42)
        let midY = size.height / 2
        let maxHalfHeight = size.height * 0.48

        for index in 0..<count {
            let source = index < bars.count ? bars[index] : fallbackBar(index)
            let style = barStyle(index: index, source: source, time: time)
            let path = barPath(index: index,
                               amplitude: style.amplitude,
                               gap: gap,
                               barWidth: barWidth,
                               midY: midY,
                               maxHalfHeight: maxHalfHeight)
            context.fill(path, with: .color(style.color))
        }
    }

    private func barStyle(index: Int, source: Double, time: TimeInterval) -> BarStyle {
        let t = Double(index) / Double(54)
        let shimmer = (sin(Double(index) * 0.5 - time * 6) * 0.5) + 0.5

        switch mode {
        case .recording:
            return BarStyle(amplitude: source,
                            color: Self.rainbowColor(t, lightness: 0.62, saturation: 1, alpha: 1))
        case .transforming:
            let drift = (t + time * 0.15).truncatingRemainder(dividingBy: 1)
            return BarStyle(amplitude: source * (0.35 + 0.65 * shimmer),
                            color: Self.rainbowColor(drift, lightness: 0.60 + shimmer * 0.08, saturation: 1, alpha: 1))
        case .ready:
            return BarStyle(amplitude: source,
                            color: Self.rainbowColor(t, lightness: 0.52, saturation: 0.70, alpha: 0.50))
        case .playing:
            let color = t <= progress
                ? Self.rainbowColor(t, lightness: 0.62, saturation: 1, alpha: 1)
                : .white.opacity(0.16)
            return BarStyle(amplitude: source, color: color)
        }
    }

    private func barPath(index: Int,
                         amplitude: Double,
                         gap: CGFloat,
                         barWidth: CGFloat,
                         midY: CGFloat,
                         maxHalfHeight: CGFloat) -> Path {
        let height = max(3, CGFloat(amplitude) * maxHalfHeight)
        let rect = CGRect(x: CGFloat(index) * gap + (gap - barWidth) / 2,
                          y: midY - height,
                          width: barWidth,
                          height: height * 2)
        return Path(roundedRect: rect, cornerRadius: min(barWidth / 2, 6))
    }

    private func fallbackBar(_ index: Int) -> Double {
        0.2 + 0.6 * abs(sin(Double(index) * 0.7) * cos(Double(index) * 0.31))
    }

    static func rainbowColor(_ t: Double, lightness: Double, saturation: Double, alpha: Double) -> Color {
        let hue = (140 + t * 280).truncatingRemainder(dividingBy: 360) / 360
        return Color(hue: hue, saturation: saturation, brightness: lightness, opacity: alpha)
    }
}

#Preview("Expanded") {
    VoiceTransformView(model: VoiceTransformViewModel(service: MockConvertService()))
}

// Approximates the iMessage compact panel (keyboard-height sheet at the bottom).
// Canvas can't render real Messages chrome — tune the height to match the device.
#Preview("iMessage compact") {
    ZStack(alignment: .bottom) {
        Color(white: 0.92).ignoresSafeArea()
        VoiceTransformView(model: VoiceTransformViewModel(service: MockConvertService()))
            .frame(height: 400)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

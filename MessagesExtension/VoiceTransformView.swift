import SwiftUI
import AVFoundation
import os

struct VoicePersona: Identifiable, Equatable {
    let id: String
    let name: String
    let monogram: String
    let color1: Color
    let color2: Color
    let uiColor1: UIColor
    let uiColor2: UIColor

    static let all: [VoicePersona] = [
        VoicePersona(id: "elder",
                     name: "The Elder",
                     monogram: "E",
                     color1: Color(hex: 0xF7B733),
                     color2: Color(hex: 0xFC4A1A),
                     uiColor1: UIColor(hex: 0xF7B733),
                     uiColor2: UIColor(hex: 0xFC4A1A)),
        VoicePersona(id: "aria",
                     name: "Aria",
                     monogram: "A",
                     color1: Color(hex: 0xF857A6),
                     color2: Color(hex: 0x9B5CF6),
                     uiColor1: UIColor(hex: 0xF857A6),
                     uiColor2: UIColor(hex: 0x9B5CF6)),
        VoicePersona(id: "mlk",
                     name: "M.L.K.",
                     monogram: "M",
                     color1: Color(hex: 0x36D1DC),
                     color2: Color(hex: 0x5B86E5),
                     uiColor1: UIColor(hex: 0x36D1DC),
                     uiColor2: UIColor(hex: 0x5B86E5)),
    ]
}

@MainActor
final class VoiceTransformViewModel: NSObject, ObservableObject {
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

    var onDismiss: (() -> Void)?
    var onInsert: ((URL, @escaping (Error?) -> Void) -> Void)?

    private let log = Logger(subsystem: "com.aaron.voiceMixer", category: "flow")
    private let service: ConvertService
    private let recorder: AudioRecorder
    private var conversionTask: Task<Void, Never>?
    private var recordTimer: Timer?
    private var levelTimer: Timer?
    private var statusTimer: Timer?
    private var playbackTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var preparedClip: PreparedClip?
    private var statusIndex = 0

    private let transformStatuses = [
        "Uploading your voice…",
        "Analyzing tone & cadence…",
        "Applying voice model…",
        "Rendering new audio…",
    ]

    init(service: ConvertService, recorder: AudioRecorder = AudioRecorder()) {
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

    func cancel() {
        stopPlayback()
        cancelConversion()
        if isRecording {
            _ = recorder.stopRecording()
        }
        onDismiss?()
    }

    func nextFromPersona() {
        step = .record
        statusLine = "Tap to record"
        seedWaveform()
    }

    func goBack() {
        stopPlayback()
        switch step {
        case .persona:
            cancel()
        case .record:
            if isRecording {
                _ = recorder.stopRecording()
                stopRecordingTimers()
                isRecording = false
            }
            step = .persona
        case .transforming:
            cancelConversion()
            step = .record
            statusLine = "Tap to record"
        case .review:
            preparedClip = nil
            step = .record
            statusLine = "Tap to record"
        }
    }

    func recordButtonTapped() {
        isRecording ? stopAndConvert() : beginRecording()
    }

    func redo() {
        stopPlayback()
        preparedClip = nil
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
                guard let self else { return }
                self.isSending = false
                if let error {
                    self.log.error("SEND: insertAttachment error \(error.localizedDescription)")
                    self.statusLine = "Insert failed: \(error.localizedDescription)"
                } else {
                    self.log.info("SEND: insertAttachment completed")
                    self.statusLine = "Added to message — tap Send in Messages"
                    self.preparedClip = nil
                    self.step = .persona
                    self.seedWaveform()
                    self.onDismiss?()
                }
            }
        }
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

    private func startConversion(from recordedURL: URL) {
        stopRecordingTimers()
        isRecording = false
        step = .transforming
        statusIndex = 0
        statusLine = transformStatuses[0]
        startStatusTimer()

        conversionTask?.cancel()
        conversionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let clip = try await self.prepareClip(from: recordedURL)
                try Task.checkCancellation()
                self.preparedClip = clip
                self.stopStatusTimer()
                self.step = .review
                self.statusLine = "Transformed · \(self.formattedDuration)"
                self.conversionTask = nil
            } catch is CancellationError {
                self.stopStatusTimer()
                self.statusLine = "Tap to record"
                self.conversionTask = nil
            } catch {
                self.log.error("CONVERT: failed \(String(describing: error))")
                self.stopStatusTimer()
                self.step = .record
                self.statusLine = "Convert failed"
                self.conversionTask = nil
            }
        }
    }

    private func prepareClip(from recordedURL: URL) async throws -> PreparedClip {
        let response = try await service.convert(audioURL: recordedURL, voiceId: selectedPersona.id)
        try Task.checkCancellation()
        guard let audioUrl = URL(string: response.audioUrl) else {
            throw ConvertServiceError.invalidAudioURL
        }
        let convertedAudioURL = try await service.fetchAudio(audioUrl)
        try Task.checkCancellation()
        let renderer = WaveformVideoRenderer()
        let sentAudioBars = await renderer.displayBars(fromAudio: convertedAudioURL)
        if !sentAudioBars.isEmpty {
            waveformBars = sentAudioBars
        }
        let videoURL = try await renderer.makeVideo(fromAudio: convertedAudioURL,
                                                    personaName: selectedPersona.name)
        return PreparedClip(audioURL: convertedAudioURL, videoURL: videoURL)
    }

    private func cancelConversion() {
        conversionTask?.cancel()
        conversionTask = nil
        stopStatusTimer()
    }

    private func startRecordingTimers() {
        recordTimer?.invalidate()
        levelTimer?.invalidate()

        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.seconds += 0.1
            }
        }

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.pushLiveLevel(self.recorder.normalizedLevel())
            }
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
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.85, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.statusIndex = min(self.statusIndex + 1, self.transformStatuses.count - 1)
                self.statusLine = self.transformStatuses[self.statusIndex]
            }
        }
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.audioPlayer else { return }
                if player.duration > 0 {
                    self.playProgress = min(1, player.currentTime / player.duration)
                }
                if !player.isPlaying {
                    self.audioPlayerDidFinishPlaying(player, successfully: true)
                }
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
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
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

struct VoiceTransformView: View {
    @ObservedObject var model: VoiceTransformViewModel

    var body: some View {
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
                Capsule()
                    .fill(.white.opacity(0.20))
                    .frame(width: 38, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

                navBar

                TabView(selection: Binding(get: { pageIndex }, set: { _ in })) {
                    personaPage.tag(0)
                    recordPage.tag(1)
                    reviewPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.snappy(duration: 0.42), value: pageIndex)
            }
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
            let cardWidth: CGFloat = 124
            let sidePadding = max(0, (geo.size.width - cardWidth) / 2)
            if #available(iOS 17.0, *) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(VoicePersona.all) { persona in
                            personaButton(persona)
                                .frame(width: cardWidth)
                                .id(persona.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, sidePadding)
                    .padding(.vertical, 14)
                }
                .scrollContentBackground(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: Binding(
                    get: { model.selectedPersona.id },
                    set: { newID in
                        if let newID, let persona = VoicePersona.all.first(where: { $0.id == newID }) {
                            model.selectedPersona = persona
                        }
                    }
                ))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(VoicePersona.all) { persona in
                                personaButton(persona)
                                    .frame(width: cardWidth)
                                    .id(persona.id)
                            }
                        }
                        .padding(.horizontal, sidePadding)
                        .padding(.vertical, 14)
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
        }
        .frame(height: 156)
    }

    private func personaButton(_ persona: VoicePersona) -> some View {
        let selected = model.selectedPersona == persona
        return Button {
            model.selectedPersona = persona
        } label: {
            VStack(spacing: 10) {
                PersonaAvatarView(persona: persona, size: 96, selected: selected)
                Text(persona.name)
                    .font(.system(size: 15, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? .white : .white.opacity(0.55))
            }
            .scaleEffect(selected ? 1 : 0.8)
            .opacity(selected ? 1 : 0.5)
            .animation(.easeOut(duration: 0.25), value: selected)
        }
        .buttonStyle(.plain)
    }

    private var recordPage: some View {
        VStack(spacing: 0) {
            personaChip(showLiveBadge: model.isRecording)
                .padding(.top, 6)

            Spacer(minLength: 0)

            NeonWaveformView(mode: recordWaveformMode,
                             bars: model.waveformBars,
                             progress: 0)
                .frame(height: 130)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)

            statusView
                .frame(height: 30)
                .padding(.bottom, 10)

            recordControl
                .frame(height: 84)

            Text(model.isRecording ? "Tap to stop" : model.step == .transforming ? "" : "Tap to record")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.35))
                .frame(height: 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
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
            ProgressView()
                .tint(model.selectedPersona.color2)
                .scaleEffect(1.45)
        } else if model.isRecording {
            Button { model.recordButtonTapped() } label: {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.50), lineWidth: 4)
                        .frame(width: 76, height: 76)
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(hex: 0xFF9500))
                        .shadow(color: Color(hex: 0xFF9500).opacity(0.70), radius: 18)
                        .frame(width: 28, height: 28)
                }
            }
            .buttonStyle(.plain)
        } else {
            Button { model.recordButtonTapped() } label: {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.70), lineWidth: 3)
                        .frame(width: 80, height: 80)
                    Circle()
                        .fill(Color(hex: 0xFF9500))
                        .shadow(color: Color(hex: 0xFF9500).opacity(0.70), radius: 24)
                        .frame(width: 60, height: 60)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var reviewPage: some View {
        VStack(spacing: 0) {
            personaChip(showLiveBadge: false)
                .padding(.top, 6)

            Spacer(minLength: 0)

            NeonWaveformView(mode: model.isPlaying ? .playing : .ready,
                             bars: model.waveformBars,
                             progress: model.playProgress)
                .frame(height: 130)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)

            Text("Transformed · \(model.formattedDuration)")
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.50))
                .padding(.bottom, 14)

            HStack(spacing: 28) {
                VStack(spacing: 10) {
                    Button { model.redo() } label: {
                        Circle()
                            .fill(.white.opacity(0.10))
                            .frame(width: 54, height: 54)
                            .overlay {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.70))
                            }
                    }
                    .buttonStyle(.plain)
                    Text("Redo")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.40))
                }
                .frame(width: 54)

                VStack(spacing: 10) {
                    Button { model.togglePlayback() } label: {
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
                    .buttonStyle(.plain)
                    Text(model.isPlaying ? "Playing" : "Preview")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.40))
                }
                .frame(width: 80)

                Color.clear.frame(width: 54)
            }
            .frame(height: 108)
            .padding(.bottom, 16)
        }
    }

    private func personaChip(showLiveBadge: Bool) -> some View {
        VStack(spacing: 8) {
            PersonaAvatarView(persona: model.selectedPersona, size: 56, selected: true)
            HStack(spacing: 8) {
                Text(model.selectedPersona.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                if showLiveBadge {
                    Text("LIVE MIC")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Color(hex: 0x34D399))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: 0x34D399).opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
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
            .overlay {
                Text(persona.monogram)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: selected ? persona.color2.opacity(0.65) : .black.opacity(0.40),
                    radius: selected ? 20 : 8,
                    y: selected ? 0 : 4)
            .overlay {
                if selected {
                    Circle()
                        .stroke(Color(hex: 0x0D0D10), lineWidth: 2.5)
                        .padding(-2.5)
                    Circle()
                        .stroke(persona.color2, lineWidth: 2)
                        .padding(-5)
                }
            }
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

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let count = 54
        let gap = size.width / CGFloat(count)
        let barWidth = max(2.5, gap * 0.42)
        let midY = size.height / 2
        let maxHalfHeight = size.height * 0.48

        for index in 0..<count {
            let source = index < bars.count ? bars[index] : fallbackBar(index)
            let t = Double(index) / Double(count)
            let shimmer = (sin(Double(index) * 0.5 - time * 6) * 0.5) + 0.5
            let amplitude: Double
            let color: Color

            switch mode {
            case .recording:
                amplitude = source
                color = Self.rainbowColor(t, lightness: 0.62, saturation: 1, alpha: 1)
            case .transforming:
                amplitude = source * (0.35 + 0.65 * shimmer)
                let drift = (t + time * 0.15).truncatingRemainder(dividingBy: 1)
                color = Self.rainbowColor(drift, lightness: 0.60 + shimmer * 0.08, saturation: 1, alpha: 1)
            case .ready:
                amplitude = source
                color = Self.rainbowColor(t, lightness: 0.52, saturation: 0.70, alpha: 0.50)
            case .playing:
                amplitude = source
                if t <= progress {
                    color = Self.rainbowColor(t, lightness: 0.62, saturation: 1, alpha: 1)
                } else {
                    color = .white.opacity(0.16)
                }
            }

            let height = max(3, CGFloat(amplitude) * maxHalfHeight)
            let rect = CGRect(x: CGFloat(index) * gap + (gap - barWidth) / 2,
                              y: midY - height,
                              width: barWidth,
                              height: height * 2)
            let path = Path(roundedRect: rect, cornerRadius: min(barWidth / 2, 6))
            context.fill(path, with: .color(color))
        }
    }

    private func fallbackBar(_ index: Int) -> Double {
        0.2 + 0.6 * abs(sin(Double(index) * 0.7) * cos(Double(index) * 0.31))
    }

    static func rainbowColor(_ t: Double, lightness: Double, saturation: Double, alpha: Double) -> Color {
        let hue = (140 + t * 280).truncatingRemainder(dividingBy: 360) / 360
        return Color(hue: hue, saturation: saturation, brightness: lightness, opacity: alpha)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}

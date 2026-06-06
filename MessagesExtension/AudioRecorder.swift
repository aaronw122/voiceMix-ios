import Foundation
import AVFoundation

/// Thin wrapper over `AVAudioRecorder` that writes AAC `.m4a` to a temp file.
/// Configures and activates the audio session before recording — the default
/// iOS session permits playback but not recording.
final class AudioRecorder: NSObject {
    static let maxDurationSeconds: TimeInterval = 60

    private var recorder: AVAudioRecorder?
    private var maxDurationTimer: Timer?
    private(set) var fileURL: URL?
    var didReachMaxDuration: ((URL?) -> Void)?

    var isRecording: Bool { recorder?.isRecording ?? false }

    func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        // `.playAndRecord` so we can also do the local playback sanity check.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true, options: [])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceMix-recording-\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        guard recorder.record() else {
            throw RecorderError.failedToStart
        }

        self.recorder = recorder
        self.fileURL = url
        scheduleMaxDurationTimer()
    }

    /// Stops recording and returns the finished file URL.
    @discardableResult
    func stopRecording() -> URL? {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        recorder?.stop()
        let url = fileURL
        recorder = nil
        // Release the session so other audio (playback bubble) behaves nicely.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        return url
    }

    enum RecorderError: Error {
        case failedToStart
    }

    private func scheduleMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: Self.maxDurationSeconds,
                                                repeats: false) { [weak self] _ in
            guard let self, self.isRecording else { return }
            let url = self.stopRecording()
            self.didReachMaxDuration?(url)
        }
    }

    // MARK: - Microphone permission

    /// Coarse mic-permission state, normalized across the iOS 17+ and legacy APIs.
    enum MicPermission {
        case granted
        case denied
        case undetermined
    }

    /// Current record-permission state without prompting.
    static var micPermission: MicPermission {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .undetermined
            @unknown default: return .undetermined
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .undetermined
            @unknown default: return .undetermined
            }
        }
    }

    /// Explicitly request record permission. The completion is hopped onto the
    /// main actor so callers can update UI directly. In an iMessage extension
    /// the implicit prompt from `AVAudioRecorder.record()` often never fires, so
    /// we must request explicitly before recording.
    static func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        let deliver: (Bool) -> Void = { granted in
            Task { @MainActor in completion(granted) }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: deliver)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(deliver)
        }
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {}

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
        recorder.isMeteringEnabled = true
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

    /// Current mic level normalized to 0...1 for the live waveform.
    func normalizedLevel() -> Double {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        guard power.isFinite else { return 0 }

        // AVAudioRecorder reports roughly -80dB...0dB. Bias the curve toward
        // speech so quiet phrases still produce visible bars.
        let clamped = Double(min(max(power, -60), 0))
        let linear = pow(10, clamped / 20)
        return min(1, max(0.04, pow(linear * 3.2, 0.72)))
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

}

extension AudioRecorder: AVAudioRecorderDelegate {}

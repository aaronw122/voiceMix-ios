import Foundation
import AVFoundation

/// Thin wrapper over `AVAudioRecorder` that writes AAC `.m4a` to a temp file.
/// Configures and activates the audio session before recording — the default
/// iOS session permits playback but not recording.
final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL?

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
    }

    /// Stops recording and returns the finished file URL.
    @discardableResult
    func stopRecording() -> URL? {
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
}

extension AudioRecorder: AVAudioRecorderDelegate {}

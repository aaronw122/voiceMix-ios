import Foundation

/// Client-side-only stand-in for the convert backend. No bytes leave the device.
struct MockConvertService: ConvertService {
    func convert(audioURL: URL, voiceId: String) async throws -> ConvertResponse {
        // Fake latency so the loading state is real.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        return ConvertResponse(
            url: "https://mock.voicemix.invalid/clip/123",
            title: "voiceMix sample",
            // A dummy audioUrl the mock controls; fetchAudio ignores its value.
            audioUrl: "https://mock.voicemix.invalid/audio/sample.mp3"
        )
    }

    func fetchAudio(_ audioUrl: URL) async throws -> URL {
        // Ignore the dummy URL; copy the bundled sample to a durable temp file.
        guard let bundled = Bundle.main.url(forResource: "sample", withExtension: "mp3") else {
            throw ConvertServiceError.missingBundledSample
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceMix-\(UUID().uuidString).mp3")

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: bundled, to: destination)
        return destination
    }
}

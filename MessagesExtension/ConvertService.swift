import Foundation

/// Response shape returned by the convert backend.
struct ConvertResponse: Decodable {
    let url: String
    let title: String
    let audioUrl: String
}

/// The single seam isolating real vs. mock networking. Nothing downstream
/// knows whether the bytes came from german's backend or a bundled sample.
protocol ConvertService {
    /// Upload the recorded audio and receive a `{url, title, audioUrl}` payload.
    func convert(audioURL: URL, voiceId: String) async throws -> ConvertResponse
    /// Fetch the converted audio, returning a durable local `.mp3` file URL
    /// (one that won't be cleaned up before it's inserted into the thread).
    func fetchAudio(_ audioUrl: URL) async throws -> URL
}

enum ConvertServiceError: Error {
    case missingBundledSample
    case invalidResponse
    case invalidAudioURL
}

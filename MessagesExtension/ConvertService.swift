import Foundation

/// Response shape returned by the convert backend. Both `/convert` and
/// `/impersonate` return this identical shape, so everything downstream is
/// engine-agnostic.
struct ConvertResponse: Decodable {
    let url: String
    let title: String
    let audioUrl: String
}

/// The single seam isolating real vs. mock networking. Nothing downstream
/// knows whether the bytes came from the backend or a bundled sample.
protocol ConvertService {
    /// Upload the recorded audio and receive a `{url, title, audioUrl}` payload.
    /// `engine` selects the backend endpoint (`.elevenlabs` → `/convert`,
    /// `.modal` → `/impersonate`); the backend 422s on a wrong pairing.
    func convert(audioURL: URL, voiceId: String, engine: VoiceEngine) async throws -> ConvertResponse
    /// Fetch the converted audio, returning a durable local `.mp3` file URL
    /// (one that won't be cleaned up before it's inserted into the thread).
    func fetchAudio(_ audioUrl: URL) async throws -> URL
}

/// Status-specific failures so callers can show distinct, actionable copy
/// instead of collapsing everything into one "Convert failed".
enum ConvertServiceError: Error {
    case missingBundledSample
    case invalidAudioURL
    /// File exceeded the backend's size budget before we even uploaded it.
    case fileTooLarge(bytes: Int)
    /// Non-2xx HTTP response. `body` carries the (truncated) server message.
    case httpStatus(Int, body: String?)
    /// Transport-level failure: offline, timeout, DNS, TLS, etc.
    case network(underlying: Error)
}

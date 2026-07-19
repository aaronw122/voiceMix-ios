import Foundation

/// Which backend engine (and therefore which endpoint) a voice routes to.
///
/// The backend rejects the wrong pairing with a 422, so this is load-bearing,
/// not cosmetic: `.elevenlabs` voices go to `POST /convert`, `.modal` voices
/// go to `POST /impersonate`.
public enum VoiceEngine: String, Equatable {
    case elevenlabs
    case modal
}

/// The single seam isolating real vs. mock networking. Nothing downstream
/// knows whether the bytes came from the backend or a bundled sample.
public protocol ConvertService {
    /// Upload the recorded audio and receive a local `.mp3` file URL.
    /// `engine` selects the backend endpoint (`.elevenlabs` → `/convert`,
    /// `.modal` → `/impersonate`); the backend 422s on a wrong pairing.
    func convert(audioURL: URL, voiceId: String, engine: VoiceEngine) async throws -> URL
}

/// Status-specific failures so callers can show distinct, actionable copy
/// instead of collapsing everything into one "Convert failed".
enum ConvertServiceError: Error {
    case missingBundledSample
    /// File exceeded the backend's size budget before we even uploaded it.
    case fileTooLarge(bytes: Int)
    /// Non-2xx HTTP response. `body` carries the (truncated) server message.
    case httpStatus(Int, body: String?)
    /// 503 admission rejection. `retryAfter` is the server's integer-seconds
    /// `Retry-After` ETA (or a fallback) that drives the queued countdown.
    case busy(retryAfter: Int)
    /// A successful response did not contain the negotiated MP3 payload.
    case unexpectedContentType(String?)
    /// Transport-level failure: offline, timeout, DNS, TLS, etc.
    case network(underlying: Error)
}

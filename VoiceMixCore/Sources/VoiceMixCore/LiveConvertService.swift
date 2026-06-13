import Foundation
import os

/// Real networking against the voiceMix backend.
///
/// Routes by `engine`: `.elevenlabs` → `POST /convert`, `.modal` →
/// `POST /impersonate`. Both take a multipart body with a `voiceId` form field
/// and an `audio` file part; for modal we send EXACTLY those two parts (no
/// `text` part — the backend rejects sending both audio and text).
public struct LiveConvertService: ConvertService {
    /// Mirror of the backend's 10MB upload limit. We fail fast with a typed
    /// error before buffering the file rather than uploading and eating a 413.
    static let maxUploadBytes = 10 * 1024 * 1024

    let baseURL: URL
    let session: URLSession

    private let log = Logger(subsystem: "com.aaron.voiceMixer", category: "network")

    /// A backend convert can take ~70s, which blows past `URLSession.shared`'s
    /// 60s default request timeout (it throws `NSURLErrorTimedOut`, surfaced as
    /// `ConvertServiceError.network`). Use a dedicated session with a 120s
    /// request timeout to leave headroom.
    public static let convertSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        return URLSession(configuration: config)
    }()

    public init(baseURL: URL = Config.baseURL, session: URLSession = LiveConvertService.convertSession) {
        self.baseURL = baseURL
        self.session = session
    }

    public func convert(audioURL: URL, voiceId: String, engine: VoiceEngine) async throws -> ConvertResponse {
        try validateUploadSize(of: audioURL)

        let boundary = "Boundary-\(UUID().uuidString)"
        let request = makeUploadRequest(for: engine, boundary: boundary)

        let audioData = try Data(contentsOf: audioURL)
        let body = Self.multipartBody(
            boundary: boundary,
            voiceId: voiceId,
            audioData: audioData
        )

        let (data, response) = try await performUpload(request, body: body)
        let payload = try validatedPayload(data, response, engine: engine, voiceId: voiceId)
        return try JSONDecoder().decode(ConvertResponse.self, from: payload)
    }

    private func endpoint(for engine: VoiceEngine) -> URL {
        let path: String
        switch engine {
        case .elevenlabs: path = "convert"
        case .modal: path = "impersonate"
        }
        return baseURL.appendingPathComponent(path)
    }

    /// Size guard BEFORE reading the whole file into memory.
    private func validateUploadSize(of audioURL: URL) throws {
        if let size = try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int,
           size > Self.maxUploadBytes {
            log.error("UPLOAD: file too large \(size) bytes > \(Self.maxUploadBytes)")
            throw ConvertServiceError.fileTooLarge(bytes: size)
        }
    }

    private func makeUploadRequest(for engine: VoiceEngine, boundary: String) -> URLRequest {
        var request = URLRequest(url: endpoint(for: engine))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func performUpload(_ request: URLRequest, body: Data) async throws -> (Data, URLResponse) {
        do {
            return try await session.upload(for: request, from: body)
        } catch {
            log.error("UPLOAD: transport failure \(error.localizedDescription)")
            throw ConvertServiceError.network(underlying: error)
        }
    }

    private func validatedPayload(
        _ data: Data,
        _ response: URLResponse,
        engine: VoiceEngine,
        voiceId: String
    ) throws -> Data {
        guard let http = response as? HTTPURLResponse else {
            throw ConvertServiceError.httpStatus(-1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data.prefix(512), encoding: .utf8)
            log.error("UPLOAD: HTTP \(http.statusCode) engine=\(engine.rawValue) voiceId=\(voiceId) body=\(bodyText ?? "<none>")")
            throw ConvertServiceError.httpStatus(http.statusCode, body: bodyText)
        }
        return data
    }

    public func fetchAudio(_ audioUrl: URL) async throws -> URL {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: audioUrl)
        } catch {
            throw ConvertServiceError.network(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ConvertServiceError.httpStatus(-1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ConvertServiceError.httpStatus(http.statusCode, body: nil)
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceMix-\(UUID().uuidString).mp3")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Builds a multipart/form-data body with a `voiceId` text field and an
    /// `audio` file part. The filename is hardcoded to `recording.m4a` to avoid
    /// `Content-Disposition` header injection from a future untrusted file
    /// source. `internal` (not `private`) so the request shape is testable.
    static func multipartBody(
        boundary: String,
        voiceId: String,
        audioData: Data
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"

        func append(_ string: String) {
            body.append(string.data(using: .utf8)!)
        }

        func appendVoiceIdField() {
            append("--\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"voiceId\"\(crlf)\(crlf)")
            append("\(voiceId)\(crlf)")
        }

        func appendAudioFileField() {
            append("--\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"audio\"; filename=\"recording.m4a\"\(crlf)")
            append("Content-Type: audio/m4a\(crlf)\(crlf)")
            body.append(audioData)
            append(crlf)
        }

        func appendClosingBoundary() {
            append("--\(boundary)--\(crlf)")
        }

        appendVoiceIdField()
        appendAudioFileField()
        appendClosingBoundary()
        return body
    }
}

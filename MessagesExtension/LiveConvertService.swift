import Foundation
import os

/// Real networking against the voiceMix backend.
///
/// Routes by `engine`: `.elevenlabs` → `POST /convert`, `.modal` →
/// `POST /impersonate`. Both take a multipart body with a `voiceId` form field
/// and an `audio` file part; for modal we send EXACTLY those two parts (no
/// `text` part — the backend rejects sending both audio and text).
struct LiveConvertService: ConvertService {
    /// Mirror of the backend's 10MB upload limit. We fail fast with a typed
    /// error before buffering the file rather than uploading and eating a 413.
    static let maxUploadBytes = 10 * 1024 * 1024

    let baseURL: URL
    let session: URLSession

    private let log = Logger(subsystem: "com.aaron.voiceMixer", category: "network")

    init(baseURL: URL = Config.baseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func convert(audioURL: URL, voiceId: String, engine: VoiceEngine) async throws -> ConvertResponse {
        let path: String
        switch engine {
        case .elevenlabs: path = "convert"
        case .modal: path = "impersonate"
        }
        let endpoint = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        // Size guard BEFORE reading the whole file into memory.
        if let size = try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int,
           size > Self.maxUploadBytes {
            log.error("UPLOAD: file too large \(size) bytes > \(Self.maxUploadBytes)")
            throw ConvertServiceError.fileTooLarge(bytes: size)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)
        // Both engines use the same body shape: `voiceId` + `audio` only.
        let body = Self.multipartBody(
            boundary: boundary,
            voiceId: voiceId,
            audioData: audioData
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: body)
        } catch {
            log.error("UPLOAD: transport failure \(error.localizedDescription)")
            throw ConvertServiceError.network(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ConvertServiceError.httpStatus(-1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data.prefix(512), encoding: .utf8)
            log.error("UPLOAD: HTTP \(http.statusCode) engine=\(engine.rawValue) voiceId=\(voiceId) body=\(bodyText ?? "<none>")")
            throw ConvertServiceError.httpStatus(http.statusCode, body: bodyText)
        }
        return try JSONDecoder().decode(ConvertResponse.self, from: data)
    }

    func fetchAudio(_ audioUrl: URL) async throws -> URL {
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

        // voiceId field
        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"voiceId\"\(crlf)\(crlf)")
        append("\(voiceId)\(crlf)")

        // audio file part — fixed filename, no header injection surface.
        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"recording.m4a\"\(crlf)")
        append("Content-Type: audio/m4a\(crlf)\(crlf)")
        body.append(audioData)
        append(crlf)

        append("--\(boundary)--\(crlf)")
        return body
    }
}

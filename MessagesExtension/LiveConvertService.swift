import Foundation

/// Real networking against german's backend. Written now, unwired (`useMock`
/// stays `true`) until the endpoint is live. It only needs to compile — there
/// is no backend to run it against yet.
struct LiveConvertService: ConvertService {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = Config.baseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func convert(audioURL: URL, voiceId: String) async throws -> ConvertResponse {
        let endpoint = baseURL.appendingPathComponent("convert")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)
        let body = Self.multipartBody(
            boundary: boundary,
            voiceId: voiceId,
            audioData: audioData,
            audioFilename: audioURL.lastPathComponent
        )

        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ConvertServiceError.invalidResponse
        }
        return try JSONDecoder().decode(ConvertResponse.self, from: data)
    }

    func fetchAudio(_ audioUrl: URL) async throws -> URL {
        let (data, response) = try await session.data(from: audioUrl)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ConvertServiceError.invalidResponse
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceMix-\(UUID().uuidString).mp3")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Builds a multipart/form-data body with an `audio` file part and a
    /// `voiceId` text field.
    private static func multipartBody(
        boundary: String,
        voiceId: String,
        audioData: Data,
        audioFilename: String
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

        // audio file part
        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(audioFilename)\"\(crlf)")
        append("Content-Type: audio/m4a\(crlf)\(crlf)")
        body.append(audioData)
        append(crlf)

        append("--\(boundary)--\(crlf)")
        return body
    }
}

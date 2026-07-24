import Foundation
import XCTest
@testable import VoiceMixCore

final class LiveConvertServiceTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.requestHandler = nil
        super.tearDown()
    }

    func testConvertSendsAudioMPEGAcceptHeaderAndWritesExactResponseBytes() async throws {
        let expectedAudio = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x01, 0x02])
        URLProtocolStub.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "audio/mpeg")
            return try Self.response(
                for: request,
                statusCode: 200,
                contentType: "Audio/MPEG; charset=binary",
                data: expectedAudio
            )
        }

        let service = makeService()
        let uploadURL = try makeUploadFile()
        defer { try? FileManager.default.removeItem(at: uploadURL) }

        let audioURL = try await service.convert(
            audioURL: uploadURL,
            voiceId: "el-prez",
            engine: .modal
        )
        defer { try? FileManager.default.removeItem(at: audioURL) }

        XCTAssertEqual(audioURL.pathExtension, "mp3")
        XCTAssertEqual(try Data(contentsOf: audioURL), expectedAudio)
    }

    func testConvertSendsStableDeviceIdAndFreshRequestIdPerAttempt() async throws {
        var deviceIds: [String?] = []
        var requestIds: [String?] = []
        var appVersions: [String?] = []
        URLProtocolStub.requestHandler = { request in
            deviceIds.append(request.value(forHTTPHeaderField: "X-Device-Id"))
            requestIds.append(request.value(forHTTPHeaderField: "X-Request-Id"))
            appVersions.append(request.value(forHTTPHeaderField: "X-App-Version"))
            return try Self.response(
                for: request,
                statusCode: 200,
                contentType: "audio/mpeg",
                data: Data([0x49, 0x44, 0x33])
            )
        }

        let service = makeService()
        let uploadURL = try makeUploadFile()
        defer { try? FileManager.default.removeItem(at: uploadURL) }

        for _ in 0..<2 {
            let out = try await service.convert(audioURL: uploadURL, voiceId: "el-prez", engine: .modal)
            try? FileManager.default.removeItem(at: out)
        }

        let sentDeviceIds = try deviceIds.map { try XCTUnwrap($0) }
        XCTAssertEqual(Set(sentDeviceIds).count, 1)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(sentDeviceIds.first)))

        let sentRequestIds = try requestIds.map { try XCTUnwrap($0) }
        XCTAssertEqual(Set(sentRequestIds).count, 2)
        for id in sentRequestIds {
            XCTAssertNotNil(UUID(uuidString: id))
        }

        // Equality (not just non-nil) so a dropped setValue fails whenever the bundle has a version.
        for version in appVersions {
            XCTAssertEqual(version, ClientTelemetry.appVersion)
        }
        for version in appVersions.compactMap({ $0 }) {
            XCTAssertNotNil(version.range(of: #"^\d+\.\d+(\.\d+)?(-[0-9A-Za-z.]+)?$"#, options: .regularExpression),
                            "app version \(version) would be dropped by the backend")
        }
    }

    func testConvert503SurfacesBusyWithParsedRetryAfter() async throws {
        URLProtocolStub.requestHandler = { request in
            try Self.response(
                for: request,
                statusCode: 503,
                headers: ["Content-Type": "application/json", "Retry-After": "42"],
                data: Data(#"{"error":"busy"}"#.utf8)
            )
        }

        let service = makeService()
        let uploadURL = try makeUploadFile()
        defer { try? FileManager.default.removeItem(at: uploadURL) }

        do {
            _ = try await service.convert(audioURL: uploadURL, voiceId: "el-prez", engine: .modal)
            XCTFail("Expected busy")
        } catch let ConvertServiceError.busy(retryAfter) {
            XCTAssertEqual(retryAfter, 42)
        } catch {
            XCTFail("Expected busy, got \(error)")
        }
    }

    func testConvert503WithoutRetryAfterFallsBackToDefaultETA() async throws {
        URLProtocolStub.requestHandler = { request in
            try Self.response(
                for: request,
                statusCode: 503,
                headers: ["Content-Type": "application/json"],
                data: Data(#"{"error":"busy"}"#.utf8)
            )
        }

        let service = makeService()
        let uploadURL = try makeUploadFile()
        defer { try? FileManager.default.removeItem(at: uploadURL) }

        do {
            _ = try await service.convert(audioURL: uploadURL, voiceId: "el-prez", engine: .modal)
            XCTFail("Expected busy")
        } catch let ConvertServiceError.busy(retryAfter) {
            XCTAssertEqual(retryAfter, QueuedRetryPolicy.fallbackETASeconds)
        } catch {
            XCTFail("Expected busy, got \(error)")
        }
    }

    func testConvertThrowsHTTPStatusForJSONErrorWithoutWritingFile() async throws {
        let errorBody = Data(#"{"error":"unknown voice"}"#.utf8)
        URLProtocolStub.requestHandler = { request in
            try Self.response(
                for: request,
                statusCode: 404,
                contentType: "application/json",
                data: errorBody
            )
        }

        let service = makeService()
        let uploadURL = try makeUploadFile()
        defer { try? FileManager.default.removeItem(at: uploadURL) }
        let filesBefore = temporaryMP3Files()

        do {
            _ = try await service.convert(
                audioURL: uploadURL,
                voiceId: "missing",
                engine: .modal
            )
            XCTFail("Expected httpStatus")
        } catch let ConvertServiceError.httpStatus(statusCode, body) {
            XCTAssertEqual(statusCode, 404)
            XCTAssertEqual(body, String(data: errorBody, encoding: .utf8))
        } catch {
            XCTFail("Expected httpStatus, got \(error)")
        }

        XCTAssertEqual(temporaryMP3Files(), filesBefore)
    }

    func testConvertRejectsSuccessfulJSONWithoutLeavingMP3File() async throws {
        let jsonBody = Data(#"{"audioUrl":"https://old.example/audio.mp3"}"#.utf8)
        URLProtocolStub.requestHandler = { request in
            try Self.response(
                for: request,
                statusCode: 200,
                contentType: "application/json",
                data: jsonBody
            )
        }

        let service = makeService()
        let uploadURL = try makeUploadFile()
        defer { try? FileManager.default.removeItem(at: uploadURL) }
        let filesBefore = temporaryMP3Files()

        do {
            _ = try await service.convert(
                audioURL: uploadURL,
                voiceId: "el-prez",
                engine: .modal
            )
            XCTFail("Expected unexpectedContentType")
        } catch let ConvertServiceError.unexpectedContentType(contentType) {
            XCTAssertEqual(contentType, "application/json")
        } catch {
            XCTFail("Expected unexpectedContentType, got \(error)")
        }

        XCTAssertEqual(temporaryMP3Files(), filesBefore)
    }

    private func makeService() -> LiveConvertService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return LiveConvertService(
            baseURL: URL(string: "https://voice.test")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func makeUploadFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceMix-upload-\(UUID().uuidString).m4a")
        try Data([0x00, 0x01, 0x02]).write(to: url, options: .atomic)
        return url
    }

    private func temporaryMP3Files() -> Set<URL> {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return Set(files.filter {
            $0.lastPathComponent.hasPrefix("voiceMix-") && $0.pathExtension == "mp3"
        })
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int,
        contentType: String,
        data: Data
    ) throws -> (HTTPURLResponse, Data) {
        try response(for: request, statusCode: statusCode, headers: ["Content-Type": contentType], data: data)
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int,
        headers: [String: String],
        data: Data
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        ))
        return (response, data)
    }
}

private final class URLProtocolStub: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            XCTFail("URLProtocolStub.requestHandler was not set")
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

import Foundation

/// Client-side-only stand-in for the convert backend. No bytes leave the device.
///
/// For the steel thread the mock echoes the user's *actual recording* back so
/// playback feels real (untransformed) on-device. If the recording can't be
/// found, it falls back to the bundled sample so the flow never breaks.
public struct MockConvertService: ConvertService {
    public init() {}

    public func convert(audioURL: URL, voiceId: String, engine: VoiceEngine) async throws -> URL {
        #if DEBUG && canImport(UIKit)
        // Catch wrong live routing early: a green mock must not mask a
        // voiceId/engine mismatch that would 422 against the real backend.
        assert(Self.expectedEngine[voiceId] == engine,
               "voiceId '\(voiceId)' routed to \(engine.rawValue); expected \(Self.expectedEngine[voiceId]?.rawValue ?? "<unknown voiceId>")")
        #endif
        // Fake latency so the loading state is real.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let source = recordedFile(from: audioURL) ?? bundledSample()

        guard let source else { throw ConvertServiceError.missingBundledSample }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceMix-\(UUID().uuidString).mp3")

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// The user's recording, if `audioURL` points at an existing local file.
    private func recordedFile(from audioURL: URL) -> URL? {
        guard audioURL.isFileURL,
              FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
        return audioURL
    }

    private func bundledSample() -> URL? {
        Bundle.main.url(forResource: "sample", withExtension: "mp3")
    }

    #if DEBUG && canImport(UIKit)
    /// Known-good voiceId → engine pairings, derived from the catalog so the
    /// mock asserts the same routing the live service would perform.
    private static let expectedEngine: [String: VoiceEngine] = Dictionary(
        uniqueKeysWithValues: VoicePersona.all.map { ($0.voiceId, $0.engine) }
    )
    #endif
}

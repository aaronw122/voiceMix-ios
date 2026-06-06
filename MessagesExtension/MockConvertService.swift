import Foundation

/// Client-side-only stand-in for the convert backend. No bytes leave the device.
///
/// For the steel thread the mock echoes the user's *actual recording* back so
/// playback feels real (untransformed) on-device. If the recording can't be
/// found, it falls back to the bundled sample so the flow never breaks.
struct MockConvertService: ConvertService {
    func convert(audioURL: URL, voiceId: String, engine: VoiceEngine) async throws -> ConvertResponse {
        #if DEBUG
        // Catch wrong live routing early: a green mock must not mask a
        // voiceId/engine mismatch that would 422 against the real backend.
        assert(Self.expectedEngine[voiceId] == engine,
               "voiceId '\(voiceId)' routed to \(engine.rawValue); expected \(Self.expectedEngine[voiceId]?.rawValue ?? "<unknown voiceId>")")
        #endif
        // Fake latency so the loading state is real.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        return ConvertResponse(
            url: "https://mock.voicemix.invalid/clip/123",
            title: "voiceMix sample",
            // Echo the recorded file back as a local file URL; fetchAudio copies it.
            audioUrl: audioURL.absoluteString
        )
    }

    func fetchAudio(_ audioUrl: URL) async throws -> URL {
        let source = recordedFile(from: audioUrl) ?? bundledSample()

        guard let source else { throw ConvertServiceError.missingBundledSample }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceMix-\(UUID().uuidString).\(source.pathExtension)")

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// The user's recording, if `audioUrl` points at an existing local file.
    private func recordedFile(from audioUrl: URL) -> URL? {
        guard audioUrl.isFileURL,
              FileManager.default.fileExists(atPath: audioUrl.path) else { return nil }
        return audioUrl
    }

    private func bundledSample() -> URL? {
        Bundle.main.url(forResource: "sample", withExtension: "mp3")
    }

    #if DEBUG
    /// Known-good voiceId → engine pairings, derived from the catalog so the
    /// mock asserts the same routing the live service would perform.
    private static let expectedEngine: [String: VoiceEngine] = Dictionary(
        uniqueKeysWithValues: VoicePersona.all.map { ($0.voiceId, $0.engine) }
    )
    #endif
}

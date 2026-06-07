import Foundation
import os

#if DEBUG
/// DEBUG-only sanity check: at launch, fetch `GET {baseURL}/voices` and assert
/// the local hardcoded catalog still matches the server's `voiceId` / `engine`
/// / `acceptsText`. The hardcoded catalog otherwise drifts silently into
/// 404/422 at demo time.
///
/// Non-blocking and short-timeout by design — this never gates the UI. It is
/// invoked from `MessagesViewController.viewDidLoad`. Networking deliberately
/// lives here, NOT in static catalog init or `Config`.
public enum VoiceCatalogPreflight {
    /// One `/voices` entry as returned by the backend.
    private struct ServerVoice: Decodable {
        let id: String
        let name: String
        let engine: String
        let acceptsText: Bool
    }

    private static let log = Logger(subsystem: "com.aaron.voiceMixer", category: "preflight")

    /// Fire-and-forget. Logs/asserts mismatches; swallows transport failures.
    public static func run(baseURL: URL = Config.baseURL) {
        Task.detached(priority: .utility) {
            let endpoint = baseURL.appendingPathComponent("voices")
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 5

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    log.error("PREFLIGHT: /voices non-2xx — skipping catalog check")
                    return
                }
                let serverVoices = try JSONDecoder().decode([ServerVoice].self, from: data)
                validate(serverVoices)
            } catch {
                // Offline / timeout during dev is fine — never block launch.
                log.notice("PREFLIGHT: /voices unreachable (\(error.localizedDescription)) — skipping")
            }
        }
    }

    private static func validate(_ serverVoices: [ServerVoice]) {
        let byId = Dictionary(uniqueKeysWithValues: serverVoices.map { ($0.id, $0) })

        for persona in VoicePersona.all {
            guard let server = byId[persona.voiceId] else {
                log.error("PREFLIGHT: voiceId '\(persona.voiceId)' missing from server /voices")
                assertionFailure("Local catalog voiceId '\(persona.voiceId)' not found on server")
                continue
            }
            if server.engine != persona.engine.rawValue {
                log.error("PREFLIGHT: engine drift for '\(persona.voiceId)': local=\(persona.engine.rawValue) server=\(server.engine)")
                assertionFailure("Engine drift for '\(persona.voiceId)': local=\(persona.engine.rawValue) server=\(server.engine)")
            }
            // We only assert id-exists + engine match. `acceptsText` is purely a
            // backend hint about text input; the client always sends audio, so it
            // is not part of our contract and varies independently server-side.
        }
        log.info("PREFLIGHT: catalog matches server /voices")
    }
}
#endif

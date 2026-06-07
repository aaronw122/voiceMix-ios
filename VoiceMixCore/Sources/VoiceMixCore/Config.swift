import Foundation

public enum Config {
    /// Base URL for the convert backend.
    public static let baseURL: URL = {
        if let host = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
           !host.isEmpty,
           let url = URL(string: host) {
            return url
        }
        // ATS: the production origin is HTTPS, so no App Transport Security
        // exception is needed. If you ever point this at a plain-HTTP dev
        // endpoint (e.g. http://localhost), add a DEBUG-only, EXTENSION-target
        // NSAppTransportSecurity exception — do NOT ship a blanket
        // NSAllowsArbitraryLoads.
        return URL(string: "https://voiceapi.awill.co")!
    }()

    /// Orthogonal to environment. `false` = real backend; flip to `true` for
    /// offline development against the bundled sample.
    public static let useMock = false
}

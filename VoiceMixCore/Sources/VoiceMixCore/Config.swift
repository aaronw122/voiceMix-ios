import Foundation

public enum Config {
    /// Base URL for the convert backend.
    ///
    /// Per steel.md the preferred long-term approach is to drive this from an
    /// xcconfig / build setting surfaced through Info.plist. For the steel
    /// thread we keep a simple `#if DEBUG` fallback constant so the swap to
    /// german's real endpoint is a one-line change and we don't fight xcconfig
    /// under time pressure.
    public static let baseURL: URL = {
        if let host = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
           !host.isEmpty,
           let url = URL(string: host) {
            return url
        }
        // Code fallback: the live HTTPS origin (Cloudflare tunnel). The
        // Info.plist `API_BASE_URL` (driven by Debug/Release build settings)
        // overrides this when set.
        //
        // ATS: the production origin is HTTPS, so no App Transport Security
        // exception is needed (and none is present in either Info.plist). If you
        // ever point this at a plain-HTTP dev endpoint (e.g. http://localhost),
        // add a DEBUG-only, EXTENSION-target NSAppTransportSecurity exception —
        // do NOT ship a blanket NSAllowsArbitraryLoads.
        return URL(string: "https://voiceapi.awill.co")!
    }()

    /// Orthogonal to environment. `false` = real backend; flip to `true` for
    /// offline development against the bundled sample.
    public static let useMock = false
}

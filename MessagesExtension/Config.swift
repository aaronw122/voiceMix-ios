import Foundation

enum Config {
    /// Base URL for the convert backend.
    ///
    /// Per steel.md the preferred long-term approach is to drive this from an
    /// xcconfig / build setting surfaced through Info.plist. For the steel
    /// thread we keep a simple `#if DEBUG` fallback constant so the swap to
    /// german's real endpoint is a one-line change and we don't fight xcconfig
    /// under time pressure.
    static let baseURL: URL = {
        if let host = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
           !host.isEmpty,
           let url = URL(string: host) {
            return url
        }
        #if DEBUG
        return URL(string: "https://dev.example.com")!
        #else
        return URL(string: "https://api.example.com")!
        #endif
    }()

    /// Orthogonal to environment. Flip to `false` when german's endpoint is live.
    static let useMock = true
}

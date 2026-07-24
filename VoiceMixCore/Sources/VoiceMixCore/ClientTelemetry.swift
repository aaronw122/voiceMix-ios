import Foundation

/// Identity headers for the backend telemetry ledger; omitted ones land as NULL columns.
enum ClientTelemetry {
    private static let installIdKey = "voiceMix.installId"

    /// Extension-scoped — no App Group, so the host app would mint a different id. Backend
    /// drops a `device_id` it can't parse as a UUID, hence the revalidation on read.
    static let installId: String = {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: installIdKey), UUID(uuidString: existing) != nil {
            return existing
        }
        let minted = UUID().uuidString
        defaults.set(minted, forKey: installIdKey)
        return minted
    }()

    /// Backend requires at least `major.minor`, so a bare `"1"` would be dropped.
    static let appVersion: String? =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    /// Fresh per attempt: `request_id` is a non-unique index, so a reused id writes a
    /// second, ambiguous row rather than replacing the first.
    static func newRequestId() -> String { UUID().uuidString }
}

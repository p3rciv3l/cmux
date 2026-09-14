import Foundation

/// A caller-generated, single-use identifier pairing one suspend request with its release.
struct BrowserMediaSuspensionLeaseID: Hashable {
    let rawValue: String

    init?(_ rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 128 else { return nil }
        self.rawValue = normalized
    }
}

import Foundation

/// Tracks which content hashes have already been claimed during a run so a
/// duplicate file is inferred once and inherits the original's verdict.
public actor Deduplicator {
    private var firstSeen: [String: String] = [:] // hash -> relative path
    private let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    /// Returns the relative path of an earlier file with the same hash, or nil
    /// if this hash is new (and records it).
    public func claim(hash: String, relativePath: String) -> String? {
        guard enabled else { return nil }
        if let existing = firstSeen[hash] {
            return existing
        }
        firstSeen[hash] = relativePath
        return nil
    }

    public func seed(hash: String, relativePath: String) {
        if firstSeen[hash] == nil {
            firstSeen[hash] = relativePath
        }
    }
}

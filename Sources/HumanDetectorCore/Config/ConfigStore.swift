import Foundation

/// Loads and saves `AppConfig` as pretty-printed JSON so it is diffable and
/// hand-editable. Also holds the security-scoped bookmark helpers the sandboxed
/// app needs in order to reopen folders across launches.
public enum ConfigStore {
    public static let defaultFileName = "HumanDetectorConfig.json"

    public static func defaultConfig(hardware: HardwareProfile = .current()) -> AppConfig {
        var config = AppConfig()
        PresetResolver.apply(.auto, hardware: hardware, to: &config)
        config.person.family = .yolo26
        config.person.task = .seg
        return config
    }

    public static func load(from url: URL) throws -> AppConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    public static func save(_ config: AppConfig, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }

    /// Default on-disk location inside Application Support.
    public static func defaultURL() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("HumanDetector", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(defaultFileName)
    }

    public static func loadOrDefault() -> AppConfig {
        guard let url = defaultURL(), let config = try? load(from: url) else {
            return defaultConfig()
        }
        return config
    }
}

// MARK: - Security-scoped bookmarks (sandbox folder access)

public enum BookmarkStore {
    /// Create a security-scoped bookmark for a user-selected folder.
    public static func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Make a bookmark that grants read/write (used for the output root).
    public static func readWriteBookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve a bookmark, returning a URL that is already started.
    /// The caller is responsible for calling `stopAccessingSecurityScopedResource()`
    /// when done — wrap in `withSecurityScope` to do that automatically.
    public static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }

    /// Convenience that starts and stops access for the duration of `body`.
    public static func withSecurityScope<T>(_ data: Data, _ body: (URL) throws -> T) throws -> T {
        let (url, _) = try resolve(data)
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }
}

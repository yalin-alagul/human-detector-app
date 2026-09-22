import Foundation

/// A single reversible file placement.
public struct UndoRecord: Codable, Sendable, Equatable {
    public var sourcePath: String
    public var destinationPath: String
    public var hash: String
    public var verdict: Verdict
    public var timestamp: Date

    public init(sourcePath: String, destinationPath: String, hash: String, verdict: Verdict, timestamp: Date = Date()) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.hash = hash
        self.verdict = verdict
        self.timestamp = timestamp
    }
}

/// Append-only journal of every file we moved, so a run can be undone.
///
/// `AGENTS.md` treats moving as safe because it is not deleting, but a wrong
/// verdict still scrambles a library. This journal is the missing undo button.
public final class UndoJournal {
    public let url: URL
    private let handle: FileHandle
    private let lock = NSLock()

    public init(outputRoot: URL) throws {
        let dir = outputRoot.appendingPathComponent(SupportPaths.workDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("undo-\(SupportPaths.uniqueStamp()).jsonl")
        // Unique name means createFile can never truncate an earlier journal.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    public func record(_ record: UndoRecord) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data([0x0A]))
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
    }

    // MARK: Reading

    public static func journalURLs(outputRoot: URL) -> [URL] {
        let dir = outputRoot.appendingPathComponent(SupportPaths.workDirName, isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("undo-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func records(at url: URL) -> [UndoRecord] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(UndoRecord.self, from: Data(line.utf8))
        }
    }

    /// Move everything from the newest *non-empty* journal back to its source
    /// location. Empty journals (created by no-op runs) are skipped and cleaned
    /// up, so pressing Undo repeatedly walks back through real runs.
    ///
    /// Restored files are also recorded in `restored.jsonl` so the resume logic
    /// knows they are no longer processed and must be scanned again.
    @discardableResult
    public static func undoLatest(outputRoot: URL) throws -> Int {
        let journals = journalURLs(outputRoot: outputRoot)
        var usedJournal: URL?
        var pending: [UndoRecord] = []

        for url in journals.reversed() {
            let contents = records(at: url)
            if contents.isEmpty {
                // Drop empty journals so they do not mask real ones.
                try? FileManager.default.removeItem(at: url)
                continue
            }
            usedJournal = url
            pending = contents
            break
        }

        guard let journal = usedJournal else { return 0 }

        var restoredRecords: [UndoRecord] = []
        for record in pending.reversed() {
            let destination = URL(fileURLWithPath: record.destinationPath)
            let source = URL(fileURLWithPath: record.sourcePath)
            guard FileManager.default.fileExists(atPath: destination.path) else { continue }
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.removeItem(at: source)
            }
            try FileManager.default.moveItem(at: destination, to: source)
            restoredRecords.append(record)
        }

        try appendRestored(restoredRecords, outputRoot: outputRoot)
        try? FileManager.default.removeItem(at: journal)
        return restoredRecords.count
    }

    // MARK: Durable restore log

    /// Record that files were put back. The manifest stays append-only, so this
    /// is what lets `processedHashes` tell that a hash is pending again.
    public static func appendRestored(_ records: [UndoRecord], outputRoot: URL) throws {
        guard !records.isEmpty else { return }
        let dir = outputRoot.appendingPathComponent(SupportPaths.workDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(SupportPaths.restoredFileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        let encoder = JSONEncoder()
        for record in records {
            let data = try encoder.encode(record)
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        }
        try handle.close()
    }

    public static func restoredRecords(outputRoot: URL) -> [UndoRecord] {
        let url = outputRoot
            .appendingPathComponent(SupportPaths.workDirName, isDirectory: true)
            .appendingPathComponent(SupportPaths.restoredFileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(UndoRecord.self, from: Data($0)) }
    }
}

enum SupportPaths {
    static let workDirName = ".humandetector"
    static let manifestFileName = "manifest.jsonl"
    static let restoredFileName = "restored.jsonl"

    /// Timestamp with enough entropy that two events in the same second never
    /// share a file name (which previously let one journal overwrite another).
    static func uniqueStamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "\(stamp)-\(UUID().uuidString.prefix(6))"
    }
}

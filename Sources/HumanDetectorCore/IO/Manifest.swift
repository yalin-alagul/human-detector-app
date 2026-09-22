import Foundation

/// Writes the run manifest as append-only JSONL (durable, resume-friendly) plus
/// a per-run CSV for spreadsheets and quick eyeballing.
public final class ManifestWriter {
    public let runID: String
    public let jsonlURL: URL?
    public let csvURL: URL?

    private var jsonlHandle: FileHandle?
    private var csvHandle: FileHandle?
    private let lock = NSLock()

    public init(outputRoot: URL, writeCSV: Bool, writeJSONL: Bool) throws {
        let dir = outputRoot.appendingPathComponent(SupportPaths.workDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = SupportPaths.uniqueStamp()
        runID = stamp

        if writeJSONL {
            let url = dir.appendingPathComponent(SupportPaths.manifestFileName)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            jsonlHandle = handle
            jsonlURL = url
        } else {
            jsonlHandle = nil
            jsonlURL = nil
        }

        if writeCSV {
            let url = dir.appendingPathComponent("run-\(stamp).csv")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: Data((ManifestEntry.csvHeader + "\n").utf8))
            csvHandle = handle
            csvURL = url
        } else {
            csvHandle = nil
            csvURL = nil
        }
    }

    public func append(_ entry: ManifestEntry) {
        lock.lock()
        defer { lock.unlock() }
        if let jsonlHandle, let data = try? JSONEncoder().encode(entry) {
            try? jsonlHandle.write(contentsOf: data)
            try? jsonlHandle.write(contentsOf: Data([0x0A]))
        }
        if let csvHandle {
            try? csvHandle.write(contentsOf: Data((entry.csvRow() + "\n").utf8))
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? jsonlHandle?.close()
        try? csvHandle?.close()
    }
}

/// Reads prior manifests so an interrupted run can skip work it already did.
public enum ManifestReader {
    public static func manifestURL(outputRoot: URL) -> URL {
        outputRoot
            .appendingPathComponent(SupportPaths.workDirName, isDirectory: true)
            .appendingPathComponent(SupportPaths.manifestFileName)
    }

    public static func allEntries(outputRoot: URL) -> [ManifestEntry] {
        let url = manifestURL(outputRoot: outputRoot)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(ManifestEntry.self, from: Data($0)) }
    }

    /// Hashes that are still quarantined and should be skipped on resume.
    ///
    /// A file counts as processed only while its most recent *placement* is
    /// newer than its most recent *restore*. After `Undo Last Run` the restore
    /// wins, so the file is scanned again instead of being silently skipped.
    public static func processedHashes(outputRoot: URL) -> Set<String> {
        // Latest placement per hash, keeping the destination so we can verify
        // the file is really still there (and not just a dry-run record).
        var latestPlaced: [String: (date: Date, destination: String?)] = [:]
        for entry in allEntries(outputRoot: outputRoot) where entry.error == nil {
            if entry.verdict == .skipped || entry.verdict == .failed { continue }
            if let existing = latestPlaced[entry.hash], existing.date >= entry.timestamp { continue }
            latestPlaced[entry.hash] = (entry.timestamp, entry.destinationPath)
        }

        var latestRestored: [String: Date] = [:]
        for record in UndoJournal.restoredRecords(outputRoot: outputRoot) {
            if let existing = latestRestored[record.hash], existing >= record.timestamp { continue }
            latestRestored[record.hash] = record.timestamp
        }

        var result = Set<String>()
        for (hash, placed) in latestPlaced {
            if let restored = latestRestored[hash], restored >= placed.date { continue }
            // A dry run (or a quarantine-off run) has no destination; those must
            // never make a later real run skip the file.
            guard let destination = placed.destination, !destination.isEmpty else { continue }
            guard FileManager.default.fileExists(atPath: destination) else { continue }
            result.insert(hash)
        }
        return result
    }

    /// Forget all prior decisions so the next run reprocesses everything.
    /// The old manifest is moved aside rather than deleted.
    public static func reset(outputRoot: URL) throws {
        let dir = outputRoot.appendingPathComponent(SupportPaths.workDirName, isDirectory: true)
        let stamp = SupportPaths.uniqueStamp()
        let manager = FileManager.default
        let manifest = dir.appendingPathComponent(SupportPaths.manifestFileName)
        if manager.fileExists(atPath: manifest.path) {
            let backup = dir.appendingPathComponent("manifest-\(stamp).bak.jsonl")
            try? manager.removeItem(at: backup)
            try manager.moveItem(at: manifest, to: backup)
        }
        let restored = dir.appendingPathComponent(SupportPaths.restoredFileName)
        if manager.fileExists(atPath: restored.path) {
            try? manager.removeItem(at: restored)
        }
    }
}

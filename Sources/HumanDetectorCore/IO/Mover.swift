import Foundation

public enum FileMoveError: Error, LocalizedError {
    case collision(String)

    public var errorDescription: String? {
        switch self {
        case .collision(let path): return "Destination already exists: \(path)"
        }
    }
}

public struct MoveOutcome: Sendable {
    public let destination: URL
    public let performed: Bool
}

/// Places files into the output tree. Never deletes: even `trash/` is a move.
public enum Mover {
    /// Compute and create the destination, then move/copy the file.
    ///
    /// - Parameter relativePath: path relative to the input root, preserved
    ///   inside the verdict folder so the dataset stays navigable.
    public static func place(
        source: URL,
        outputRoot: URL,
        verdict: Verdict,
        relativePath: String,
        mode: MoveMode,
        collision: CollisionPolicy,
        hash: String,
        dryRun: Bool
    ) throws -> MoveOutcome {
        guard let folder = verdict.folderName else {
            throw FileMoveError.collision("Verdict \(verdict.rawValue) has no destination folder")
        }
        let root = outputRoot.appendingPathComponent(folder, isDirectory: true)
        let relative = relativePath.isEmpty ? source.lastPathComponent : relativePath
        var destination = root.appendingPathComponent(relative)
        let parent = destination.deletingLastPathComponent()

        if dryRun {
            return MoveOutcome(destination: destination, performed: false)
        }

        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destination.path) {
            let resolved = try resolveCollision(
                destination: destination,
                policy: collision,
                hash: hash
            )
            switch resolved {
            case .none:
                return MoveOutcome(destination: destination, performed: false)
            case .some(let url):
                destination = url
            }
        }

        switch mode {
        case .move:
            try FileManager.default.moveItem(at: source, to: destination)
        case .copy:
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return MoveOutcome(destination: destination, performed: true)
    }

    private static func resolveCollision(
        destination: URL,
        policy: CollisionPolicy,
        hash: String
    ) throws -> URL? {
        switch policy {
        case .skip:
            return nil
        case .overwrite:
            try FileManager.default.removeItem(at: destination)
            return destination
        case .hashSuffix:
            let ext = destination.pathExtension
            let stem = destination.deletingPathExtension().lastPathComponent
            let name = "\(stem)_\(Hasher.short(hash))\(ext.isEmpty ? "" : ".\(ext)")"
            return destination.deletingLastPathComponent().appendingPathComponent(name)
        case .suffix:
            let ext = destination.pathExtension
            let stem = destination.deletingPathExtension().lastPathComponent
            let dir = destination.deletingLastPathComponent()
            var index = 1
            while true {
                let name = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
                let candidate = dir.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
                index += 1
                if index > 10_000 { return destination }
            }
        }
    }
}

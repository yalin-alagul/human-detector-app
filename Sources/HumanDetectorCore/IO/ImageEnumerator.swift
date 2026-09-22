import Foundation

public enum ImageEnumerator {
    /// Recursively collect image files under `root`, returning each file's URL
    /// and its path relative to `root` (used to mirror the tree in the output).
    public static func enumerate(root: URL, extensions: Set<String>) throws -> [(url: URL, relativePath: String)] {
        let normalized = Set(extensions.map { $0.lowercased() })
        let rootPath = root.standardizedFileURL.path

        // Distinguish "cannot read" from "genuinely empty" — silence here was
        // the reason a denied sandbox folder looked like a successful no-op.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory) else {
            throw PipelineError.inputNotFound(rootPath)
        }
        guard FileManager.default.isReadableFile(atPath: rootPath) else {
            throw PipelineError.inputNotReadable(rootPath)
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw PipelineError.inputNotReadable(rootPath)
        }

        var results: [(URL, String)] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            if url.lastPathComponent == SupportPaths.workDirName { continue }
            guard normalized.contains(url.pathExtension.lowercased()) else { continue }

            let path = url.standardizedFileURL.path
            var relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
            if relative.hasPrefix("/") { relative.removeFirst() }
            results.append((url, relative))
        }
        return results.sorted { $0.1 < $1.1 }
    }

    /// Count every regular, non-hidden file (any extension) so an empty result
    /// can be explained: empty folder vs. files that simply are not images.
    public static func anyFileCount(root: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }
}

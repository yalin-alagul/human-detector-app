import Foundation

/// A model package installed on this Mac.
public struct InstalledModel: Sendable, Equatable, Identifiable {
    public var stem: String
    public var url: URL
    public var bytes: Int64
    public var id: String { stem }
}

public enum ModelStoreError: Error, LocalizedError {
    case notAModelPackage(String)
    case nothingToImport

    public var errorDescription: String? {
        switch self {
        case .notAModelPackage(let name):
            return "\(name) isn't a CoreML model package (no Manifest.json inside)."
        case .nothingToImport:
            return "No .mlpackage models were found in the selection."
        }
    }
}

/// The folder models are installed into. The app ships without models: a
/// signed bundle can't change, so they live in Application Support where the
/// app can add and remove them at any time.
public struct ModelStore: Sendable {
    public static let packageExtension = "mlpackage"

    public let directory: URL
    /// Compiled `.mlmodelc` cache that has to go when its package goes.
    public let compiledDirectory: URL

    public init(
        directory: URL = ModelStore.defaultDirectory,
        compiledDirectory: URL = CoreMLLoader.compiledDirectory
    ) {
        self.directory = directory
        self.compiledDirectory = compiledDirectory
    }

    /// `Application Support/HumanDetector/Models`, inside the app's container
    /// when it runs sandboxed.
    public static var defaultDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("HumanDetector/Models", isDirectory: true)
    }

    /// Where a sandboxed build of the app keeps its models. The CLI isn't
    /// sandboxed, so it can use what the app downloaded.
    public static var sandboxedAppDirectory: URL {
        realHomeDirectory
            .appendingPathComponent("Library/Containers/com.humandetector.app/Data/Library/Application Support/HumanDetector/Models", isDirectory: true)
    }

    /// The user's real home, not the container a sandboxed process sees.
    private static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public func packageURL(for stem: String) -> URL {
        directory.appendingPathComponent(stem).appendingPathExtension(Self.packageExtension)
    }

    /// Installed packages, sorted by stem. Hidden staging folders are skipped.
    public func installed() -> [InstalledModel] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { ["mlpackage", "mlmodelc"].contains($0.pathExtension) }
            .map { InstalledModel(stem: $0.deletingPathExtension().lastPathComponent, url: $0, bytes: Self.size(of: $0)) }
            .sorted { $0.stem < $1.stem }
    }

    public func isInstalled(_ stem: String) -> Bool {
        installed().contains { $0.stem == stem }
    }

    /// Delete a model and its compiled cache.
    public func remove(stem: String) throws {
        let fm = FileManager.default
        for ext in ["mlpackage", "mlmodelc"] {
            let url = directory.appendingPathComponent(stem).appendingPathExtension(ext)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        removeCompiled(stem: stem)
    }

    /// A fresh folder on the same volume as the store, so a finished package
    /// can be moved into place atomically. The caller deletes it.
    public func makeStagingDirectory() throws -> URL {
        let url = directory
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Move a complete package into the store, replacing any older copy.
    @discardableResult
    public func install(staged: URL, stem: String) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: staged.appendingPathComponent("Manifest.json").path) else {
            throw ModelStoreError.notAModelPackage(staged.lastPathComponent)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = packageURL(for: stem)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
        removeCompiled(stem: stem)
        return destination
    }

    /// Copy `.mlpackage`s into the store. Each URL may be a package itself or
    /// a folder containing packages. Returns the imported stems.
    @discardableResult
    public func importPackages(from urls: [URL]) throws -> [String] {
        let fm = FileManager.default
        var packages: [URL] = []
        for url in urls {
            if url.pathExtension == Self.packageExtension {
                packages.append(url)
            } else if let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                packages += entries.filter { $0.pathExtension == Self.packageExtension }
            }
        }
        guard !packages.isEmpty else { throw ModelStoreError.nothingToImport }

        let staging = try makeStagingDirectory()
        defer { try? fm.removeItem(at: staging) }
        var stems: [String] = []
        for package in packages.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let stem = package.deletingPathExtension().lastPathComponent
            let copy = staging.appendingPathComponent(package.lastPathComponent)
            try fm.copyItem(at: package, to: copy)
            try install(staged: copy, stem: stem)
            stems.append(stem)
        }
        return stems
    }

    private func removeCompiled(stem: String) {
        let compiled = compiledDirectory.appendingPathComponent(stem).appendingPathExtension("mlmodelc")
        try? FileManager.default.removeItem(at: compiled)
    }

    static func size(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}

/// Names and ordering for the models the app knows about.
public enum ModelCatalog {
    public static let scrfdStem = "scrfd_10g_bnkps"

    /// Every person-model stem the export script can produce, smallest first.
    private static let personStems: [(stem: String, family: ModelFamily, size: ModelSize, task: ModelTask)] = {
        var stems: [(String, ModelFamily, ModelSize, ModelTask)] = []
        for family in ModelFamily.allCases {
            for task in ModelTask.allCases {
                for size in ModelSize.allCases {
                    stems.append(("\(family.rawValue)\(size.rawValue)-\(task.rawValue)", family, size, task))
                }
            }
        }
        return stems
    }()

    public static func displayName(for stem: String) -> String {
        if stem == scrfdStem { return "SCRFD face detector" }
        if let match = personStems.first(where: { $0.stem == stem }) {
            let size = match.size.displayName.replacingOccurrences(of: " (\(match.size.rawValue))", with: "")
            let task = match.task == .seg ? "segmentation" : "detection"
            return "\(match.family.displayName) \(size) · \(task)"
        }
        return stem
    }

    /// Person models in family/task/size order, then SCRFD, then anything else.
    public static func sortKey(for stem: String) -> (Int, String) {
        if let index = personStems.firstIndex(where: { $0.stem == stem }) { return (index, stem) }
        if stem == scrfdStem { return (personStems.count, stem) }
        return (personStems.count + 1, stem)
    }

    /// The downloadable models a config needs: the person model unless a
    /// custom path overrides it, and SCRFD when the face provider uses it.
    public static func stemsNeeded(by config: AppConfig) -> [String] {
        var stems: [String] = []
        if config.person.enabled, (config.person.customModelPath ?? "").isEmpty {
            stems.append(config.person.modelStem)
        }
        if config.face.enabled, config.face.provider != .vision, (config.face.scrfdModelPath ?? "").isEmpty {
            stems.append(scrfdStem)
        }
        return stems
    }
}

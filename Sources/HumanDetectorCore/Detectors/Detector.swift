import Foundation
import CoreGraphics

public enum DetectorError: Error, LocalizedError {
    case modelNotFound(String)
    case modelLoadFailed(String, underlying: Error)
    case unsupportedOutput(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let stem):
            return "Model '\(stem)' isn't installed. Download it from the Models card on the Dashboard, or import an .mlpackage."
        case .modelLoadFailed(let stem, let error):
            return "Failed to load model '\(stem)': \(error.localizedDescription)"
        case .unsupportedOutput(let detail):
            return "Unsupported model output layout: \(detail)"
        case .inferenceFailed(let detail):
            return "Inference failed: \(detail)"
        }
    }
}

/// Person detector contract.
public protocol PersonDetecting: AnyObject {
    func detect(in image: CGImage) throws -> [Detection]
    var modelDescription: String { get }
}

/// Face detector contract.
public protocol FaceDetecting: AnyObject {
    func detect(in image: CGImage) throws -> [Detection]
    var modelDescription: String { get }
}

/// Finds model packages: the app's model store first, then (for the CLI) the
/// sandboxed app's store and a `Models/` folder next to the working directory.
/// Nothing is bundled inside the app.
public enum ModelRegistry {
    public static func personModelURL(for config: PersonConfig) -> URL? {
        if let custom = config.customModelPath, !custom.isEmpty {
            let url = URL(fileURLWithPath: custom)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return locate(stem: config.modelStem)
    }

    public static func scrfdModelURL(for config: FaceConfig) -> URL? {
        if let custom = config.scrfdModelPath, !custom.isEmpty {
            let url = URL(fileURLWithPath: custom)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return locate(stem: ModelCatalog.scrfdStem)
    }

    /// Look for `<stem>.mlpackage` or `<stem>.mlmodelc` in the usual places.
    public static func locate(stem: String) -> URL? {
        let candidates = ["mlpackage", "mlmodelc", "mlmodel"]
        for root in searchRoots() {
            for ext in candidates {
                let url = root.appendingPathComponent(stem).appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    public static func searchRoots() -> [URL] {
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment["HUMAN_DETECTOR_MODELS"], !env.isEmpty {
            roots.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        roots.append(ModelStore.defaultDirectory)
        if ModelStore.sandboxedAppDirectory != ModelStore.defaultDirectory {
            roots.append(ModelStore.sandboxedAppDirectory)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        roots.append(cwd.appendingPathComponent("Models", isDirectory: true))
        roots.append(cwd.appendingPathComponent("Resources/Models", isDirectory: true))
        return roots
    }
}

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
            return "No bundled model found for '\(stem)'. Add the .mlpackage to Resources/Models or set a custom path."
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

/// Finds model packages wherever they end up: inside the app bundle, an
/// adjacent `Models/` folder during development, or an explicit override.
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
        return locate(stem: "scrfd_10g_bnkps")
    }

    /// Look for `<stem>.mlpackage` or `<stem>.mlmodelc` in the usual places.
    public static func locate(stem: String) -> URL? {
        let candidates = ["mlpackage", "mlmodelc", "mlmodel"]
        for root in searchRoots() {
            for ext in candidates {
                let url = root.appendingPathComponent(stem).appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            // Xcode may flatten a package into a compiled model directory.
            if let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                if let match = entries.first(where: { $0.deletingPathExtension().lastPathComponent == stem }) {
                    return match
                }
            }
        }
        return nil
    }

    public static func searchRoots() -> [URL] {
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment["HUMAN_DETECTOR_MODELS"], !env.isEmpty {
            roots.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        let bundle = Bundle.main
        if let resource = bundle.resourceURL {
            roots.append(resource.appendingPathComponent("Models", isDirectory: true))
            roots.append(resource)
        }
        roots.append(bundle.bundleURL.appendingPathComponent("Contents/Resources/Models", isDirectory: true))
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Models", isDirectory: true))
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Models", isDirectory: true))
        if let support = ConfigStore.defaultURL()?.deletingLastPathComponent() {
            roots.append(support.appendingPathComponent("Models", isDirectory: true))
        }
        return roots
    }
}

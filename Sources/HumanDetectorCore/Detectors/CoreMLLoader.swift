import Foundation
import CoreML

public extension ComputeUnit {
    var mlComputeUnits: MLComputeUnits {
        switch self {
        case .cpuOnly: return .cpuOnly
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .cpuAndGPU: return .cpuAndGPU
        case .all: return .all
        }
    }
}

/// Compiles and caches `.mlpackage` models so we pay the compile cost once,
/// not on every launch.
public enum CoreMLLoader {
    public static func loadModel(at url: URL, computeUnit: ComputeUnit) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnit.mlComputeUnits

        let loadURL: URL
        if url.pathExtension == "mlpackage" {
            loadURL = try compiledURL(for: url)
        } else {
            loadURL = url
        }
        do {
            return try MLModel(contentsOf: loadURL, configuration: configuration)
        } catch {
            throw DetectorError.modelLoadFailed(url.deletingPathExtension().lastPathComponent, underlying: error)
        }
    }

    /// Compile into Application Support so repeat launches are fast, and
    /// recompile when the source package is newer.
    public static func compiledURL(for package: URL) throws -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base
            .appendingPathComponent("HumanDetector/CompiledModels", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let stem = package.deletingPathExtension().lastPathComponent
        let dest = dir.appendingPathComponent(stem).appendingPathExtension("mlmodelc")

        if fm.fileExists(atPath: dest.path), !isStale(source: package, compiled: dest) {
            return dest
        }
        let compiled = try MLModel.compileModel(at: package)
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: compiled, to: dest)
        return dest
    }

    private static func isStale(source: URL, compiled: URL) -> Bool {
        let fm = FileManager.default
        guard
            let sourceDate = (try? fm.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date,
            let compiledDate = (try? fm.attributesOfItem(atPath: compiled.path))?[.modificationDate] as? Date
        else { return false }
        return sourceDate > compiledDate
    }
}

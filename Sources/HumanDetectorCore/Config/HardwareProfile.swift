import Foundation

/// What we know about the machine we are running on.
///
/// There is deliberately no hard-coded "M6" anywhere: Apple ships new chips
/// faster than this file can be edited, so we detect memory and cores and let
/// the preset table decide. That keeps the same binary correct on an M1
/// laptop today and a future high-memory desktop.
public struct HardwareProfile: Sendable, Equatable {
    public let totalMemoryGB: Double
    public let chipName: String
    public let modelIdentifier: String
    public let performanceCores: Int
    public let efficiencyCores: Int

    public var physicalCores: Int { performanceCores + efficiencyCores }

    /// Human-readable summary for the UI banner.
    public var summary: String {
        let cores = performanceCores > 0
            ? "\(performanceCores)P+\(efficiencyCores)E cores"
            : "\(physicalCores) cores"
        return "\(chipName) · \(Int(totalMemoryGB.rounded())) GB · \(cores)"
    }

    public static func current() -> HardwareProfile {
        let memoryBytes = Sysctl.uint64("hw.memsize") ?? 0
        let chip = Sysctl.string("machdep.cpu.brand_string") ?? chipFromModelID()
        let model = Sysctl.string("hw.model") ?? "Mac"
        let perf = Sysctl.uint32("hw.perflevel0.physicalcpu").map(Int.init) ?? 0
        let eff = Sysctl.uint32("hw.perflevel1.physicalcpu").map(Int.init) ?? 0
        return HardwareProfile(
            totalMemoryGB: Double(memoryBytes) / 1_073_741_824.0,
            chipName: chip,
            modelIdentifier: model,
            performanceCores: perf,
            efficiencyCores: eff
        )
    }

    private static func chipFromModelID() -> String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }
}

/// Tiny wrapper around `sysctl` so we do not shell out.
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func uint32(_ name: String) -> UInt32? {
        var value: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

/// The tuned defaults a preset applies to a config.
public struct PresetTuning: Sendable, Equatable {
    public var personSize: ModelSize
    public var imageSize: Int
    public var concurrency: Int
    public var prefetch: Int
    public var computeUnit: ComputeUnit
    public var note: String
}

public enum PresetResolver {
    /// Resolve the concrete tuning for a preset, given the host hardware.
    public static func tuning(for preset: HardwarePreset, hardware: HardwareProfile) -> PresetTuning {
        switch preset {
        case .lite:
            return PresetTuning(
                personSize: .n,
                imageSize: 640,
                concurrency: 2,
                prefetch: 4,
                computeUnit: .cpuAndNeuralEngine,
                note: "8 GB class: nano model at 640 px, low concurrency."
            )
        case .balanced:
            return PresetTuning(
                personSize: .m,
                imageSize: 960,
                concurrency: 4,
                prefetch: 8,
                computeUnit: .cpuAndNeuralEngine,
                note: "16 GB class: medium model at 960 px. Good dev-machine default."
            )
        case .max:
            return PresetTuning(
                personSize: .x,
                imageSize: 1280,
                concurrency: 6,
                prefetch: 12,
                computeUnit: .cpuAndNeuralEngine,
                note: "24 GB+ class: X-Large model at 1280 px — best recall."
            )
        case .custom:
            return PresetTuning(
                personSize: .x,
                imageSize: 1280,
                concurrency: 4,
                prefetch: 8,
                computeUnit: .cpuAndNeuralEngine,
                note: "Custom tuning — values left untouched."
            )
        case .auto:
            return tuning(for: autoPreset(for: hardware), hardware: hardware)
        }
    }

    /// Pick a preset from installed memory. Thresholds are intentionally
    /// generous at the top so a 24 GB machine always gets the best model.
    public static func autoPreset(for hardware: HardwareProfile) -> HardwarePreset {
        switch hardware.totalMemoryGB {
        case ..<12: return .lite
        case ..<22: return .balanced
        default: return .max
        }
    }

    /// Apply a preset to a config in place (does not touch IO or thresholds).
    public static func apply(_ preset: HardwarePreset, hardware: HardwareProfile, to config: inout AppConfig) {
        let tuning = tuning(for: preset, hardware: hardware)
        config.person.size = tuning.personSize
        config.person.imageSize = tuning.imageSize
        config.person.computeUnit = tuning.computeUnit
        config.performance.preset = preset
        config.performance.concurrency = tuning.concurrency
        config.performance.prefetch = tuning.prefetch
    }
}

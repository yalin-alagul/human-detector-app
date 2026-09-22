import Foundation
import CoreGraphics

/// One sampled image plus everything inference learned about it.
public struct CalibrationItem: Sendable {
    public var url: URL
    public var relativePath: String
    public var signals: ImageSignals
}

/// Runs the detector suite over a random sample and hands back the raw signals.
///
/// The point is caching: once a sample has been analyzed, the calibration UI
/// re-runs `DecisionEngine` on these stored signals as sliders move. Threshold
/// changes are then instant and free of extra inference.
public enum Calibrator {
    /// Deterministic, seedable random sampling so a calibration run is repeatable.
    public static func sample(
        root: URL,
        count: Int,
        seed: UInt64,
        extensions: Set<String>
    ) throws -> [(url: URL, relativePath: String)] {
        let all = try ImageEnumerator.enumerate(root: root, extensions: extensions)
        guard all.count > count else { return all }
        var rng = SplitMix64(seed: seed)
        var pool = all
        pool.shuffle(using: &rng)
        return Array(pool.prefix(count))
    }

    /// Analyze a set of files sequentially. Sequential on purpose: calibration
    /// samples are small and we would rather report steady progress than
    /// saturate the machine.
    public static func analyze(
        files: [(url: URL, relativePath: String)],
        config: AppConfig,
        suite: DetectorSuite,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [CalibrationItem] {
        var items: [CalibrationItem] = []
        items.reserveCapacity(files.count)
        let decodeCap = max(config.person.imageSize, suite.personInputSize ?? 0)

        for (index, file) in files.enumerated() {
            if Task.isCancelled { break }
            let signals: ImageSignals
            do {
                let loaded = try ImageLoader.load(at: file.url, maxPixelSize: decodeCap)
                signals = try suite.analyze(image: loaded.cgImage, thresholds: config.thresholds)
            } catch {
                signals = .empty
            }
            items.append(CalibrationItem(url: file.url, relativePath: file.relativePath, signals: signals))
            onProgress?(index + 1, files.count)
        }
        return items
    }

    /// Re-classify cached items under new thresholds — no inference involved.
    public static func reevaluate(
        items: [CalibrationItem],
        thresholds: ThresholdConfig,
        goal: DetectionGoal = .removeHumans
    ) -> [(item: CalibrationItem, decision: Decision)] {
        items.map { ($0, DecisionEngine.decide(signals: $0.signals, thresholds: thresholds, goal: goal)) }
    }
}

/// Tiny deterministic RNG (SplitMix64) so sampling is reproducible without
/// pulling in a dependency.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

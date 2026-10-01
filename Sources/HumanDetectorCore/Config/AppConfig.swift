import Foundation

/// The complete, serializable configuration for a scan run.
///
/// Every value here is intentionally explicit so the same struct can be edited
/// in the GUI, persisted as JSON, or hand-written for the headless CLI.
public struct AppConfig: Codable, Sendable, Equatable {
    /// Optional so configs written before this setting existed still decode.
    public var goal: DetectionGoal?
    public var io: IOConfig
    public var person: PersonConfig
    public var face: FaceConfig
    public var signals: SignalConfig
    public var thresholds: ThresholdConfig
    public var panorama: PanoramaConfig
    public var performance: PerformanceConfig
    public var behavior: BehaviorConfig
    public var qa: QAConfig
    public var ui: UIConfig
    /// Optional so configs written before model downloads existed still decode.
    public var modelSource: ModelSource?

    /// The active goal, with a safe fallback for older config files.
    public var resolvedGoal: DetectionGoal { goal ?? .keepHumans }

    /// Where models download from, with defaults for older config files.
    public var resolvedModelSource: ModelSource { modelSource ?? ModelSource() }

    public init(
        goal: DetectionGoal? = .keepHumans,
        io: IOConfig = .init(),
        person: PersonConfig = .init(),
        face: FaceConfig = .init(),
        signals: SignalConfig = .init(),
        thresholds: ThresholdConfig = .init(),
        panorama: PanoramaConfig = .init(),
        performance: PerformanceConfig = .init(),
        behavior: BehaviorConfig = .init(),
        qa: QAConfig = .init(),
        ui: UIConfig = .init(),
        modelSource: ModelSource? = nil
    ) {
        self.goal = goal
        self.io = io
        self.person = person
        self.face = face
        self.signals = signals
        self.thresholds = thresholds
        self.panorama = panorama
        self.performance = performance
        self.behavior = behavior
        self.qa = qa
        self.ui = ui
        self.modelSource = modelSource
    }
}

// MARK: - Model source

/// The Hugging Face model repo the app downloads `.mlpackage`s from:
/// `huggingface.co/<username>/<repository>`. The access token is not stored
/// here; the app keeps it in the Keychain.
public struct ModelSource: Codable, Sendable, Equatable {
    public static let defaultRepository = "human-detector-models"

    public var huggingFaceUsername: String
    public var huggingFaceRepo: String

    public init(huggingFaceUsername: String = "", huggingFaceRepo: String = ModelSource.defaultRepository) {
        self.huggingFaceUsername = huggingFaceUsername
        self.huggingFaceRepo = huggingFaceRepo
    }

    /// `username/repository`, or nil until a username is set.
    public var repoID: String? {
        let user = huggingFaceUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = huggingFaceRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { return nil }
        return "\(user)/\(repo.isEmpty ? Self.defaultRepository : repo)"
    }
}

// MARK: - IO

public struct IOConfig: Codable, Sendable, Equatable {
    public var inputPath: String
    public var outputPath: String
    public var moveMode: MoveMode
    public var preserveRelativePaths: Bool
    public var collisionPolicy: CollisionPolicy
    public var supportedExtensions: [String]
    public var skipCorruptFiles: Bool

    public init(
        inputPath: String = "",
        outputPath: String = "",
        moveMode: MoveMode = .move,
        preserveRelativePaths: Bool = true,
        collisionPolicy: CollisionPolicy = .suffix,
        supportedExtensions: [String] = IOConfig.defaultExtensions,
        skipCorruptFiles: Bool = true
    ) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.moveMode = moveMode
        self.preserveRelativePaths = preserveRelativePaths
        self.collisionPolicy = collisionPolicy
        self.supportedExtensions = supportedExtensions
        self.skipCorruptFiles = skipCorruptFiles
    }

    public static let defaultExtensions: [String] = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
        "bmp", "gif", "webp", "dng", "arw", "cr2", "nef", "raf",
    ]
}

// MARK: - Person model

public struct PersonConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var family: ModelFamily
    public var size: ModelSize
    public var task: ModelTask
    /// Overrides the installed model when non-nil (path to an `.mlpackage` or `.mlmodelc`).
    public var customModelPath: String?
    /// Square inference resolution. Higher catches smaller figures and costs more time.
    public var imageSize: Int
    public var confidenceThreshold: Float
    public var iouThreshold: Float
    public var computeUnit: ComputeUnit
    /// When false, mask coefficients are decoded but masks are not rasterized (faster).
    public var computeMasks: Bool
    /// COCO class index to keep. Person is always 0.
    public var targetClassIndex: Int
    /// Maximum number of detections to keep after NMS.
    public var maxDetections: Int

    public init(
        enabled: Bool = true,
        family: ModelFamily = .yolo26,
        size: ModelSize = .x,
        task: ModelTask = .seg,
        customModelPath: String? = nil,
        imageSize: Int = 1280,
        confidenceThreshold: Float = 0.25,
        iouThreshold: Float = 0.45,
        computeUnit: ComputeUnit = .cpuAndNeuralEngine,
        computeMasks: Bool = false,
        targetClassIndex: Int = 0,
        maxDetections: Int = 100
    ) {
        self.enabled = enabled
        self.family = family
        self.size = size
        self.task = task
        self.customModelPath = customModelPath
        self.imageSize = imageSize
        self.confidenceThreshold = confidenceThreshold
        self.iouThreshold = iouThreshold
        self.computeUnit = computeUnit
        self.computeMasks = computeMasks
        self.targetClassIndex = targetClassIndex
        self.maxDetections = maxDetections
    }

    /// The model file stem, e.g. `yolo26x-seg`.
    public var modelStem: String {
        "\(family.rawValue)\(size.rawValue)-\(task.rawValue)"
    }
}

// MARK: - Face model

public struct FaceConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var provider: FaceProvider
    public var scrfdModelPath: String?
    public var computeUnit: ComputeUnit
    /// Minimum face size in pixels of the input image; smaller faces are ignored.
    public var minimumFaceSize: Int

    public init(
        enabled: Bool = true,
        provider: FaceProvider = .vision,
        scrfdModelPath: String? = nil,
        computeUnit: ComputeUnit = .cpuAndNeuralEngine,
        minimumFaceSize: Int = 12
    ) {
        self.enabled = enabled
        self.provider = provider
        self.scrfdModelPath = scrfdModelPath
        self.computeUnit = computeUnit
        self.minimumFaceSize = minimumFaceSize
    }
}

// MARK: - Extra Vision signals

public struct SignalConfig: Codable, Sendable, Equatable {
    /// `VNDetectHumanRectanglesRequest` on Stage 1 negatives.
    public var visionHumanRects: Bool
    /// `VNDetectHumanBodyPoseRequest` on Stage 1 negatives.
    public var visionBodyPose: Bool

    public init(visionHumanRects: Bool = true, visionBodyPose: Bool = true) {
        self.visionHumanRects = visionHumanRects
        self.visionBodyPose = visionBodyPose
    }
}

// MARK: - Thresholds

public struct ThresholdConfig: Codable, Sendable, Equatable {
    public var yoloTrash: Float
    public var yoloReviewLow: Float
    public var faceTrash: Float
    public var faceReviewLow: Float
    public var visionHumanTrash: Float
    public var visionHumanReviewLow: Float
    public var visionPoseTrash: Float
    public var visionPoseReviewLow: Float
    /// Detections whose box area is below this fraction of the image are ignored.
    public var minimumAreaFraction: Float

    public init(
        yoloTrash: Float = 0.25,
        yoloReviewLow: Float = 0.10,
        faceTrash: Float = 0.50,
        faceReviewLow: Float = 0.30,
        visionHumanTrash: Float = 0.60,
        visionHumanReviewLow: Float = 0.35,
        visionPoseTrash: Float = 0.50,
        visionPoseReviewLow: Float = 0.25,
        minimumAreaFraction: Float = 0.00005
    ) {
        self.yoloTrash = yoloTrash
        self.yoloReviewLow = yoloReviewLow
        self.faceTrash = faceTrash
        self.faceReviewLow = faceReviewLow
        self.visionHumanTrash = visionHumanTrash
        self.visionHumanReviewLow = visionHumanReviewLow
        self.visionPoseTrash = visionPoseTrash
        self.visionPoseReviewLow = visionPoseReviewLow
        self.minimumAreaFraction = minimumAreaFraction
    }
}

// MARK: - Panorama

public struct PanoramaConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Long-edge pixel threshold above which an image is tiled.
    public var longEdgeThreshold: Int
    public var tileSize: Int
    /// Fraction of overlap between adjacent tiles (0…0.5).
    public var overlap: Double

    public init(
        enabled: Bool = true,
        longEdgeThreshold: Int = 4000,
        tileSize: Int = 1280,
        overlap: Double = 0.2
    ) {
        self.enabled = enabled
        self.longEdgeThreshold = longEdgeThreshold
        self.tileSize = tileSize
        self.overlap = overlap
    }
}

// MARK: - Performance

public struct PerformanceConfig: Codable, Sendable, Equatable {
    public var preset: HardwarePreset
    /// Number of images decoded and inferred concurrently.
    public var concurrency: Int
    /// Images whose decoded pixels are prefetched ahead of inference.
    public var prefetch: Int
    /// Pause when the machine reports serious/thermal throttling.
    public var pauseOnThermalThrottle: Bool
    /// Refuse to continue if estimated free memory drops below this many GB.
    public var minimumFreeMemoryGB: Double

    public init(
        preset: HardwarePreset = .auto,
        concurrency: Int = 4,
        prefetch: Int = 8,
        pauseOnThermalThrottle: Bool = true,
        minimumFreeMemoryGB: Double = 1.5
    ) {
        self.preset = preset
        self.concurrency = concurrency
        self.prefetch = prefetch
        self.pauseOnThermalThrottle = pauseOnThermalThrottle
        self.minimumFreeMemoryGB = minimumFreeMemoryGB
    }
}

// MARK: - Behaviour

public struct BehaviorConfig: Codable, Sendable, Equatable {
    public var resume: Bool
    public var deduplicateByHash: Bool
    public var dryRun: Bool
    public var writeCSV: Bool
    public var writeJSONL: Bool
    public var writeSidecarJSON: Bool
    /// Move files into `clean/`, `review/`, `trash/`. When false, verdicts are only logged.
    public var quarantine: Bool

    public init(
        resume: Bool = true,
        deduplicateByHash: Bool = true,
        dryRun: Bool = false,
        writeCSV: Bool = true,
        writeJSONL: Bool = true,
        writeSidecarJSON: Bool = false,
        quarantine: Bool = true
    ) {
        self.resume = resume
        self.deduplicateByHash = deduplicateByHash
        self.dryRun = dryRun
        self.writeCSV = writeCSV
        self.writeJSONL = writeJSONL
        self.writeSidecarJSON = writeSidecarJSON
        self.quarantine = quarantine
    }
}

// MARK: - QA

public struct QAConfig: Codable, Sendable, Equatable {
    public var calibrationSampleSize: Int
    public var calibrationSeed: UInt64
    public var spotCheckSampleSize: Int
    public var histogramBins: Int

    public init(
        calibrationSampleSize: Int = 300,
        calibrationSeed: UInt64 = 0xC0FFEE,
        spotCheckSampleSize: Int = 100,
        histogramBins: Int = 50
    ) {
        self.calibrationSampleSize = calibrationSampleSize
        self.calibrationSeed = calibrationSeed
        self.spotCheckSampleSize = spotCheckSampleSize
        self.histogramBins = histogramBins
    }
}

// MARK: - UI

public struct UIConfig: Codable, Sendable, Equatable {
    public var thumbnailSize: Double
    public var showBoxes: Bool
    public var showMasks: Bool
    public var showHeatmap: Bool
    public var confirmBeforeMove: Bool

    public init(
        thumbnailSize: Double = 160,
        showBoxes: Bool = true,
        showMasks: Bool = true,
        showHeatmap: Bool = true,
        confirmBeforeMove: Bool = true
    ) {
        self.thumbnailSize = thumbnailSize
        self.showBoxes = showBoxes
        self.showMasks = showMasks
        self.showHeatmap = showHeatmap
        self.confirmBeforeMove = confirmBeforeMove
    }
}

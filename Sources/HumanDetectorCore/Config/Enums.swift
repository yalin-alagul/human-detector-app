import Foundation

// MARK: - Model selection

public enum ModelFamily: String, Codable, Sendable, CaseIterable, Identifiable {
    case yolo26
    case yolo11

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .yolo26: return "YOLO26"
        case .yolo11: return "YOLO11"
        }
    }
}

public enum ModelSize: String, Codable, Sendable, CaseIterable, Identifiable {
    case n, s, m, l, x

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .n: return "Nano (n)"
        case .s: return "Small (s)"
        case .m: return "Medium (m)"
        case .l: return "Large (l)"
        case .x: return "X-Large (x)"
        }
    }

    /// Relative accuracy/speed rank. Higher is more accurate and slower.
    public var rank: Int {
        switch self {
        case .n: return 0
        case .s: return 1
        case .m: return 2
        case .l: return 3
        case .x: return 4
        }
    }
}

public enum ModelTask: String, Codable, Sendable, CaseIterable, Identifiable {
    case seg
    case detect

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .seg: return "Instance segmentation"
        case .detect: return "Detection (boxes)"
        }
    }
}

public enum ComputeUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case cpuOnly
    case cpuAndNeuralEngine
    case cpuAndGPU
    case all

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cpuOnly: return "CPU only"
        case .cpuAndNeuralEngine: return "CPU + Neural Engine (recommended)"
        case .cpuAndGPU: return "CPU + GPU"
        case .all: return "All (CPU + GPU + ANE)"
        }
    }
}

// MARK: - Pipeline behaviour

public enum HardwarePreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto
    case lite
    case balanced
    case max
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Auto (detect hardware)"
        case .lite: return "Lite (8 GB)"
        case .balanced: return "Balanced (16 GB)"
        case .max: return "Maximum (24 GB+)"
        case .custom: return "Custom"
        }
    }

    /// Fits in a segmented control without clipping.
    public var shortName: String {
        switch self {
        case .auto: return "Auto"
        case .lite: return "Lite"
        case .balanced: return "Balanced"
        case .max: return "Max"
        case .custom: return "Custom"
        }
    }
}

public enum FaceProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case vision
    case scrfd
    case both

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vision: return "Vision (built-in)"
        case .scrfd: return "SCRFD (CoreML)"
        case .both: return "Both"
        }
    }
}

public enum MoveMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case move
    case copy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .move: return "Move (quarantine)"
        case .copy: return "Copy (non-destructive)"
        }
    }
}

public enum CollisionPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case suffix
    case hashSuffix
    case skip
    case overwrite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .suffix: return "Append (1), (2)…"
        case .hashSuffix: return "Append short hash"
        case .skip: return "Skip existing"
        case .overwrite: return "Overwrite"
        }
    }
}

/// Which side of the dataset you want to keep.
///
/// This flips the meaning of the verdicts, not the detectors:
/// - `removeHumans` — keep photos with nobody in them (the original spec).
/// - `keepHumans`   — keep photos containing people; photos with nobody go to `trash/`.
public enum DetectionGoal: String, Codable, Sendable, CaseIterable, Identifiable {
    case removeHumans
    case keepHumans

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .removeHumans: return "Remove people (keep empty photos)"
        case .keepHumans: return "Keep people (trash empty photos)"
        }
    }

    public var shortName: String {
        switch self {
        case .removeHumans: return "Remove people"
        case .keepHumans: return "Keep people"
        }
    }

    /// What lands in each folder, for UI help text.
    public var folderExplanation: String {
        switch self {
        case .removeHumans:
            return "clean = no people · review = unsure · trash = people detected"
        case .keepHumans:
            return "clean = people detected · review = unsure · trash = no people (delete these)"
        }
    }
}

public enum Verdict: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case clean
    case review
    case trash
    case skipped
    case failed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clean: return "Clean"
        case .review: return "Review"
        case .trash: return "Trash"
        case .skipped: return "Skipped"
        case .failed: return "Failed"
        }
    }

    /// Folder name for the three primary verdicts.
    public var folderName: String? {
        switch self {
        case .clean: return "clean"
        case .review: return "review"
        case .trash: return "trash"
        case .skipped, .failed: return nil
        }
    }
}

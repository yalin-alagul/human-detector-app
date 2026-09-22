import Foundation
import CoreGraphics

/// A normalized bounding box using Vision's convention: origin bottom-left,
/// values in 0…1 relative to image dimensions.
public struct BoundingBox: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var area: Double { max(0, width) * max(0, height) }

    /// Intersection-over-union against another normalized box.
    public func iou(_ other: BoundingBox) -> Double {
        let a = rect
        let b = other.rect
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }
        let interArea = Double(inter.width * inter.height)
        let union = area + other.area - interArea
        return union <= 0 ? 0 : interArea / union
    }
}

/// A dense float mask at some (usually low) resolution.
public struct MaskData: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        self.width = width
        self.height = height
        self.values = values
    }
}

/// One detector output.
public struct Detection: Sendable, Equatable {
    public var label: String
    public var confidence: Float
    public var box: BoundingBox
    public var mask: MaskData?

    public init(label: String, confidence: Float, box: BoundingBox, mask: MaskData? = nil) {
        self.label = label
        self.confidence = confidence
        self.box = box
        self.mask = mask
    }
}

/// Everything the pipeline learned about one image, independent of thresholds.
/// Keeping raw scores here is what lets the calibration UI re-classify without
/// re-running inference.
public struct ImageSignals: Sendable, Equatable {
    public var personDetections: [Detection]
    public var faces: [Detection]
    public var humanRects: [Detection]
    public var bodyPoses: [Detection]
    public var tiled: Bool

    public init(
        personDetections: [Detection] = [],
        faces: [Detection] = [],
        humanRects: [Detection] = [],
        bodyPoses: [Detection] = [],
        tiled: Bool = false
    ) {
        self.personDetections = personDetections
        self.faces = faces
        self.humanRects = humanRects
        self.bodyPoses = bodyPoses
        self.tiled = tiled
    }

    public var personTop: Float { personDetections.map(\.confidence).max() ?? 0 }
    public var faceTop: Float { faces.map(\.confidence).max() ?? 0 }
    public var humanRectTop: Float { humanRects.map(\.confidence).max() ?? 0 }
    public var bodyPoseTop: Float { bodyPoses.map(\.confidence).max() ?? 0 }

    public static let empty = ImageSignals()
}

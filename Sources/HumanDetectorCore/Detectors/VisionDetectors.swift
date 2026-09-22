import Foundation
import Vision
import CoreGraphics

/// Built-in Vision face detector — no extra model, runs on the ANE/GPU.
public final class VisionFaceDetector: FaceDetecting, @unchecked Sendable {
    private let config: FaceConfig

    public init(config: FaceConfig) {
        self.config = config
    }

    public var modelDescription: String { "Vision VNDetectFaceRectanglesRequest" }

    public func detect(in image: CGImage) throws -> [Detection] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw DetectorError.inferenceFailed(error.localizedDescription)
        }
        guard let observations = request.results else { return [] }
        let width = Double(image.width)

        return observations.compactMap { face in
            let box = BoundingBox(face.boundingBox)
            if width * box.width < Double(config.minimumFaceSize) { return nil }
            return Detection(label: "face", confidence: face.confidence, box: box)
        }
    }
}

/// The two cheap Vision signals we run on Stage-1 negatives to recover bodies
/// the person model may have missed. Both are free (no model download).
public final class VisionSignalDetector: @unchecked Sendable {
    private let config: SignalConfig

    public init(config: SignalConfig) {
        self.config = config
    }

    public var modelDescription: String { "Vision human rectangles + body pose" }

    public func humanRectangles(in image: CGImage) -> [Detection] {
        guard config.visionHumanRects else { return [] }
        let request = VNDetectHumanRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        return results.map { observation in
            Detection(
                label: "human",
                confidence: observation.confidence,
                box: BoundingBox(observation.boundingBox)
            )
        }
    }

    public func bodyPoses(in image: CGImage) -> [Detection] {
        guard config.visionBodyPose else { return [] }
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        return results.compactMap { pose in
            guard let points = try? pose.recognizedPoints(.all), !points.isEmpty else { return nil }
            let confident = points.values.filter { $0.confidence > 0.1 }
            guard confident.count >= 4 else { return nil }
            let score = Float(confident.map(\.confidence).reduce(0, +)) / Float(confident.count)
            return Detection(
                label: "pose",
                confidence: min(1, score + Float(confident.count) / 34.0),
                box: box(for: confident)
            )
        }
    }

    /// Body-pose observations have no bounding box, so derive one from joints.
    private func box(for points: [VNRecognizedPoint]) -> BoundingBox {
        let xs = points.map { Double($0.location.x) }
        let ys = points.map { Double($0.location.y) }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            return BoundingBox(x: 0, y: 0, width: 1, height: 1)
        }
        let padding = 0.03
        return BoundingBox(
            x: max(0, minX - padding),
            y: max(0, minY - padding),
            width: min(1, maxX - minX + padding * 2),
            height: min(1, maxY - minY + padding * 2)
        )
    }
}

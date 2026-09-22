import Foundation
import CoreGraphics

/// Builds the detector set described by a config and merges their output into
/// one `ImageSignals` value per image.
public final class DetectorSuite: @unchecked Sendable {
    public let person: PersonDetecting?
    public let faceDetectors: [FaceDetecting]
    public let signals: VisionSignalDetector

    public let personDescription: String
    public let faceDescription: String
    /// Non-fatal problems (for example, SCRFD missing so we fell back to Vision).
    public let notes: [String]

    public var personInputSize: Int? { (person as? PersonDetector)?.inputSize }

    public init(config: AppConfig) throws {
        var notes: [String] = []

        if config.person.enabled {
            let detector = try PersonDetector(config: config.person)
            self.person = detector
            personDescription = detector.modelDescription
        } else {
            self.person = nil
            personDescription = "disabled"
        }

        var faces: [FaceDetecting] = []
        if config.face.enabled {
            switch config.face.provider {
            case .vision:
                faces.append(VisionFaceDetector(config: config.face))
            case .scrfd:
                do {
                    faces.append(try SCRFDFaceDetector(config: config.face))
                } catch {
                    notes.append("SCRFD unavailable (\(error.localizedDescription)); using Vision faces instead.")
                    faces.append(VisionFaceDetector(config: config.face))
                }
            case .both:
                do {
                    faces.append(try SCRFDFaceDetector(config: config.face))
                } catch {
                    notes.append("SCRFD unavailable (\(error.localizedDescription)); Vision faces only.")
                }
                faces.append(VisionFaceDetector(config: config.face))
            }
        }
        self.faceDetectors = faces
        faceDescription = faces.isEmpty ? "disabled" : faces.map(\.modelDescription).joined(separator: " + ")
        self.signals = VisionSignalDetector(config: config.signals)
        self.notes = notes
    }

    /// Run Stage 1, and only if it comes back negative run the Stage 2/3
    /// detectors — matching the cheap-before-expensive ordering in the plan.
    public func analyze(image: CGImage, thresholds: ThresholdConfig) throws -> ImageSignals {
        var result = ImageSignals()

        if let person {
            result.personDetections = try person.detect(in: image)
        } else {
            result.personDetections = []
        }

        let minArea = Double(thresholds.minimumAreaFraction)
        let personTop = DecisionEngine.topScore(result.personDetections, minArea: minArea)
        let stage1Negative = personTop < thresholds.yoloTrash

        guard stage1Negative else { return result }

        for detector in faceDetectors {
            result.faces.append(contentsOf: try detector.detect(in: image))
        }
        result.humanRects = signals.humanRectangles(in: image)
        result.bodyPoses = signals.bodyPoses(in: image)
        return result
    }
}

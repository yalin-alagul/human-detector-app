import Foundation
import CoreML
import Vision
import CoreGraphics

/// YOLO person detector running a CoreML `.mlpackage` on the Neural Engine.
///
/// Inference is serialized with a lock: the ANE is a single unit, so parallel
/// CoreML calls mostly add contention. The pipeline still decodes images and
/// runs face detection concurrently, which is where the real overlap is.
public final class PersonDetector: PersonDetecting, @unchecked Sendable {
    private let vnModel: VNCoreMLModel
    private let config: PersonConfig
    private let lock = NSLock()

    public let modelDescription: String
    /// The model's own input resolution (long edge), read from its description.
    public let inputSize: Int
    /// Human-readable description of the tensor layout we decoded last time.
    public private(set) var lastLayout: String = "not yet run"

    public init(config: PersonConfig) throws {
        guard let url = ModelRegistry.personModelURL(for: config) else {
            throw DetectorError.modelNotFound(config.modelStem)
        }
        let mlModel = try CoreMLLoader.loadModel(at: url, computeUnit: config.computeUnit)
        self.vnModel = try VNCoreMLModel(for: mlModel)
        self.config = config

        let constraint = mlModel.modelDescription
            .inputDescriptionsByName
            .values
            .compactMap { $0.imageConstraint }
            .first
        let size = max(constraint?.pixelsWide ?? config.imageSize, constraint?.pixelsHigh ?? config.imageSize)
        self.inputSize = size
        self.modelDescription = "\(config.modelStem) @ \(size)px (\(config.computeUnit.rawValue))"
    }

    public func detect(in image: CGImage) throws -> [Detection] {
        let request = VNCoreMLRequest(model: vnModel)
        // Normalized coordinates are invariant to independent x/y scaling, so
        // a stretch-to-fill resize leaves box geometry correct.
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        lock.lock()
        defer { lock.unlock() }
        do {
            try handler.perform([request])
        } catch {
            throw DetectorError.inferenceFailed(error.localizedDescription)
        }

        guard let observations = request.results else { return [] }
        var featureOutputs: [(String, MLMultiArray)] = []
        var recognized: [Detection] = []

        for observation in observations {
            if let object = observation as? VNRecognizedObjectObservation {
                if let detection = mapRecognized(object) { recognized.append(detection) }
            } else if let feature = observation as? VNCoreMLFeatureValueObservation,
                      let array = feature.featureValue.multiArrayValue {
                featureOutputs.append((feature.featureName, array))
            }
        }

        if !recognized.isEmpty {
            lastLayout = "recognized-object observations"
            return YOLODecoder.nmsDetections(
                recognized,
                iou: config.iouThreshold,
                maxDetections: config.maxDetections
            )
        }

        guard !featureOutputs.isEmpty else { return [] }

        // Pick the primary detection tensor (most elements among 3D outputs)
        // and the mask protos (4D output, typically [1, 32, H, W]).
        let main = featureOutputs
            .filter { $0.1.shape.count == 3 }
            .max { $0.1.count < $1.1.count }
        guard let main else { return [] }
        let protos = featureOutputs.first { array in
            array.1.shape.count == 4 && (array.0.contains("proto") || array.1.shape[1] == 32)
        }

        let decoded = YOLODecoder.decode(
            main: main.1,
            protos: protos?.1,
            config: config
        )
        lastLayout = decoded.layout
        return decoded.detections
    }

    private func mapRecognized(_ object: VNRecognizedObjectObservation) -> Detection? {
        let label = object.labels.max(by: { $0.confidence < $1.confidence })
        let name = (label?.identifier ?? "person").lowercased()
        guard name.contains("person") || name.contains("human") else { return nil }
        return Detection(
            label: "person",
            confidence: label?.confidence ?? object.confidence,
            box: BoundingBox(object.boundingBox)
        )
    }

}

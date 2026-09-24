import Foundation
import CoreML
import CoreGraphics

/// SCRFD face detector running a CoreML conversion of `scrfd_10g_bnkps.onnx`.
///
/// SCRFD is a dedicated tiny-face specialist. It is optional: Vision's built-in
/// detector handles most libraries without any extra model. This path expects a
/// CoreML package whose outputs are named `score_<stride>`, `bbox_<stride>`,
/// `kps_<stride>` for strides 8/16/32 — `Models/export_models.py` produces
/// exactly that naming. Unnamed outputs are matched by shape instead.
public final class SCRFDFaceDetector: FaceDetecting, @unchecked Sendable {
    private let model: MLModel
    private let inputName: String
    private let inputWidth: Int
    private let inputHeight: Int
    private let scoreThreshold: Float
    private let nmsThreshold: Float = 0.4
    private let lock = NSLock()

    private struct Head {
        var stride: Int
        var scoreName: String
        var bboxName: String
        var kpsName: String?
    }

    private let heads: [Head]

    public init(config: FaceConfig, scoreThreshold: Float = 0.2) throws {
        guard let url = ModelRegistry.scrfdModelURL(for: config) else {
            throw DetectorError.modelNotFound("scrfd_10g_bnkps")
        }
        let model = try CoreMLLoader.loadModel(at: url, computeUnit: config.computeUnit)
        self.model = model
        self.scoreThreshold = scoreThreshold

        guard let input = model.modelDescription.inputDescriptionsByName.first else {
            throw DetectorError.unsupportedOutput("SCRFD model has no inputs")
        }
        self.inputName = input.key
        if let constraint = input.value.imageConstraint {
            self.inputWidth = constraint.pixelsWide
            self.inputHeight = constraint.pixelsHigh
        } else if let array = input.value.multiArrayConstraint, array.shape.count == 4 {
            // NCHW multi-array input produced by our CoreML export.
            self.inputHeight = array.shape[2].intValue
            self.inputWidth = array.shape[3].intValue
        } else {
            throw DetectorError.unsupportedOutput("SCRFD input is neither an image nor an NCHW tensor")
        }

        // Build heads from named outputs.
        var byStride: [Int: (score: String?, bbox: String?, kps: String?)] = [:]
        for key in model.modelDescription.outputDescriptionsByName.keys {
            let parts = key.split(separator: "_")
            guard parts.count == 2, let stride = Int(parts[1]) else { continue }
            switch parts[0] {
            case "score": byStride[stride, default: (nil, nil, nil)].score = key
            case "bbox": byStride[stride, default: (nil, nil, nil)].bbox = key
            case "kps": byStride[stride, default: (nil, nil, nil)].kps = key
            default: break
            }
        }

        // Exports that kept the converter's numeric names (var_717, …): the
        // shape [N, 1|4|10] gives the head kind, and N anchors (two per grid
        // cell) give the stride.
        if byStride.isEmpty {
            for (key, description) in model.modelDescription.outputDescriptionsByName {
                guard let shape = description.multiArrayConstraint?.shape.map(\.intValue),
                      shape.count >= 2, let channels = shape.last else { continue }
                let anchors = shape.dropLast().reduce(1, *)
                guard anchors > 0 else { continue }
                let stride = Int((Double(2 * inputWidth * inputHeight) / Double(anchors)).squareRoot().rounded())
                guard stride > 0, (inputWidth / stride) * (inputHeight / stride) * 2 == anchors else { continue }
                switch channels {
                case 1: byStride[stride, default: (nil, nil, nil)].score = key
                case 4: byStride[stride, default: (nil, nil, nil)].bbox = key
                case 10: byStride[stride, default: (nil, nil, nil)].kps = key
                default: break
                }
            }
        }

        let built: [Head] = byStride.compactMap { stride, names in
            guard let score = names.score, let bbox = names.bbox else { return nil }
            return Head(stride: stride, scoreName: score, bboxName: bbox, kpsName: names.kps)
        }.sorted { $0.stride < $1.stride }

        guard !built.isEmpty else {
            throw DetectorError.unsupportedOutput(
                "SCRFD outputs are neither named score_<stride>/bbox_<stride>/kps_<stride> nor shaped [anchors, 1|4|10]. Re-export with Models/export_models.py, or use the Vision face provider."
            )
        }
        self.heads = built
    }

    public var modelDescription: String {
        "SCRFD \(inputWidth)×\(inputHeight)"
    }

    public func detect(in image: CGImage) throws -> [Detection] {
        guard let inputArray = makeInput(from: image) else {
            throw DetectorError.inferenceFailed("could not build SCRFD input tensor")
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: inputArray)])

        lock.lock()
        defer { lock.unlock() }
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: provider)
        } catch {
            throw DetectorError.inferenceFailed(error.localizedDescription)
        }

        var detections: [Detection] = []
        for head in heads {
            guard let score = output.featureValue(for: head.scoreName)?.multiArrayValue,
                  let bbox = output.featureValue(for: head.bboxName)?.multiArrayValue else { continue }
            detections.append(contentsOf: decodeHead(head, score: score, bbox: bbox))
        }
        return YOLODecoder.nmsDetections(detections, iou: nmsThreshold, maxDetections: 500)
    }

    // MARK: - Decoding

    private func decodeHead(_ head: Head, score: MLMultiArray, bbox: MLMultiArray) -> [Detection] {
        let scoreReader = MultiArrayReader(score)
        let bboxReader = MultiArrayReader(bbox)

        // CoreML exports give either [1, N, C] or the flattened [N, C].
        let scoreRank = scoreReader.shape.count
        let count = scoreRank == 3 ? scoreReader.shape[1] : scoreReader.shape[0]
        let bboxRank = bboxReader.shape.count

        let gridH = inputHeight / head.stride
        let gridW = inputWidth / head.stride
        guard gridH * gridW * 2 == count else { return [] }

        func scoreValue(_ index: Int) -> Float {
            scoreRank == 3 ? scoreReader.float3(0, index, 0) : scoreReader.float([index, 0])
        }

        func bboxValue(_ index: Int, _ channel: Int) -> Float {
            bboxRank == 3 ? bboxReader.float3(0, index, channel) : bboxReader.float([index, channel])
        }

        let stride = Float(head.stride)
        var results: [Detection] = []

        for index in 0..<count {
            let raw = scoreValue(index)
            guard raw >= scoreThreshold else { continue }

            // Anchor centre: two anchors per grid cell.
            let cell = index / 2
            let x = cell % gridW
            let y = cell / gridW
            let cx = Float(x) * stride
            let cy = Float(y) * stride

            let left = bboxValue(index, 0) * stride
            let top = bboxValue(index, 1) * stride
            let right = bboxValue(index, 2) * stride
            let bottom = bboxValue(index, 3) * stride

            let x1 = Double((cx - left) / Float(inputWidth))
            let y1 = Double((cy - top) / Float(inputHeight))
            let x2 = Double((cx + right) / Float(inputWidth))
            let y2 = Double((cy + bottom) / Float(inputHeight))

            // Vision convention: bottom-left origin.
            let box = BoundingBox(
                x: max(0, x1),
                y: max(0, 1 - y2),
                width: max(0, x2 - x1),
                height: max(0, y2 - y1)
            )
            results.append(Detection(label: "face", confidence: raw, box: box))
        }
        return results
    }

    // MARK: - Input tensor

    /// Build an NCHW BGR tensor with SCRFD's (pixel - 127.5) / 128 normalization.
    private func makeInput(from image: CGImage) -> MLMultiArray? {
        guard let pixels = PixelBuffer.rgbBytes(from: image, width: inputWidth, height: inputHeight) else { return nil }
        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: inputHeight), NSNumber(value: inputWidth)],
            dataType: .float32
        ) else { return nil }

        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        let plane = inputHeight * inputWidth
        let blueOffset = 2
        let greenOffset = 1
        let redOffset = 0

        for index in 0..<plane {
            let r = Float(pixels[index * 4 + redOffset])
            let g = Float(pixels[index * 4 + greenOffset])
            let b = Float(pixels[index * 4 + blueOffset])
            pointer[index] = (b - 127.5) / 128.0
            pointer[plane + index] = (g - 127.5) / 128.0
            pointer[2 * plane + index] = (r - 127.5) / 128.0
        }
        return array
    }
}

/// Minimal RGBA byte extraction at a target size for model input tensors.
enum PixelBuffer {
    static func rgbBytes(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        // The drawing must happen inside the closure: the pointer is only valid there.
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? bytes : nil
    }
}

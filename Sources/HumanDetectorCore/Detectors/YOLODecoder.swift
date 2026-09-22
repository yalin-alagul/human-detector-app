import Foundation
import CoreML

/// Fast, dtype-aware element access into an `MLMultiArray`.
///
/// The naive `array[[0, c, i]]` subscript allocates an NSNumber per access and
/// is far too slow when scanning 8400 anchors. We read the raw buffer instead.
final class MultiArrayReader {
    private let pointer: UnsafeRawPointer
    private let dataType: MLMultiArrayDataType
    let shape: [Int]
    let strides: [Int]

    init(_ array: MLMultiArray) {
        self.pointer = UnsafeRawPointer(array.dataPointer)
        self.dataType = array.dataType
        self.shape = array.shape.map { $0.intValue }
        self.strides = array.strides.map { $0.intValue }
    }

    @inline(__always)
    func float(_ indices: [Int]) -> Float {
        var offset = 0
        for (i, stride) in strides.enumerated() {
            offset += indices[i] * stride
        }
        switch dataType {
        case .float32:
            return pointer.loadUnaligned(fromByteOffset: offset * 4, as: Float.self)
        case .float16:
            let bits = pointer.loadUnaligned(fromByteOffset: offset * 2, as: UInt16.self)
            return Float(Float16(bitPattern: bits))
        case .double:
            return Float(pointer.loadUnaligned(fromByteOffset: offset * 8, as: Double.self))
        case .int32:
            return Float(pointer.loadUnaligned(fromByteOffset: offset * 4, as: Int32.self))
        default:
            return 0
        }
    }

    @inline(__always)
    func float3(_ a: Int, _ b: Int, _ c: Int) -> Float {
        float([a, b, c])
    }

    @inline(__always)
    func float4(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Float {
        float([a, b, c, d])
    }
}

/// Decodes the tensor layouts produced by Ultralytics CoreML exports.
///
/// Layouts we understand:
/// 1. Raw, transposed `[1, C, N]` (YOLOv8/v11 default export). `C` is
///    `4 + nc`, optionally `+1` objectness and `+32` mask coefficients.
/// 2. Row-major `[1, N, C]` with a handful of columns — the YOLO26 NMS-free
///    head, `[x1, y1, x2, y2, score, class]`.
enum YOLODecoder {
    struct Decoded {
        var detections: [Detection]
        var layout: String
    }

    private struct Candidate {
        var detection: Detection
        var coefficients: [Float]?
    }

    static func decode(
        main: MLMultiArray,
        protos: MLMultiArray?,
        config: PersonConfig
    ) -> Decoded {
        let reader = MultiArrayReader(main)
        let shape = reader.shape
        guard shape.count == 3 else {
            return Decoded(detections: [], layout: "unsupported rank \(shape.count)")
        }
        // Treat as [1, C, N] when the middle axis is the smaller one.
        if shape[1] <= shape[2] {
            return decodeTransposed(reader: reader, protos: protos, config: config)
        } else {
            return decodeRows(reader: reader, protos: protos, config: config)
        }
    }

    // MARK: - Raw transposed [1, C, N]

    private static func decodeTransposed(
        reader: MultiArrayReader,
        protos: MLMultiArray?,
        config: PersonConfig
    ) -> Decoded {
        let channels = reader.shape[1]
        let anchors = reader.shape[2]
        let spec = AttributeSpec(channels: channels)
        let threshold = config.confidenceThreshold
        let base = 4 + (spec.hasObjectness ? 1 : 0) + spec.numClasses

        var candidates: [Candidate] = []
        candidates.reserveCapacity(64)

        for i in 0..<anchors {
            // Person is class 0: channel 4 when there is no objectness column,
            // channel 5 when objectness occupies channel 4.
            var score = reader.float3(0, 4 + (spec.hasObjectness ? 1 : 0), i)
            if spec.hasObjectness {
                score *= reader.float3(0, 4, i)
            }
            guard score >= threshold, score > 0 else { continue }

            let cx = reader.float3(0, 0, i)
            let cy = reader.float3(0, 1, i)
            let w = reader.float3(0, 2, i)
            let h = reader.float3(0, 3, i)
            let box = BoundingBox(
                x: Double(cx - w / 2),
                y: Double(1 - cy - h / 2),
                width: Double(w),
                height: Double(h)
            )

            var coefficients: [Float]?
            if spec.maskCoefficients > 0 {
                var coeffs = [Float](repeating: 0, count: spec.maskCoefficients)
                for k in 0..<spec.maskCoefficients {
                    coeffs[k] = reader.float3(0, base + k, i)
                }
                coefficients = coeffs
            }

            candidates.append(Candidate(
                detection: Detection(label: "person", confidence: score, box: box),
                coefficients: coefficients
            ))
        }

        let kept = nms(candidates, iou: config.iouThreshold, maxDetections: config.maxDetections)
        var detections = kept.map(\.detection)
        if config.computeMasks, let protos {
            attachMasks(to: &detections, candidates: kept, protos: protos)
        }
        let layout = "transposed C=\(channels) N=\(anchors) nc=\(spec.numClasses) obj=\(spec.hasObjectness) masks=\(spec.maskCoefficients)"
        return Decoded(detections: detections, layout: layout)
    }

    // MARK: - Row-major [1, N, C]

    private static func decodeRows(
        reader: MultiArrayReader,
        protos: MLMultiArray?,
        config: PersonConfig
    ) -> Decoded {
        let rows = reader.shape[1]
        let columns = reader.shape[2]
        let threshold = config.confidenceThreshold

        if columns >= 6 && columns <= 8 {
            var candidates: [Candidate] = []
            for i in 0..<rows {
                let score = reader.float3(0, i, 4)
                guard score >= threshold else { continue }
                let cls = Int(reader.float3(0, i, 5).rounded())
                guard cls == config.targetClassIndex else { continue }
                let x1 = Double(reader.float3(0, i, 0))
                let y1 = Double(reader.float3(0, i, 1))
                let x2 = Double(reader.float3(0, i, 2))
                let y2 = Double(reader.float3(0, i, 3))
                let box = BoundingBox(x: x1, y: 1 - y2, width: x2 - x1, height: y2 - y1)
                candidates.append(Candidate(
                    detection: Detection(label: "person", confidence: score, box: box),
                    coefficients: nil
                ))
            }
            let kept = nms(candidates, iou: config.iouThreshold, maxDetections: config.maxDetections)
            return Decoded(detections: kept.map(\.detection), layout: "nms-free rows N=\(rows) C=\(columns)")
        }

        // Fall back to treating the layout as [1, N, 4 + nc(+1)(+32)].
        let spec = AttributeSpec(channels: columns)
        var candidates: [Candidate] = []
        for i in 0..<rows {
            var score = reader.float3(0, i, 4 + (spec.hasObjectness ? 1 : 0))
            if spec.hasObjectness { score *= reader.float3(0, i, 4) }
            guard score >= threshold else { continue }
            let cx = Double(reader.float3(0, i, 0))
            let cy = Double(reader.float3(0, i, 1))
            let w = Double(reader.float3(0, i, 2))
            let h = Double(reader.float3(0, i, 3))
            let box = BoundingBox(x: cx - w / 2, y: 1 - cy - h / 2, width: w, height: h)
            candidates.append(Candidate(
                detection: Detection(label: "person", confidence: score, box: box),
                coefficients: nil
            ))
        }
        let kept = nms(candidates, iou: config.iouThreshold, maxDetections: config.maxDetections)
        if config.computeMasks, let protos {
            var detections = kept.map(\.detection)
            attachMasks(to: &detections, candidates: kept, protos: protos)
            return Decoded(detections: detections, layout: "row-major C=\(columns) N=\(rows)")
        }
        return Decoded(detections: kept.map(\.detection), layout: "row-major C=\(columns) N=\(rows)")
    }

    /// Derive class/objectness/mask-channel counts from the channel dimension.
    struct AttributeSpec {
        var numClasses: Int
        var hasObjectness: Bool
        var maskCoefficients: Int

        init(channels: Int) {
            switch channels {
            case 84: self.init(numClasses: 80, hasObjectness: false, maskCoefficients: 0)
            case 85: self.init(numClasses: 80, hasObjectness: true, maskCoefficients: 0)
            case 116: self.init(numClasses: 80, hasObjectness: false, maskCoefficients: 32)
            case 117: self.init(numClasses: 80, hasObjectness: true, maskCoefficients: 32)
            default:
                // Person-only segmentation export: 4 + 1 + 32 == 37.
                if channels >= 37 {
                    self.init(numClasses: max(1, channels - 4 - 32), hasObjectness: false, maskCoefficients: 32)
                } else {
                    self.init(numClasses: max(1, channels - 4), hasObjectness: false, maskCoefficients: 0)
                }
            }
        }

        init(numClasses: Int, hasObjectness: Bool, maskCoefficients: Int) {
            self.numClasses = numClasses
            self.hasObjectness = hasObjectness
            self.maskCoefficients = maskCoefficients
        }
    }

    // MARK: - NMS

    /// NMS over already-built detections (used for recognized-object outputs).
    static func nmsDetections(_ detections: [Detection], iou threshold: Float, maxDetections: Int) -> [Detection] {
        nms(detections.map { Candidate(detection: $0, coefficients: nil) },
            iou: threshold,
            maxDetections: maxDetections).map(\.detection)
    }

    private static func nms(_ candidates: [Candidate], iou threshold: Float, maxDetections: Int) -> [Candidate] {
        guard !candidates.isEmpty else { return [] }
        let sorted = candidates.sorted { $0.detection.confidence > $1.detection.confidence }
        var kept: [Candidate] = []
        var suppressed = [Bool](repeating: false, count: sorted.count)

        for i in 0..<sorted.count {
            if suppressed[i] { continue }
            kept.append(sorted[i])
            if kept.count >= maxDetections { break }
            for j in (i + 1)..<sorted.count where !suppressed[j] {
                if sorted[i].detection.box.iou(sorted[j].detection.box) > Double(threshold) {
                    suppressed[j] = true
                }
            }
        }
        return kept
    }

    // MARK: - Mask assembly

    private static func attachMasks(
        to detections: inout [Detection],
        candidates: [Candidate],
        protos: MLMultiArray
    ) {
        let protoReader = MultiArrayReader(protos)
        guard protoReader.shape.count == 4 else { return }
        let channels = protoReader.shape[1]
        let maskH = protoReader.shape[2]
        let maskW = protoReader.shape[3]

        for index in detections.indices {
            guard index < candidates.count, let coeffs = candidates[index].coefficients else { continue }
            let count = min(channels, coeffs.count)
            var values = [Float](repeating: 0, count: maskH * maskW)
            for y in 0..<maskH {
                for x in 0..<maskW {
                    var sum: Float = 0
                    for k in 0..<count {
                        sum += coeffs[k] * protoReader.float4(0, k, y, x)
                    }
                    values[y * maskW + x] = 1 / (1 + exp(-sum))
                }
            }
            detections[index].mask = MaskData(width: maskW, height: maskH, values: values)
        }
    }
}

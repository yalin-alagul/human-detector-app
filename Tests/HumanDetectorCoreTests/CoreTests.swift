import XCTest
import AppKit
@testable import HumanDetectorCore

/// Guards against shipping a blank icon because an SF Symbol name was wrong.
final class SymbolTests: XCTestCase {
    private let symbols = [
        // verdicts
        "checkmark.seal.fill", "questionmark.circle.fill", "xmark.octagon.fill",
        "arrow.uturn.forward.circle", "exclamationmark.triangle.fill",
        // generic
        "photo", "photo.badge.exclamationmark", "info.circle.fill", "xmark.circle.fill",
        "checkmark.circle.fill", "circle.dashed",
        // app chrome
        "person.crop.rectangle.stack", "folder", "tray.and.arrow.down", "cpu",
        "clock.arrow.circlepath", "arrow.uturn.backward", "arrow.clockwise",
        "square.grid.2x2", "play.circle", "stop.circle", "speedometer",
        "arrow.up.left.and.arrow.down.right", "wand.and.stars", "slider.horizontal.3",
        "chart.bar", "gauge.with.dots.needle.bottom.50percent", "gearshape", "shippingbox",
    ]

    func testAllSymbolsResolve() {
        for name in symbols {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "SF Symbol '\(name)' does not exist on this OS"
            )
        }
    }
}

final class DecisionEngineTests: XCTestCase {
    func testTrashOnStrongPerson() {
        let signals = ImageSignals(personDetections: [
            Detection(label: "person", confidence: 0.9, box: BoundingBox(x: 0.1, y: 0.1, width: 0.4, height: 0.6)),
        ])
        let decision = DecisionEngine.decide(signals: signals, thresholds: ThresholdConfig(), goal: .removeHumans)
        XCTAssertEqual(decision.verdict, .trash)
        XCTAssertEqual(decision.stage, "yolo-person")
    }

    func testReviewBand() {
        let signals = ImageSignals(personDetections: [
            Detection(label: "person", confidence: 0.15, box: BoundingBox(x: 0.1, y: 0.1, width: 0.4, height: 0.6)),
        ])
        let decision = DecisionEngine.decide(signals: signals, thresholds: ThresholdConfig(), goal: .removeHumans)
        XCTAssertEqual(decision.verdict, .review)
    }

    func testCleanWhenEmpty() {
        let decision = DecisionEngine.decide(signals: .empty, thresholds: ThresholdConfig(), goal: .removeHumans)
        XCTAssertEqual(decision.verdict, .clean)
    }

    func testFaceTrash() {
        let signals = ImageSignals(faces: [
            Detection(label: "face", confidence: 0.8, box: BoundingBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
        ])
        let decision = DecisionEngine.decide(signals: signals, thresholds: ThresholdConfig(), goal: .removeHumans)
        XCTAssertEqual(decision.verdict, .trash)
        XCTAssertEqual(decision.stage, "face")
    }

    func testKeepHumansKeepsDetectedPeople() {
        let signals = ImageSignals(personDetections: [
            Detection(label: "person", confidence: 0.9, box: BoundingBox(x: 0.1, y: 0.1, width: 0.4, height: 0.6)),
        ])
        let decision = DecisionEngine.decide(signals: signals, thresholds: ThresholdConfig(), goal: .keepHumans)
        XCTAssertEqual(decision.verdict, .clean)
    }

    func testKeepHumansTrashesEmptyPhotos() {
        let decision = DecisionEngine.decide(signals: .empty, thresholds: ThresholdConfig(), goal: .keepHumans)
        XCTAssertEqual(decision.verdict, .trash)
        XCTAssertEqual(decision.stage, "no-human")
    }

    func testKeepHumansLeavesReviewAsReview() {
        let signals = ImageSignals(personDetections: [
            Detection(label: "person", confidence: 0.15, box: BoundingBox(x: 0.1, y: 0.1, width: 0.4, height: 0.6)),
        ])
        let decision = DecisionEngine.decide(signals: signals, thresholds: ThresholdConfig(), goal: .keepHumans)
        XCTAssertEqual(decision.verdict, .review)
    }

    func testDefaultGoalKeepsPeople() {
        let hardware = HardwareProfile(totalMemoryGB: 16, chipName: "Apple Test", modelIdentifier: "Mac99,1",
                                       performanceCores: 8, efficiencyCores: 4)
        XCTAssertEqual(ConfigStore.defaultConfig(hardware: hardware).resolvedGoal, .keepHumans)
    }

    func testTinySpecklesIgnored() {
        let signals = ImageSignals(personDetections: [
            Detection(label: "person", confidence: 0.99, box: BoundingBox(x: 0.5, y: 0.5, width: 0.001, height: 0.001)),
        ])
        let decision = DecisionEngine.decide(signals: signals, thresholds: ThresholdConfig(), goal: .removeHumans)
        XCTAssertEqual(decision.verdict, .clean)
    }
}

final class TilerTests: XCTestCase {
    func testMapToOriginalTopLeft() {
        // A box filling the whole tile at the top-left of a 4000x2000 image.
        let tile = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let box = BoundingBox(x: 0, y: 0, width: 1, height: 1)
        let mapped = Tiler.mapToOriginal(box: box, tileRect: tile, originalSize: CGSize(width: 4000, height: 2000))
        XCTAssertEqual(mapped.x, 0, accuracy: 1e-9)
        XCTAssertEqual(mapped.width, 0.25, accuracy: 1e-9)
        XCTAssertEqual(mapped.height, 0.5, accuracy: 1e-9)
        // Tile sits at the vertical middle; bottom-left origin means y == 0.5.
        XCTAssertEqual(mapped.y, 0.5, accuracy: 1e-9)
    }
}

final class MoverTests: XCTestCase {
    func testSuffixCollision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("in/a.jpg")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x01]).write(to: source)

        let output = root.appendingPathComponent("out")
        let first = try Mover.place(source: source, outputRoot: output, verdict: .trash,
                                    relativePath: "a.jpg", mode: .copy, collision: .suffix,
                                    hash: "abc", dryRun: false)
        XCTAssertTrue(first.performed)

        let second = try Mover.place(source: source, outputRoot: output, verdict: .trash,
                                     relativePath: "a.jpg", mode: .copy, collision: .suffix,
                                     hash: "abc", dryRun: false)
        XCTAssertNotEqual(first.destination, second.destination)

        try? FileManager.default.removeItem(at: root)
    }

    func testDeduplicator() async {
        let dedup = Deduplicator(enabled: true)
        let first = await dedup.claim(hash: "h", relativePath: "a.jpg")
        XCTAssertNil(first)
        let second = await dedup.claim(hash: "h", relativePath: "b.jpg")
        XCTAssertEqual(second, "a.jpg")
    }
}

final class UndoResumeTests: XCTestCase {
    func testUndoMakesFileReprocessable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A real destination file, because a missing destination is treated as
        // not-processed (see testMissingDestinationIsReprocessed).
        let destination = root.appendingPathComponent("trash/a.jpg")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x01]).write(to: destination)

        let writer = try ManifestWriter(outputRoot: root, writeCSV: false, writeJSONL: true)
        let placedAt = Date()
        writer.append(ManifestEntry(
            relativePath: "a.jpg", fileName: "a.jpg", hash: "H",
            width: 1, height: 1, verdict: .trash, stage: "yolo-person",
            topScore: 0.9, destinationPath: destination.path, timestamp: placedAt
        ))
        writer.close()

        XCTAssertTrue(ManifestReader.processedHashes(outputRoot: root).contains("H"))

        try UndoJournal.appendRestored([
            UndoRecord(sourcePath: "/tmp/in/a.jpg", destinationPath: destination.path,
                       hash: "H", verdict: .trash, timestamp: placedAt.addingTimeInterval(1))
        ], outputRoot: root)

        XCTAssertFalse(
            ManifestReader.processedHashes(outputRoot: root).contains("H"),
            "A restored file must be scanned again"
        )
    }

    func testDryRunEntriesDoNotBlockRealRuns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try ManifestWriter(outputRoot: root, writeCSV: false, writeJSONL: true)
        writer.append(ManifestEntry(
            relativePath: "a.jpg", fileName: "a.jpg", hash: "H",
            width: 1, height: 1, verdict: .clean, stage: "none",
            topScore: 0, destinationPath: nil
        ))
        writer.close()

        XCTAssertTrue(
            ManifestReader.processedHashes(outputRoot: root).isEmpty,
            "A dry-run / unattached record must not count as processed"
        )
    }

    func testMissingDestinationIsReprocessed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try ManifestWriter(outputRoot: root, writeCSV: false, writeJSONL: true)
        writer.append(ManifestEntry(
            relativePath: "a.jpg", fileName: "a.jpg", hash: "H",
            width: 1, height: 1, verdict: .trash, stage: "yolo-person",
            topScore: 0.9, destinationPath: "/tmp/definitely-not-here-\(UUID().uuidString).jpg"
        ))
        writer.close()

        XCTAssertTrue(ManifestReader.processedHashes(outputRoot: root).isEmpty)
    }

    func testUndoLatestSkipsEmptyJournals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("in/a.jpg")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x01]).write(to: source)

        let journal = try UndoJournal(outputRoot: root)
        let outcome = try Mover.place(
            source: source, outputRoot: root, verdict: .trash, relativePath: "a.jpg",
            mode: .move, collision: .suffix, hash: "H", dryRun: false
        )
        journal.record(UndoRecord(
            sourcePath: source.path, destinationPath: outcome.destination.path,
            hash: "H", verdict: .trash
        ))
        journal.close()

        // Simulate a later no-op run that still creates an empty journal.
        let empty = try UndoJournal(outputRoot: root)
        empty.close()

        let restored = try UndoJournal.undoLatest(outputRoot: root)
        XCTAssertEqual(restored, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testManifestResetClearsProcessed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("clean/a.jpg")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x01]).write(to: destination)

        let writer = try ManifestWriter(outputRoot: root, writeCSV: false, writeJSONL: true)
        writer.append(ManifestEntry(
            relativePath: "a.jpg", fileName: "a.jpg", hash: "H",
            width: 1, height: 1, verdict: .clean, stage: "none", topScore: 0,
            destinationPath: destination.path
        ))
        writer.close()
        XCTAssertFalse(ManifestReader.processedHashes(outputRoot: root).isEmpty)

        try ManifestReader.reset(outputRoot: root)
        XCTAssertTrue(ManifestReader.processedHashes(outputRoot: root).isEmpty)
    }
}

final class SidecarWriterTests: XCTestCase {
    func testConcurrentAppendsDoNotInterleave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try SidecarWriter(outputRoot: root)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask { await writer.append(["i": index, "name": "row-\(index)"]) }
            }
        }
        await writer.close()

        let url = root
            .appendingPathComponent(".humandetector", isDirectory: true)
            .appendingPathComponent("sidecar.jsonl")
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 200)
        for line in lines {
            XCTAssertNotNil(
                try? JSONSerialization.jsonObject(with: Data(line)),
                "each line must be complete, valid JSON"
            )
        }
    }
}

final class ConfigTests: XCTestCase {
    func testPresetAutoPicksMaxOnLargeMemory() {
        let hardware = HardwareProfile(totalMemoryGB: 32, chipName: "Apple Test", modelIdentifier: "Mac99,1",
                                       performanceCores: 8, efficiencyCores: 4)
        XCTAssertEqual(PresetResolver.autoPreset(for: hardware), .max)
        XCTAssertEqual(PresetResolver.tuning(for: .auto, hardware: hardware).personSize, .x)
    }

    func testJSONRoundTrip() throws {
        var config = ConfigStore.defaultConfig()
        config.io.inputPath = "/tmp/in"
        config.thresholds.yoloTrash = 0.33
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }
}

final class DecoderTests: XCTestCase {
    func testAttributeSpecCOCO() {
        XCTAssertEqual(YOLODecoder.AttributeSpec(channels: 84).numClasses, 80)
        XCTAssertFalse(YOLODecoder.AttributeSpec(channels: 84).hasObjectness)
        XCTAssertTrue(YOLODecoder.AttributeSpec(channels: 85).hasObjectness)
        XCTAssertEqual(YOLODecoder.AttributeSpec(channels: 116).maskCoefficients, 32)
    }

    func testNMSDetections() {
        let detections = [
            Detection(label: "person", confidence: 0.9, box: BoundingBox(x: 0.1, y: 0.1, width: 0.3, height: 0.3)),
            Detection(label: "person", confidence: 0.8, box: BoundingBox(x: 0.11, y: 0.11, width: 0.3, height: 0.3)),
            Detection(label: "person", confidence: 0.7, box: BoundingBox(x: 0.6, y: 0.6, width: 0.2, height: 0.2)),
        ]
        let kept = YOLODecoder.nmsDetections(detections, iou: 0.5, maxDetections: 10)
        XCTAssertEqual(kept.count, 2)
    }
}

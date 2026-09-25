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
        // model library
        "arrow.down.circle", "square.and.arrow.down", "icloud.and.arrow.down", "internaldrive",
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

    func testCoreSplitThreeTiers() {
        // Apple M6: Super, Performance and Efficiency tiers.
        let split = HardwareProfile.coreSplit(levels: [
            (name: "Super", cores: 2), (name: "Performance", cores: 4), (name: "Efficiency", cores: 6),
        ])
        XCTAssertEqual(split.superCores, 2)
        XCTAssertEqual(split.performance, 4)
        XCTAssertEqual(split.efficiency, 6)

        let hardware = HardwareProfile(totalMemoryGB: 24, chipName: "Apple M6", modelIdentifier: "Mac18,5",
                                       performanceCores: 4, efficiencyCores: 6, superCores: 2)
        XCTAssertEqual(hardware.physicalCores, 12)
        XCTAssertEqual(hardware.summary, "Apple M6 · 24 GB · 2S+4P+6E cores")
        XCTAssertEqual(PresetResolver.autoPreset(for: hardware), .max)
    }

    func testCoreSplitTwoTiers() {
        let split = HardwareProfile.coreSplit(levels: [
            (name: "Performance", cores: 4), (name: "Efficiency", cores: 4),
        ])
        XCTAssertEqual(split.superCores, 0)
        XCTAssertEqual(split.performance, 4)
        XCTAssertEqual(split.efficiency, 4)
    }

    func testCoreSplitUnnamedTiers() {
        let split = HardwareProfile.coreSplit(levels: [(name: "", cores: 8), (name: "", cores: 2)])
        XCTAssertEqual(split.superCores, 0)
        XCTAssertEqual(split.performance, 8)
        XCTAssertEqual(split.efficiency, 2)
    }

    func testJSONRoundTrip() throws {
        var config = ConfigStore.defaultConfig()
        config.io.inputPath = "/tmp/in"
        config.thresholds.yoloTrash = 0.33
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testConfigWithoutModelSourceStillDecodes() throws {
        var config = ConfigStore.defaultConfig()
        config.modelSource = ModelSource(huggingFaceUsername: "someone")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertNotNil(json["modelSource"])
        json.removeValue(forKey: "modelSource")

        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.modelSource)
        XCTAssertEqual(decoded.resolvedModelSource, ModelSource())
        XCTAssertNil(decoded.resolvedModelSource.repoID, "No username, so nothing to download from")
    }

    func testModelSourceRepoID() {
        XCTAssertEqual(ModelSource(huggingFaceUsername: " someone ").repoID, "someone/human-detector-models")
        XCTAssertEqual(ModelSource(huggingFaceUsername: "someone", huggingFaceRepo: "").repoID, "someone/human-detector-models")
        XCTAssertEqual(ModelSource(huggingFaceUsername: "org", huggingFaceRepo: "models").repoID, "org/models")
    }
}

final class ModelLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> ModelStore {
        ModelStore(
            directory: root.appendingPathComponent("Models"),
            compiledDirectory: root.appendingPathComponent("CompiledModels")
        )
    }

    /// A minimal `.mlpackage` layout: enough for the store, not for CoreML.
    @discardableResult
    private func makePackage(named stem: String, in folder: URL, weights: Data = Data(repeating: 7, count: 64)) throws -> URL {
        let package = folder.appendingPathComponent("\(stem).mlpackage")
        let weightsDir = package.appendingPathComponent("Data/com.apple.CoreML/weights")
        try FileManager.default.createDirectory(at: weightsDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: package.appendingPathComponent("Manifest.json"))
        try weights.write(to: weightsDir.appendingPathComponent("weight.bin"))
        return package
    }

    func testInstallListAndRemove() throws {
        let store = makeStore()
        XCTAssertTrue(store.installed().isEmpty)

        let staging = try store.makeStagingDirectory()
        let staged = try makePackage(named: "yolo26n-seg", in: staging)
        try store.install(staged: staged, stem: "yolo26n-seg")

        let installed = store.installed()
        XCTAssertEqual(installed.map(\.stem), ["yolo26n-seg"], "Staging folders must not be listed")
        XCTAssertEqual(installed.first?.bytes, 2 + 64)

        // A compiled cache left behind by CoreMLLoader goes with the package.
        let compiled = store.compiledDirectory.appendingPathComponent("yolo26n-seg.mlmodelc")
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)

        try store.remove(stem: "yolo26n-seg")
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.packageURL(for: "yolo26n-seg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: compiled.path))
    }

    func testInstallReplacesOlderCopy() throws {
        let store = makeStore()
        try store.install(staged: makePackage(named: "m", in: store.makeStagingDirectory()), stem: "m")
        try store.install(
            staged: makePackage(named: "m", in: store.makeStagingDirectory(), weights: Data(repeating: 1, count: 10)),
            stem: "m"
        )
        XCTAssertEqual(store.installed().first?.bytes, 2 + 10)
    }

    func testInstallRejectsNonPackage() throws {
        let store = makeStore()
        let staged = try store.makeStagingDirectory().appendingPathComponent("junk.mlpackage")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.install(staged: staged, stem: "junk"))
        XCTAssertTrue(store.installed().isEmpty)
    }

    func testImportFromFolderAndPackage() throws {
        let store = makeStore()
        let exports = root.appendingPathComponent("exports")
        try makePackage(named: "yolo26s-seg", in: exports)
        try makePackage(named: "yolo26m-seg", in: exports)
        try Data("not a model".utf8).write(to: exports.appendingPathComponent("yolo26m-seg.pt"))
        let single = try makePackage(named: "scrfd_10g_bnkps", in: root.appendingPathComponent("elsewhere"))

        let stems = try store.importPackages(from: [exports, single])
        XCTAssertEqual(Set(stems), ["yolo26s-seg", "yolo26m-seg", "scrfd_10g_bnkps"])
        XCTAssertEqual(store.installed().map(\.stem), ["scrfd_10g_bnkps", "yolo26m-seg", "yolo26s-seg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: exports.appendingPathComponent("yolo26s-seg.mlpackage").path),
                      "Import copies; the originals stay")
        XCTAssertThrowsError(try store.importPackages(from: [root.appendingPathComponent("elsewhere/empty")]))
    }

    func testTreeListingGroupsPackages() throws {
        let json = """
        [
          {"type": "file", "path": ".gitattributes", "size": 1519, "oid": "a"},
          {"type": "file", "path": "README.md", "size": 20, "oid": "b"},
          {"type": "directory", "path": "yolo26x-seg.mlpackage", "size": 0, "oid": "c"},
          {"type": "file", "path": "yolo26x-seg.mlpackage/Manifest.json", "size": 617, "oid": "d"},
          {"type": "file", "path": "yolo26x-seg.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "size": 134,
           "oid": "e", "lfs": {"oid": "ABC123", "size": 120000000, "pointerSize": 134}},
          {"type": "file", "path": "yolo26n-seg.mlpackage/Manifest.json", "size": 617, "oid": "f"},
          {"type": "file", "path": "notes/yolo26m-seg.mlpackage/Manifest.json", "size": 1, "oid": "g"}
        ]
        """
        let models = try HuggingFaceClient.models(fromTree: Data(json.utf8))
        XCTAssertEqual(models.map(\.stem), ["yolo26n-seg", "yolo26x-seg"], "Smallest first; nested folders ignored")

        let x = try XCTUnwrap(models.last)
        XCTAssertEqual(x.files.count, 2)
        XCTAssertEqual(x.bytes, 617 + 120_000_000, "LFS files count their real size, not the pointer's")
        XCTAssertEqual(x.files.first { $0.path.hasSuffix("weight.bin") }?.sha256, "ABC123")
        XCTAssertNil(x.files.first { $0.path.hasSuffix("Manifest.json") }?.sha256)
    }

    func testNextPageFromLinkHeader() {
        let header = #"<https://huggingface.co/api/models/a/b/tree/main?cursor=xyz>; rel="next""#
        XCTAssertEqual(HuggingFaceClient.nextPage(linkHeader: header)?.absoluteString,
                       "https://huggingface.co/api/models/a/b/tree/main?cursor=xyz")
        XCTAssertNil(HuggingFaceClient.nextPage(linkHeader: nil))
        XCTAssertNil(HuggingFaceClient.nextPage(linkHeader: #"<https://x>; rel="prev""#))
    }

    func testVerifyRejectsBadDownloads() throws {
        let file = root.appendingPathComponent("weight.bin")
        let data = Data(repeating: 3, count: 100)
        try data.write(to: file)
        let hash = Hasher.sha256(of: data)

        XCTAssertNoThrow(try HuggingFaceClient.verify(.init(path: "w", size: 100, sha256: hash), at: file))
        XCTAssertNoThrow(try HuggingFaceClient.verify(.init(path: "w", size: 100, sha256: hash.uppercased()), at: file))
        XCTAssertNoThrow(try HuggingFaceClient.verify(.init(path: "w", size: 100, sha256: nil), at: file))
        XCTAssertThrowsError(try HuggingFaceClient.verify(.init(path: "w", size: 99, sha256: hash), at: file)) {
            guard case HuggingFaceError.sizeMismatch = $0 else { return XCTFail("expected sizeMismatch, got \($0)") }
        }
        XCTAssertThrowsError(try HuggingFaceClient.verify(.init(path: "w", size: 100, sha256: String(repeating: "0", count: 64)), at: file)) {
            guard case HuggingFaceError.checksumMismatch = $0 else { return XCTFail("expected checksumMismatch, got \($0)") }
        }
    }

    func testSearchRootsPreferTheModelStore() {
        guard ProcessInfo.processInfo.environment["HUMAN_DETECTOR_MODELS"] == nil else { return }
        let roots = ModelRegistry.searchRoots()
        XCTAssertEqual(roots.first, ModelStore.defaultDirectory)
        XCTAssertFalse(roots.contains { $0.path.hasPrefix(Bundle.main.bundleURL.path + "/Contents") },
                       "Models are never read from inside the app bundle")
    }

    func testCatalogNamesAndNeededModels() {
        XCTAssertEqual(ModelCatalog.displayName(for: "yolo26x-seg"), "YOLO26 X-Large · segmentation")
        XCTAssertEqual(ModelCatalog.displayName(for: "scrfd_10g_bnkps"), "SCRFD face detector")
        XCTAssertEqual(ModelCatalog.displayName(for: "custom"), "custom")

        var config = AppConfig()
        config.person.size = .m
        config.face.provider = .vision
        XCTAssertEqual(ModelCatalog.stemsNeeded(by: config), ["yolo26m-seg"])
        config.face.provider = .both
        XCTAssertEqual(ModelCatalog.stemsNeeded(by: config), ["yolo26m-seg", "scrfd_10g_bnkps"])
        config.person.customModelPath = "/somewhere/model.mlpackage"
        XCTAssertEqual(ModelCatalog.stemsNeeded(by: config), ["scrfd_10g_bnkps"])
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

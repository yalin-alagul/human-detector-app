import Foundation
import CoreGraphics

public struct RunProgress: Sendable {
    public var processed: Int
    public var total: Int
    public var currentPath: String
    public var counts: [Verdict: Int]
    public var imagesPerSecond: Double
    public var etaSeconds: Double?
}

public struct RunSummary: Sendable {
    public var total: Int
    public var counts: [Verdict: Int]
    public var duplicates: Int
    public var failures: Int
    public var duration: Double
    public var inputPath: String
    public var outputPath: String
    public var manifestCSV: String?
    public var undoJournal: String?
    public var personModel: String
    public var faceModel: String
    public var notes: [String]
    public var cancelled: Bool
}

public enum PipelineError: Error, LocalizedError {
    case missingPath
    case inputNotFound(String)
    case inputNotReadable(String)
    case outputNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .missingPath:
            return "Choose an input folder and an output folder first."
        case .inputNotFound(let path):
            return "Input folder does not exist: \(path)"
        case .inputNotReadable(let path):
            return "Can’t read \(path). If this is the sandboxed app, press Choose… and re-select the folder — macOS forgets folder access after the app is updated or re-signed."
        case .outputNotFound(let path):
            return "Output folder could not be created: \(path)"
        }
    }
}

/// Bounded-concurrency scan over a folder tree.
///
/// Image decode and Stage 2/3 Vision work run across `concurrency` tasks, while
/// YOLO inference is serialized inside `PersonDetector` (the ANE is a single
/// unit). Manifest and undo writes happen on the actor, in completion order.
public actor ScanPipeline {
    private let config: AppConfig
    private let token = CancellationToken()

    /// `hardware` is accepted so callers can construct the pipeline uniformly;
    /// tuning already happened when the preset was applied to `config`.
    public init(config: AppConfig, hardware: HardwareProfile) {
        self.config = config
    }

    public func cancel() {
        token.cancel()
    }

    /// Signals cached per content hash so duplicate files reuse one inference.
    private actor SignalsCache {
        private var storage: [String: ImageSignals] = [:]
        private var order: [String] = []
        private let capacity = 20_000

        func get(_ hash: String) -> ImageSignals? { storage[hash] }

        func put(_ hash: String, _ signals: ImageSignals) {
            if storage[hash] == nil {
                order.append(hash)
                if order.count > capacity, let oldest = order.first {
                    order.removeFirst()
                    storage.removeValue(forKey: oldest)
                }
            }
            storage[hash] = signals
        }
    }

    // MARK: - Run

    public func run(
        progress: @escaping @Sendable (RunProgress) -> Void,
        onEntry: (@Sendable (ManifestEntry) -> Void)? = nil
    ) async throws -> RunSummary {
        let started = Date()
        guard !config.io.inputPath.isEmpty, !config.io.outputPath.isEmpty else {
            throw PipelineError.missingPath
        }
        let inputRoot = URL(fileURLWithPath: config.io.inputPath, isDirectory: true)
        let outputRoot = URL(fileURLWithPath: config.io.outputPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: inputRoot.path) else {
            throw PipelineError.inputNotFound(inputRoot.path)
        }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let suite = try DetectorSuite(config: config)
        let log = RunLog()
        for note in suite.notes { log.add(note) }

        let files = try ImageEnumerator.enumerate(
            root: inputRoot,
            extensions: Set(config.io.supportedExtensions)
        )
        guard !files.isEmpty else {
            // Explain the no-op instead of finishing silently.
            let anyFiles = ImageEnumerator.anyFileCount(root: inputRoot)
            let isPackage = (try? inputRoot.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            let looksLikePhotosLibrary = inputRoot.pathExtension.lowercased() == "photoslibrary" || isPackage
            if looksLikePhotosLibrary {
                log.add("\(inputRoot.path) looks like a package (e.g. a Photos Library), which we deliberately do not scan inside. Export the originals first (Photos → File → Export) or point the input at the folder of exported images.")
            } else if anyFiles == 0 {
                log.add("Nothing to scan: \(inputRoot.path) contains no files. If a previous run moved them, point the input at the folder that still holds them.")
            } else {
                let extList = config.io.supportedExtensions.joined(separator: ", ")
                log.add("Found \(anyFiles) file(s) in \(inputRoot.path) but none matched the image extensions (\(extList)). Add the extension in Settings or move images into the input folder.")
            }
            return RunSummary(
                total: 0, counts: [:], duplicates: 0, failures: 0, duration: 0,
                inputPath: inputRoot.path, outputPath: outputRoot.path,
                manifestCSV: nil, undoJournal: nil,
                personModel: suite.personDescription, faceModel: suite.faceDescription,
                notes: log.all, cancelled: false
            )
        }

        let processedHashes = config.behavior.resume
            ? ManifestReader.processedHashes(outputRoot: outputRoot)
            : []

        // A dry run must not pollute the durable manifest, or a later real run
        // would think those never-moved files were already handled.
        let manifest = try ManifestWriter(
            outputRoot: outputRoot,
            writeCSV: config.behavior.writeCSV,
            writeJSONL: config.behavior.writeJSONL && !config.behavior.dryRun
        )
        var undoJournal: UndoJournal?
        if config.behavior.quarantine, !config.behavior.dryRun {
            undoJournal = try UndoJournal(outputRoot: outputRoot)
        }

        let dedup = Deduplicator(enabled: config.behavior.deduplicateByHash)
        let cache = SignalsCache()
        let sidecar = config.behavior.writeSidecarJSON && !config.behavior.dryRun
            ? try? SidecarWriter(outputRoot: outputRoot)
            : nil
        let context = ProcessContext(
            config: config,
            suite: suite,
            dedup: dedup,
            cache: cache,
            sidecar: sidecar,
            processedHashes: processedHashes,
            outputRoot: outputRoot,
            token: token
        )

        var counts: [Verdict: Int] = [:]
        var duplicateCount = 0
        var iterator = files.makeIterator()
        let maxConcurrent = max(1, config.performance.concurrency)

        await withTaskGroup(of: ManifestEntry.self) { group in
            func addNext() {
                guard !token.isCancelled, let item = iterator.next() else { return }
                group.addTask { await ScanPipeline.process(item.url, relativePath: item.relativePath, context: context) }
            }
            for _ in 0..<maxConcurrent { addNext() }

            for await entry in group {
                counts[entry.verdict, default: 0] += 1
                if entry.duplicateOf != nil { duplicateCount += 1 }
                manifest.append(entry)
                onEntry?(entry)
                if let undoJournal, entry.verdict.folderName != nil, let destination = entry.destinationPath {
                    undoJournal.record(UndoRecord(
                        sourcePath: entry.sourcePath,
                        destinationPath: destination,
                        hash: entry.hash,
                        verdict: entry.verdict
                    ))
                }
                let processed = counts.values.reduce(0, +)
                let elapsed = Date().timeIntervalSince(started)
                let rate = elapsed > 0 ? Double(processed) / elapsed : 0
                let remaining = files.count - processed
                progress(RunProgress(
                    processed: processed,
                    total: files.count,
                    currentPath: entry.relativePath,
                    counts: counts,
                    imagesPerSecond: rate,
                    etaSeconds: rate > 0 ? Double(remaining) / rate : nil
                ))
                addNext()
            }
        }

        manifest.close()
        undoJournal?.close()
        await sidecar?.close()

        if counts[Verdict.skipped, default: 0] == files.count {
            log.add("All \(files.count) files were already processed (Resume is on). Use Undo Last Run, reset the manifest, or turn off Resume to scan them again.")
        }

        return RunSummary(
            total: files.count,
            counts: counts,
            duplicates: duplicateCount,
            failures: counts[Verdict.failed, default: 0],
            duration: Date().timeIntervalSince(started),
            inputPath: inputRoot.path,
            outputPath: outputRoot.path,
            manifestCSV: manifest.csvURL?.path,
            undoJournal: undoJournal?.url.path,
            personModel: suite.personDescription,
            faceModel: suite.faceDescription,
            notes: log.all,
            cancelled: token.isCancelled
        )
    }

    // MARK: - Per-image processing

    private struct ProcessContext: @unchecked Sendable {
        let config: AppConfig
        let suite: DetectorSuite
        let dedup: Deduplicator
        let cache: SignalsCache
        let sidecar: SidecarWriter?
        let processedHashes: Set<String>
        let outputRoot: URL
        let token: CancellationToken
    }

    private nonisolated static func process(
        _ url: URL,
        relativePath: String,
        context: ProcessContext
    ) async -> ManifestEntry {
        let start = Date()
        let fileName = url.lastPathComponent

        func entry(
            _ verdict: Verdict,
            _ hash: String,
            _ stage: String,
            _ top: Float,
            person: Float = 0,
            face: Float = 0,
            destination: String? = nil,
            duplicateOf: String? = nil,
            error: String? = nil,
            size: (Int, Int) = (0, 0)
        ) -> ManifestEntry {
            ManifestEntry(
                relativePath: relativePath,
                fileName: fileName,
                hash: hash,
                width: size.0,
                height: size.1,
                verdict: verdict,
                stage: stage,
                topScore: top,
                personScore: person,
                faceScore: face,
                sourcePath: url.path,
                destinationPath: destination,
                duplicateOf: duplicateOf,
                error: error,
                durationMS: Date().timeIntervalSince(start) * 1000
            )
        }

        do {
            let hash = try Hasher.sha256(ofFileAt: url)
            let info = ImageLoader.info(at: url)

            if context.processedHashes.contains(hash) {
                await context.dedup.seed(hash: hash, relativePath: relativePath)
                return entry(.skipped, hash, "resume", 0, size: (info?.pixelWidth ?? 0, info?.pixelHeight ?? 0))
            }

            let duplicateOf = await context.dedup.claim(hash: hash, relativePath: relativePath)

            let signals: ImageSignals
            if let cached = await context.cache.get(hash) {
                signals = cached
            } else {
                signals = try await analyze(url: url, context: context)
                await context.cache.put(hash, signals)
            }

            let decision = DecisionEngine.decide(
                signals: signals,
                thresholds: context.config.thresholds,
                goal: context.config.resolvedGoal
            )

            var destinationPath: String?
            if context.config.behavior.quarantine, !context.config.behavior.dryRun {
                let relative = context.config.io.preserveRelativePaths ? relativePath : fileName
                let outcome = try Mover.place(
                    source: url,
                    outputRoot: context.outputRoot,
                    verdict: decision.verdict,
                    relativePath: relative,
                    mode: context.config.io.moveMode,
                    collision: context.config.io.collisionPolicy,
                    hash: hash,
                    dryRun: context.config.behavior.dryRun
                )
                destinationPath = outcome.destination.path

                if let sidecar = context.sidecar {
                    await sidecar.append(sidecarRecord(
                        decision: decision,
                        relativePath: relativePath,
                        hash: hash,
                        signals: signals
                    ))
                }
            }

            return entry(
                decision.verdict,
                hash,
                decision.stage,
                decision.topScore,
                person: signals.personTop,
                face: signals.faceTop,
                destination: destinationPath,
                duplicateOf: duplicateOf,
                size: (info?.pixelWidth ?? 0, info?.pixelHeight ?? 0)
            )
        } catch {
            return entry(.failed, "", "error", 0, error: error.localizedDescription)
        }
    }

    /// Load (or tile) the image and run the detector suite.
    private nonisolated static func analyze(url: URL, context: ProcessContext) async throws -> ImageSignals {
        let info = ImageLoader.info(at: url)
        let config = context.config
        let decodeCap = max(config.person.imageSize, context.suite.personInputSize ?? 0)
        let needsTiling = config.panorama.enabled
            && (info?.longEdge ?? 0) > config.panorama.longEdgeThreshold
            && context.suite.person != nil

        if needsTiling {
            let loaded = try ImageLoader.loadFullSize(at: url)
            let tiles = Tiler.tiles(
                for: loaded,
                tileSize: config.panorama.tileSize,
                overlap: config.panorama.overlap
            )
            let size = CGSize(width: loaded.pixelWidth, height: loaded.pixelHeight)
            var merged = ImageSignals(tiled: true)
            for tile in tiles {
                if context.token.isCancelled { break }
                let tileSignals = try context.suite.analyze(image: tile.image, thresholds: config.thresholds)
                merged.personDetections.append(contentsOf: remap(tileSignals.personDetections, tile.rect, size))
                merged.faces.append(contentsOf: remap(tileSignals.faces, tile.rect, size))
                merged.humanRects.append(contentsOf: remap(tileSignals.humanRects, tile.rect, size))
                merged.bodyPoses.append(contentsOf: remap(tileSignals.bodyPoses, tile.rect, size))
            }
            return merged
        }

        let loaded = try ImageLoader.load(at: url, maxPixelSize: decodeCap)
        return try context.suite.analyze(image: loaded.cgImage, thresholds: config.thresholds)
    }

    private nonisolated static func remap(_ detections: [Detection], _ tile: CGRect, _ size: CGSize) -> [Detection] {
        detections.map { detection in
            var copy = detection
            copy.box = Tiler.mapToOriginal(box: detection.box, tileRect: tile, originalSize: size)
            return copy
        }
    }

    private nonisolated static func sidecarRecord(
        decision: Decision,
        relativePath: String,
        hash: String,
        signals: ImageSignals
    ) -> [String: Any] {
        [
            "relative_path": relativePath,
            "hash": hash,
            "verdict": decision.verdict.rawValue,
            "stage": decision.stage,
            "top_score": decision.topScore,
            "person_top": signals.personTop,
            "face_top": signals.faceTop,
            "human_rect_top": signals.humanRectTop,
            "body_pose_top": signals.bodyPoseTop,
            "person_count": signals.personDetections.count,
            "face_count": signals.faces.count,
            "tiled": signals.tiled,
        ]
    }
}

/// Serializes sidecar writes so concurrent workers cannot interleave lines.
actor SidecarWriter {
    private let url: URL
    private var handle: FileHandle?

    init(outputRoot: URL) throws {
        let dir = outputRoot.appendingPathComponent(SupportPaths.workDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("sidecar.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let fileHandle = try FileHandle(forWritingTo: url)
        fileHandle.seekToEndOfFile()
        handle = fileHandle
    }

    func append(_ record: [String: Any]) {
        guard let handle,
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return }
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data([0x0A]))
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

import Foundation
import HumanDetectorCore

// Headless companion to the app for running batches on a Mac mini.
// Shares all of HumanDetectorCore, so verdicts and thresholds match the GUI.

struct Arguments {
    var command: String = "help"
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        var rest = raw
        if let first = rest.first, !first.hasPrefix("-") {
            command = first
            rest.removeFirst()
        }
        var index = 0
        while index < rest.count {
            let token = rest[index]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if index + 1 < rest.count, !rest[index + 1].hasPrefix("--") {
                    options[key] = rest[index + 1]
                    index += 2
                } else {
                    flags.insert(key)
                    index += 1
                }
            } else {
                index += 1
            }
        }
    }

    func string(_ key: String) -> String? { options[key] }
    func int(_ key: String) -> Int? { options[key].flatMap(Int.init) }
    func float(_ key: String) -> Float? { options[key].flatMap(Float.init) }
    func has(_ key: String) -> Bool { flags.contains(key) }
}

func printUsage() {
    print("""
    humandetector — recall-first human detector

    USAGE:
      humandetector scan --input <dir> --output <dir> [options]
      humandetector undo --output <dir>
      humandetector config --write <file>
      humandetector probe --image <file> [--face vision|scrfd|both]
      humandetector reset --output <dir>     forget past decisions (re-run everything)
      humandetector hardware

    SCAN OPTIONS:
      --config <file>        Load a JSON config (overrides defaults)
      --preset <name>        auto | lite | balanced | max
      --family <name>        yolo26 | yolo11
      --size <n>             n | s | m | l | x
      --task <name>          seg | detect
      --imgsz <n>            model input resolution (default 1280)
      --conf <f>             person trash threshold (default 0.25)
      --review <f>           person review floor (default 0.10)
      --concurrency <n>      parallel decode/inference tasks
      --goal <name>          keep | remove   (keep = trash photos with no people, default)
      --face <provider>      vision | scrfd | both | off
      --model <path>         custom person .mlpackage
      --scrfd <path>         custom SCRFD .mlpackage
      --dry-run              log verdicts without moving files
      --copy                 copy instead of move
      --no-resume            reprocess files already in the manifest
      --csv / --no-csv       write the per-run CSV (default on)
    """)
}

func buildConfig(_ args: Arguments) throws -> AppConfig {
    var config: AppConfig
    if let path = args.string("config"), let loaded = try? ConfigStore.load(from: URL(fileURLWithPath: path)) {
        config = loaded
    } else {
        config = ConfigStore.defaultConfig()
    }

    if let input = args.string("input") { config.io.inputPath = input }
    if let output = args.string("output") { config.io.outputPath = output }

    if let presetRaw = args.string("preset"), let preset = HardwarePreset(rawValue: presetRaw) {
        PresetResolver.apply(preset, hardware: .current(), to: &config)
    }
    if let familyRaw = args.string("family"), let family = ModelFamily(rawValue: familyRaw) {
        config.person.family = family
    }
    if let sizeRaw = args.string("size"), let size = ModelSize(rawValue: sizeRaw) {
        config.person.size = size
    }
    if let taskRaw = args.string("task"), let task = ModelTask(rawValue: taskRaw) {
        config.person.task = task
    }
    if let imgsz = args.int("imgsz") { config.person.imageSize = imgsz }
    if let conf = args.float("conf") { config.thresholds.yoloTrash = conf }
    if let review = args.float("review") { config.thresholds.yoloReviewLow = review }
    if let concurrency = args.int("concurrency") { config.performance.concurrency = concurrency }
    if let goal = args.string("goal") {
        config.goal = (goal == "remove" || goal == "remove-humans") ? .removeHumans : .keepHumans
    }
    if let model = args.string("model") { config.person.customModelPath = model }
    if let scrfd = args.string("scrfd") { config.face.scrfdModelPath = scrfd }
    if let face = args.string("face") {
        switch face {
        case "off": config.face.enabled = false
        case "scrfd": config.face.provider = .scrfd
        case "both": config.face.provider = .both
        default: config.face.provider = .vision
        }
    }
    if args.has("no-person") { config.person.enabled = false }
    if args.has("dry-run") { config.behavior.dryRun = true }
    if args.has("copy") { config.io.moveMode = .copy }
    if args.has("no-resume") { config.behavior.resume = false }
    if args.has("no-csv") { config.behavior.writeCSV = false }
    return config
}

func runScan(_ args: Arguments) async {
    do {
        let config = try buildConfig(args)
        guard !config.io.inputPath.isEmpty, !config.io.outputPath.isEmpty else {
            printUsage()
            exit(1)
        }
        let hardware = HardwareProfile.current()
        print("Hardware: \(hardware.summary)")
        print("Input:  \(config.io.inputPath)")
        print("Output: \(config.io.outputPath)")
        print("Mode:   \(config.io.moveMode.rawValue)\(config.behavior.dryRun ? " (dry run)" : "")")
        print("Goal:   \(config.resolvedGoal.shortName) — \(config.resolvedGoal.folderExplanation)")

        let pipeline = ScanPipeline(config: config, hardware: hardware)
        let summary = try await pipeline.run { progress in
            let line = String(
                format: "\r%6d/%-6d  %5.1f img/s  clean:%d review:%d trash:%d  ETA %@",
                progress.processed, progress.total, progress.imagesPerSecond,
                progress.counts[.clean, default: 0],
                progress.counts[.review, default: 0],
                progress.counts[.trash, default: 0],
                progress.etaSeconds.map { String(format: "%.0fs", $0) } ?? "—"
            )
            FileHandle.standardError.write(Data(line.utf8))
        }
        print("\n")
        print("Done in \(String(format: "%.1f", summary.duration))s — \(summary.total) files")
        print("  clean:  \(summary.counts[.clean, default: 0])")
        print("  review: \(summary.counts[.review, default: 0])")
        print("  trash:  \(summary.counts[.trash, default: 0])")
        print("  skipped:\(summary.counts[.skipped, default: 0])")
        print("  failed: \(summary.failures)")
        print("  duplicates: \(summary.duplicates)")
        print("  person model: \(summary.personModel)")
        print("  face model:   \(summary.faceModel)")
        for note in summary.notes { print("  note: \(note)") }
        if let csv = summary.manifestCSV { print("  manifest: \(csv)") }
        if let undo = summary.undoJournal { print("  undo:     \(undo)") }
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// MARK: - Entry point

let args = Arguments(Array(CommandLine.arguments.dropFirst()))
switch args.command {
case "scan":
    await runScan(args)

case "undo":
    let output = args.string("output") ?? ""
    guard !output.isEmpty else {
        FileHandle.standardError.write(Data("error: --output is required\n".utf8))
        exit(1)
    }
    do {
        let restored = try UndoJournal.undoLatest(outputRoot: URL(fileURLWithPath: output))
        print("Restored \(restored) files.")
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "config":
    guard let path = args.string("write") else {
        FileHandle.standardError.write(Data("error: --write is required\n".utf8))
        exit(1)
    }
    do {
        try ConfigStore.save(ConfigStore.defaultConfig(), to: URL(fileURLWithPath: path))
        print("Wrote default config to \(path)")
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "probe":
    guard let image = args.string("image") else {
        FileHandle.standardError.write(Data("error: --image is required\n".utf8))
        exit(1)
    }
    do {
        let config = try buildConfig(args)
        let suite = try DetectorSuite(config: config)
        let url = URL(fileURLWithPath: image)
        let cap = max(config.person.imageSize, suite.personInputSize ?? 0)
        let loaded = try ImageLoader.load(at: url, maxPixelSize: cap)
        let signals = try suite.analyze(image: loaded.cgImage, thresholds: config.thresholds)
        let decision = DecisionEngine.decide(
            signals: signals,
            thresholds: config.thresholds,
            goal: config.resolvedGoal
        )
        print("image:    \(image) (\(loaded.pixelWidth)x\(loaded.pixelHeight))")
        print("goal:     \(config.resolvedGoal.shortName) — \(config.resolvedGoal.folderExplanation)")
        print("person:   top=\(String(format: "%.4f", signals.personTop)) count=\(signals.personDetections.count)")
        print("face:     top=\(String(format: "%.4f", signals.faceTop)) count=\(signals.faces.count)")
        print("humanRect:top=\(String(format: "%.4f", signals.humanRectTop)) count=\(signals.humanRects.count)")
        print("bodyPose: top=\(String(format: "%.4f", signals.bodyPoseTop)) count=\(signals.bodyPoses.count)")
        print("verdict:  \(decision.verdict.rawValue) (stage: \(decision.stage)) — \(decision.reason)")
        for face in signals.faces.prefix(10) {
            print(String(format: "  face %.3f  box=(%.3f, %.3f, %.3f, %.3f)",
                         face.confidence, face.box.x, face.box.y, face.box.width, face.box.height))
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "reset":
    let output = args.string("output") ?? ""
    guard !output.isEmpty else {
        FileHandle.standardError.write(Data("error: --output is required\n".utf8))
        exit(1)
    }
    do {
        try ManifestReader.reset(outputRoot: URL(fileURLWithPath: output))
        print("Manifest reset. The next scan will reprocess every image in the input folder.")
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "hardware":
    print(HardwareProfile.current().summary)

default:
    printUsage()
}

import Foundation
import Combine
import AppKit
import HumanDetectorCore

/// Observable state for the whole app: config, folder access, run progress,
/// and the data the review grid shows.
@MainActor
final class AppState: ObservableObject {
    @Published var config: AppConfig
    @Published var hardware: HardwareProfile = .current()

    @Published var inputURL: URL?
    @Published var outputURL: URL?

    @Published var isRunning = false
    @Published var isCalibrating = false
    @Published var progress: RunProgress?
    @Published var summary: RunSummary?
    @Published var recent: [ManifestEntry] = []
    @Published var statusMessage = ""

    @Published var modelReady = false
    @Published var modelError: String?
    @Published var personModelDescription = "—"
    @Published var faceModelDescription = "—"

    private var pipeline: ScanPipeline?
    private var inputScope: URL?
    private var outputScope: URL?
    private var didBootstrap = false

    private enum DefaultsKey {
        static let inputBookmark = "inputBookmark"
        static let outputBookmark = "outputBookmark"
        static let configJSON = "configJSON"
    }

    init() {
        self.config = ConfigStore.loadOrDefault()
        restoreBookmarks()
    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        refreshModelStatus()
    }

    func refreshModelStatus() {
        do {
            let suite = try DetectorSuite(config: config)
            modelReady = true
            modelError = nil
            personModelDescription = suite.personDescription
            faceModelDescription = suite.faceDescription
        } catch {
            modelReady = false
            modelError = error.localizedDescription
            personModelDescription = "missing"
            faceModelDescription = "—"
        }
    }

    // MARK: - Folders

    func chooseInputFolder() {
        guard let url = FolderPicker.pick(title: "Choose the folder to scan", readOnly: true) else { return }
        inputURL = url
        config.io.inputPath = url.path
        persistBookmark(url, key: DefaultsKey.inputBookmark, readWrite: false)
        persistConfigSilently()
    }

    func chooseOutputFolder() {
        guard let url = FolderPicker.pick(title: "Choose where clean / review / trash go", readOnly: false) else { return }
        outputURL = url
        config.io.outputPath = url.path
        persistBookmark(url, key: DefaultsKey.outputBookmark, readWrite: true)
        persistConfigSilently()
    }

    private func persistConfigSilently() {
        if let url = ConfigStore.defaultURL() {
            try? ConfigStore.save(config, to: url)
        }
    }

    private func persistBookmark(_ url: URL, key: String, readWrite: Bool) {
        do {
            let data = readWrite
                ? try BookmarkStore.readWriteBookmarkData(for: url)
                : try BookmarkStore.bookmarkData(for: url)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            statusMessage = "Could not remember folder access: \(error.localizedDescription)"
        }
    }

    private func restoreBookmarks() {
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.inputBookmark),
           let (url, _) = try? BookmarkStore.resolve(data) {
            inputURL = url
            if config.io.inputPath.isEmpty { config.io.inputPath = url.path }
        }
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.outputBookmark),
           let (url, _) = try? BookmarkStore.resolve(data) {
            outputURL = url
            if config.io.outputPath.isEmpty { config.io.outputPath = url.path }
        }
    }

    private func beginScope(_ url: URL?) -> URL? {
        guard let url else { return nil }
        return url.startAccessingSecurityScopedResource() ? url : url
    }

    private func endScope(_ url: URL?) {
        url?.stopAccessingSecurityScopedResource()
    }

    /// Calibration reads the input folder outside a run, so it needs its own
    /// scoped-access window.
    func beginInputScope() -> URL? { beginScope(inputURL) }
    func endInputScope(_ url: URL?) { endScope(url) }

    // MARK: - Running

    func startRun() {
        guard !isRunning else { return }
        guard !config.io.inputPath.isEmpty, !config.io.outputPath.isEmpty else {
            statusMessage = "Pick an input and an output folder first."
            return
        }
        inputScope = beginScope(inputURL)
        outputScope = beginScope(outputURL)

        var runConfig = config
        PresetResolver.apply(runConfig.performance.preset, hardware: hardware, to: &runConfig)
        runConfig.io.inputPath = inputURL?.path ?? config.io.inputPath
        runConfig.io.outputPath = outputURL?.path ?? config.io.outputPath

        // Fail loudly if the sandbox revoked folder access (common after a
        // re-signed build), instead of finishing in 0.2 s having done nothing.
        if !FileManager.default.isReadableFile(atPath: runConfig.io.inputPath) {
            endScope(inputScope); endScope(outputScope)
            inputScope = nil; outputScope = nil
            statusMessage = "Can’t read the input folder — press Choose… and re-select it."
            return
        }
        if !FileManager.default.isWritableFile(atPath: runConfig.io.outputPath) {
            endScope(inputScope); endScope(outputScope)
            inputScope = nil; outputScope = nil
            statusMessage = "Can’t write to the output folder — press Choose… and re-select it."
            return
        }

        let pipeline = ScanPipeline(config: runConfig, hardware: hardware)
        self.pipeline = pipeline
        isRunning = true
        progress = nil
        summary = nil
        recent = []

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await pipeline.run(
                    progress: { update in
                        Task { @MainActor in self.progress = update }
                    },
                    onEntry: { entry in
                        Task { @MainActor in
                            self.recent.append(entry)
                            if self.recent.count > 60 { self.recent.removeFirst(self.recent.count - 60) }
                        }
                    }
                )
                await MainActor.run {
                    self.summary = result
                    self.isRunning = false
                    let allSkipped = result.total > 0 && result.counts[.skipped, default: 0] == result.total
                    if result.total == 0 || allSkipped {
                        self.statusMessage = result.notes.last ?? "No images found in the input folder."
                    } else {
                        self.statusMessage = result.cancelled ? "Run cancelled." : "Run complete in \(String(format: "%.1f", result.duration))s."
                    }
                    self.endScope(self.inputScope)
                    self.endScope(self.outputScope)
                    self.inputScope = nil
                    self.outputScope = nil
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.statusMessage = error.localizedDescription
                    self.endScope(self.inputScope)
                    self.endScope(self.outputScope)
                    self.inputScope = nil
                    self.outputScope = nil
                }
            }
        }
    }

    func cancelRun() {
        Task { await pipeline?.cancel() }
    }

    func undoLastRun() {
        let root = outputURL ?? URL(fileURLWithPath: config.io.outputPath)
        do {
            let count = try UndoJournal.undoLatest(outputRoot: root)
            statusMessage = count > 0 ? "Restored \(count) files." : "Nothing to undo."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Forget prior decisions so the next run reprocesses every image.
    func resetManifest() {
        let root = outputURL ?? URL(fileURLWithPath: config.io.outputPath)
        do {
            try ManifestReader.reset(outputRoot: root)
            summary = nil
            progress = nil
            recent = []
            statusMessage = "Manifest reset — the next run will reprocess every image."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Review

    /// Move a review item to another verdict folder, record it in the manifest
    /// so resume agrees, and journal it so Undo can put it back.
    @discardableResult
    func reclassify(_ entry: ManifestEntry, to verdict: Verdict) -> Bool {
        guard let currentDestination = entry.destinationPath else {
            statusMessage = "This file has no recorded location; re-run a scan first."
            return false
        }
        let source = URL(fileURLWithPath: currentDestination)
        let root = outputURL ?? URL(fileURLWithPath: config.io.outputPath)
        do {
            let outcome = try Mover.place(
                source: source,
                outputRoot: root,
                verdict: verdict,
                relativePath: entry.relativePath,
                mode: .move,
                collision: .suffix,
                hash: entry.hash,
                dryRun: false
            )

            // Journal the move so Undo Last Run restores it.
            let journal = try UndoJournal(outputRoot: root)
            journal.record(UndoRecord(
                sourcePath: entry.sourcePath,
                destinationPath: outcome.destination.path,
                hash: entry.hash,
                verdict: verdict
            ))
            journal.close()

            // Record the new verdict so processedHashes reflects reality.
            if let writer = try? ManifestWriter(outputRoot: root, writeCSV: false, writeJSONL: true) {
                writer.append(ManifestEntry(
                    relativePath: entry.relativePath,
                    fileName: entry.fileName,
                    hash: entry.hash,
                    width: entry.width,
                    height: entry.height,
                    verdict: verdict,
                    stage: "manual",
                    topScore: entry.topScore,
                    personScore: entry.personScore,
                    faceScore: entry.faceScore,
                    sourcePath: entry.sourcePath,
                    destinationPath: outcome.destination.path
                ))
                writer.close()
            }

            statusMessage = "Moved \(entry.fileName) to \(verdict.rawValue). Undo Last Run will put it back."
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    /// Load an image plus its detections for the review preview.
    func previewPayload(for url: URL) async -> PreviewPayload? {
        let config = self.config
        return await Task.detached(priority: .userInitiated) { () -> PreviewPayload? in
            guard let loaded = try? ImageLoader.load(at: url, maxPixelSize: 1600) else { return nil }
            var detections: [Detection] = []
            if let suite = try? DetectorSuite(config: config),
               let signals = try? suite.analyze(image: loaded.cgImage, thresholds: config.thresholds) {
                detections = signals.personDetections + signals.faces
            }
            return PreviewPayload(image: loaded.cgImage, detections: detections)
        }.value
    }

    /// Read the manifest off the main thread.
    func loadManifestEntries() async -> [ManifestEntry] {
        let root = outputURL ?? URL(fileURLWithPath: config.io.outputPath)
        return await Task.detached(priority: .userInitiated) {
            ManifestReader.allEntries(outputRoot: root)
        }.value
    }

    func revealInFinder(_ entry: ManifestEntry) {
        let path = entry.destinationPath ?? entry.sourcePath
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func manifestEntries() -> [ManifestEntry] {
        let root = outputURL ?? URL(fileURLWithPath: config.io.outputPath)
        return ManifestReader.allEntries(outputRoot: root)
    }

    // MARK: - Persistence

    func saveConfiguration() {
        if let url = ConfigStore.defaultURL() {
            try? ConfigStore.save(config, to: url)
            statusMessage = "Saved configuration to \(url.lastPathComponent)."
        }
    }

    func resetToAutoPreset() {
        PresetResolver.apply(.auto, hardware: hardware, to: &config)
        refreshModelStatus()
        statusMessage = "Applied auto preset for \(hardware.summary)."
    }

    func applyPreset(_ preset: HardwarePreset) {
        PresetResolver.apply(preset, hardware: hardware, to: &config)
        refreshModelStatus()
    }
}

/// Decoded image plus the detections found on it, for the review preview.
struct PreviewPayload: @unchecked Sendable {
    let image: CGImage
    let detections: [Detection]
}

/// NSOpenPanel wrapper for choosing a folder inside the sandbox.
enum FolderPicker {
    static func pick(title: String, readOnly: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = !readOnly
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

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

    /// Installed models merged with what the Hugging Face repo offers.
    @Published var modelLibrary: [ModelRow] = []
    /// Download progress (0…1) by model stem.
    @Published var downloads: [String: Double] = [:]
    @Published var isCheckingHuggingFace = false
    @Published var huggingFaceStatus: SourceStatus?
    @Published var hasToken = KeychainToken.exists
    @Published var isLoadingModels = false
    private var modelCheckGeneration = 0

    let modelStore = ModelStore()
    private var remoteModels: [RemoteModel] = []
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    /// Read from the Keychain once, on first use.
    private var cachedToken: String??

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

    /// Load the configured models off the main thread (the first load of a
    /// new model compiles it, which takes seconds) and publish the result.
    func refreshModelStatus() {
        rebuildModelLibrary()
        let config = self.config
        modelCheckGeneration += 1
        let generation = modelCheckGeneration
        isLoadingModels = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try DetectorSuite(config: config) }
            }.value
            guard generation == modelCheckGeneration else { return }
            isLoadingModels = false
            switch result {
            case .success(let suite):
                modelReady = true
                modelError = nil
                personModelDescription = suite.personDescription
                faceModelDescription = suite.faceDescription
            case .failure(let error):
                modelReady = false
                modelError = error.localizedDescription
                personModelDescription = "missing"
                faceModelDescription = "—"
            }
        }
    }

    // MARK: - Model library

    var huggingFaceRepoID: String? { config.resolvedModelSource.repoID }

    /// Models the current settings need but that aren't installed yet.
    var missingNeededModels: [ModelRow] {
        modelLibrary.filter { $0.isInUse && !$0.isInstalled }
    }

    private func rebuildModelLibrary() {
        let installed = Dictionary(modelStore.installed().map { ($0.stem, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        let remote = Dictionary(remoteModels.map { ($0.stem, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        let needed = Set(ModelCatalog.stemsNeeded(by: config))
        let stems = Set(installed.keys).union(remote.keys).union(needed)
        modelLibrary = stems
            .sorted { ModelCatalog.sortKey(for: $0) < ModelCatalog.sortKey(for: $1) }
            .map { stem in
                ModelRow(
                    stem: stem,
                    displayName: ModelCatalog.displayName(for: stem),
                    installedBytes: installed[stem],
                    remoteBytes: remote[stem],
                    isInUse: needed.contains(stem)
                )
            }
    }

    private var token: String? {
        if cachedToken == nil { cachedToken = .some(KeychainToken.read()) }
        return cachedToken ?? nil
    }

    private func huggingFaceClient() -> HuggingFaceClient {
        HuggingFaceClient(source: config.resolvedModelSource, token: token)
    }

    /// Ask Hugging Face what the repo holds, so rows show sizes and a
    /// Download button for every model there.
    func checkHuggingFace() {
        guard !isCheckingHuggingFace else { return }
        guard let repo = huggingFaceRepoID else {
            huggingFaceStatus = .init(message: HuggingFaceError.notConfigured.localizedDescription, isError: true)
            return
        }
        isCheckingHuggingFace = true
        let client = huggingFaceClient()
        Task {
            do {
                remoteModels = try await client.listModels()
                huggingFaceStatus = .init(
                    message: remoteModels.isEmpty
                        ? "Connected to \(repo), but it has no .mlpackage models yet."
                        : "Connected to \(repo): \(remoteModels.count) models available.",
                    isError: remoteModels.isEmpty
                )
            } catch {
                huggingFaceStatus = .init(message: error.localizedDescription, isError: true)
            }
            isCheckingHuggingFace = false
            rebuildModelLibrary()
        }
    }

    /// Check the token, fill in the username if it's empty, then list the repo.
    func testHuggingFace() {
        guard let token, !token.isEmpty else {
            checkHuggingFace()
            return
        }
        isCheckingHuggingFace = true
        let client = huggingFaceClient()
        Task {
            do {
                let name = try await client.whoami()
                if config.resolvedModelSource.huggingFaceUsername.trimmingCharacters(in: .whitespaces).isEmpty {
                    var source = config.resolvedModelSource
                    source.huggingFaceUsername = name
                    config.modelSource = source
                    persistConfigSilently()
                }
                isCheckingHuggingFace = false
                checkHuggingFace()
            } catch {
                isCheckingHuggingFace = false
                huggingFaceStatus = .init(message: error.localizedDescription, isError: true)
            }
        }
    }

    func setModelSource(username: String? = nil, repository: String? = nil) {
        var source = config.resolvedModelSource
        if let username { source.huggingFaceUsername = username }
        if let repository { source.huggingFaceRepo = repository }
        guard source != config.resolvedModelSource else { return }
        config.modelSource = source
        remoteModels = []
        huggingFaceStatus = nil
        persistConfigSilently()
        rebuildModelLibrary()
    }

    func saveToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainToken.save(trimmed)
            cachedToken = .some(trimmed)
            hasToken = true
            huggingFaceStatus = .init(message: "Token saved in the Keychain.", isError: false)
        } catch {
            huggingFaceStatus = .init(message: error.localizedDescription, isError: true)
        }
    }

    func clearToken() {
        KeychainToken.delete()
        cachedToken = .some(nil)
        hasToken = false
        huggingFaceStatus = .init(message: "Token removed.", isError: false)
    }

    func downloadModel(_ stem: String) {
        guard downloadTasks[stem] == nil else { return }
        guard let repo = huggingFaceRepoID else {
            statusMessage = HuggingFaceError.notConfigured.localizedDescription
            return
        }
        let client = huggingFaceClient()
        let store = modelStore
        downloads[stem] = 0
        downloadTasks[stem] = Task {
            do {
                if !remoteModels.contains(where: { $0.stem == stem }) {
                    remoteModels = try await client.listModels()
                }
                guard let model = remoteModels.first(where: { $0.stem == stem }) else {
                    throw HuggingFaceError.modelNotAvailable(stem, repo: repo)
                }
                try await client.download(model, into: store) { fraction in
                    Task { @MainActor in
                        if self.downloads[stem] != nil { self.downloads[stem] = fraction }
                    }
                }
                statusMessage = "Downloaded \(ModelCatalog.displayName(for: stem))."
            } catch is CancellationError {
                statusMessage = "Download of \(stem) cancelled."
            } catch {
                statusMessage = "Couldn't download \(stem): \(error.localizedDescription)"
            }
            downloads[stem] = nil
            downloadTasks[stem] = nil
            refreshModelStatus()
        }
    }

    func cancelDownload(_ stem: String) {
        downloadTasks[stem]?.cancel()
    }

    func removeModel(_ stem: String) {
        guard !isRunning else {
            statusMessage = "Stop the scan before removing a model."
            return
        }
        do {
            try modelStore.remove(stem: stem)
            statusMessage = "Removed \(ModelCatalog.displayName(for: stem)). You can download it again any time."
        } catch {
            statusMessage = "Couldn't remove \(stem): \(error.localizedDescription)"
        }
        refreshModelStatus()
    }

    /// Copy `.mlpackage`s the user picks (packages, or folders holding them).
    func importModels() {
        let panel = NSOpenPanel()
        panel.title = "Import CoreML models"
        panel.message = "Choose .mlpackage models, or a folder that contains them."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        let store = modelStore
        statusMessage = "Importing models…"
        Task {
            do {
                let stems = try await Task.detached(priority: .userInitiated) {
                    try store.importPackages(from: urls)
                }.value
                statusMessage = "Imported \(stems.joined(separator: ", "))."
            } catch {
                statusMessage = "Couldn't import models: \(error.localizedDescription)"
            }
            refreshModelStatus()
        }
    }

    func revealModelsFolder() {
        try? FileManager.default.createDirectory(at: modelStore.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(modelStore.directory)
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

/// One model in the library: installed, available on Hugging Face, or needed
/// by the current settings (any combination).
struct ModelRow: Identifiable, Equatable {
    let stem: String
    let displayName: String
    let installedBytes: Int64?
    let remoteBytes: Int64?
    /// The current preset / face settings use this model.
    let isInUse: Bool

    var id: String { stem }
    var isInstalled: Bool { installedBytes != nil }
    var sizeText: String? {
        (installedBytes ?? remoteBytes).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

/// Result of the last Hugging Face check, shown in Settings and on Models.
struct SourceStatus: Equatable {
    let message: String
    let isError: Bool
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

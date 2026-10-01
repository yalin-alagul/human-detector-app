import SwiftUI
import HumanDetectorCore

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var tokenDraft = ""

    var body: some View {
        Form {
            goalSection
            huggingFaceSection
            personSection
            faceSection
            signalSection
            thresholdSection
            panoramaSection
            performanceSection
            behaviorSection
            qaSection
            uiSection
        }
        .formStyle(.grouped)
        // Keep the model list and Start button in step with the chosen model.
        .onChange(of: state.config.person.modelStem) { _, _ in state.refreshModelStatus() }
        .onChange(of: state.config.face.provider) { _, _ in state.refreshModelStatus() }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Restore defaults") {
                    // Keep the folders and model source; only reset tuning.
                    let input = state.config.io.inputPath
                    let output = state.config.io.outputPath
                    let source = state.config.modelSource
                    state.config = ConfigStore.defaultConfig(hardware: state.hardware)
                    state.config.io.inputPath = input
                    state.config.io.outputPath = output
                    state.config.modelSource = source
                    state.refreshModelStatus()
                }
                Spacer()
                Button("Save configuration") { state.saveConfiguration() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.bar)
        }
    }

    private var goalSection: some View {
        Section("Goal") {
            Picker("Keep", selection: Binding(
                get: { state.config.goal ?? .keepHumans },
                set: { state.config.goal = $0 }
            )) {
                ForEach(DetectionGoal.allCases) { Text($0.shortName).tag($0) }
            }
            Text(state.config.resolvedGoal.folderExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var huggingFaceSection: some View {
        Section {
            TextField("Username", text: Binding(
                get: { state.config.resolvedModelSource.huggingFaceUsername },
                set: { state.setModelSource(username: $0) }
            ), prompt: Text("your-hf-username"))
            TextField("Repository", text: Binding(
                get: { state.config.resolvedModelSource.huggingFaceRepo },
                set: { state.setModelSource(repository: $0) }
            ), prompt: Text(ModelSource.defaultRepository))
            HStack {
                SecureField("Access token", text: $tokenDraft,
                            prompt: Text(state.hasToken ? "Saved in Keychain" : "hf_…"))
                    .onSubmit { saveToken() }
                Button("Save") { saveToken() }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Clear") { state.clearToken() }
                    .disabled(!state.hasToken)
            }
            HStack {
                Button("Test connection") { state.testHuggingFace() }
                    .disabled(state.isCheckingHuggingFace)
                if state.isCheckingHuggingFace {
                    ProgressView().controlSize(.small)
                }
                if let status = state.huggingFaceStatus {
                    Text(status.message)
                        .font(.caption)
                        .foregroundStyle(status.isError ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Hugging Face")
        } footer: {
            Text("Models download from huggingface.co/<username>/<repository>. A token is needed only for a private repo; a read-only token from huggingface.co/settings/tokens is enough. Leave the username empty and press Test connection to fill it from the token.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveToken() {
        state.saveToken(tokenDraft)
        tokenDraft = ""
    }

    private var personSection: some View {
        Section("Person detector") {
            Toggle("Enabled", isOn: $state.config.person.enabled)
            Picker("Family", selection: $state.config.person.family) {
                ForEach(ModelFamily.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Size", selection: $state.config.person.size) {
                ForEach(ModelSize.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Task", selection: $state.config.person.task) {
                ForEach(ModelTask.allCases) { Text($0.displayName).tag($0) }
            }
            LabeledContent("Resolved model", value: state.config.person.modelStem)
            HStack {
                Text("Inference size")
                Slider(value: Binding(
                    get: { Double(state.config.person.imageSize) },
                    set: { state.config.person.imageSize = Int($0) }
                ), in: 640...1600, step: 160)
                Text("\(state.config.person.imageSize) px").monospacedDigit().frame(width: 70, alignment: .trailing)
            }
            Picker("Compute units", selection: $state.config.person.computeUnit) {
                ForEach(ComputeUnit.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Rasterize masks (slower; for visualisation only)", isOn: $state.config.person.computeMasks)
            TextField("Custom model path (.mlpackage)", text: Binding(
                get: { state.config.person.customModelPath ?? "" },
                set: { state.config.person.customModelPath = $0.isEmpty ? nil : $0 }
            ))
        }
    }

    private var faceSection: some View {
        Section("Face detector") {
            Toggle("Enabled", isOn: $state.config.face.enabled)
            Picker("Provider", selection: $state.config.face.provider) {
                ForEach(FaceProvider.allCases) { Text($0.displayName).tag($0) }
            }
            Stepper("Minimum face size: \(state.config.face.minimumFaceSize) px",
                    value: $state.config.face.minimumFaceSize, in: 6...200)
            TextField("SCRFD model path (.mlpackage)", text: Binding(
                get: { state.config.face.scrfdModelPath ?? "" },
                set: { state.config.face.scrfdModelPath = $0.isEmpty ? nil : $0 }
            ))
        }
    }

    private var signalSection: some View {
        Section("Extra Vision signals") {
            Toggle("Human rectangles", isOn: $state.config.signals.visionHumanRects)
            Toggle("Body pose", isOn: $state.config.signals.visionBodyPose)
        }
    }

    private var thresholdSection: some View {
        Section("Thresholds") {
            thresholdSlider("Person → trash", value: $state.config.thresholds.yoloTrash)
            thresholdSlider("Person review floor", value: $state.config.thresholds.yoloReviewLow)
            thresholdSlider("Face → trash", value: $state.config.thresholds.faceTrash)
            thresholdSlider("Face review floor", value: $state.config.thresholds.faceReviewLow)
            thresholdSlider("Human-rect → trash", value: $state.config.thresholds.visionHumanTrash)
            thresholdSlider("Body-pose → trash", value: $state.config.thresholds.visionPoseTrash)
        }
    }

    private func thresholdSlider(_ title: String, value: Binding<Float>) -> some View {
        HStack {
            Text(title)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Float($0) }
            ), in: 0...1)
            Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }

    private var panoramaSection: some View {
        Section("Large panoramas") {
            Toggle("Tile oversized images", isOn: $state.config.panorama.enabled)
            Stepper("Long-edge threshold: \(state.config.panorama.longEdgeThreshold) px",
                    value: $state.config.panorama.longEdgeThreshold, in: 1000...12000, step: 500)
            Stepper("Tile size: \(state.config.panorama.tileSize) px",
                    value: $state.config.panorama.tileSize, in: 640...2048, step: 128)
            HStack {
                Text("Tile overlap")
                Slider(value: $state.config.panorama.overlap, in: 0...0.5)
                Text(String(format: "%.0f%%", state.config.panorama.overlap * 100))
                    .monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }

    private var performanceSection: some View {
        Section("Performance") {
            Picker("Preset", selection: $state.config.performance.preset) {
                ForEach(HardwarePreset.allCases) { Text($0.displayName).tag($0) }
            }
            Stepper("Concurrency: \(state.config.performance.concurrency)",
                    value: $state.config.performance.concurrency, in: 1...16)
            Stepper("Prefetch: \(state.config.performance.prefetch)",
                    value: $state.config.performance.prefetch, in: 1...32)
            Toggle("Pause on thermal throttling", isOn: $state.config.performance.pauseOnThermalThrottle)
            LabeledContent("Detected", value: state.hardware.summary)
        }
    }

    private var behaviorSection: some View {
        Section("Behaviour") {
            Picker("File handling", selection: $state.config.io.moveMode) {
                ForEach(MoveMode.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("On name collision", selection: $state.config.io.collisionPolicy) {
                ForEach(CollisionPolicy.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Preserve relative paths", isOn: $state.config.io.preserveRelativePaths)
            Toggle("Resume (skip already-processed hashes)", isOn: $state.config.behavior.resume)
            Toggle("Deduplicate identical files", isOn: $state.config.behavior.deduplicateByHash)
            Toggle("Write CSV manifest", isOn: $state.config.behavior.writeCSV)
            Toggle("Write JSONL manifest", isOn: $state.config.behavior.writeJSONL)
            Toggle("Write per-image sidecar JSON", isOn: $state.config.behavior.writeSidecarJSON)
            Toggle("Skip corrupt files", isOn: $state.config.io.skipCorruptFiles)
        }
    }

    private var qaSection: some View {
        Section("Calibration & QA") {
            Stepper("Calibration sample: \(state.config.qa.calibrationSampleSize) images",
                    value: $state.config.qa.calibrationSampleSize, in: 20...2000, step: 20)
            Stepper("Spot-check sample: \(state.config.qa.spotCheckSampleSize) images",
                    value: $state.config.qa.spotCheckSampleSize, in: 10...1000, step: 10)
            Stepper("Histogram bins: \(state.config.qa.histogramBins)",
                    value: $state.config.qa.histogramBins, in: 10...120, step: 5)
        }
    }

    private var uiSection: some View {
        Section("Interface") {
            HStack {
                Text("Thumbnail size")
                Slider(value: $state.config.ui.thumbnailSize, in: 80...320)
                Text("\(Int(state.config.ui.thumbnailSize)) px").monospacedDigit().frame(width: 60, alignment: .trailing)
            }
            Toggle("Show bounding boxes", isOn: $state.config.ui.showBoxes)
            Toggle("Show masks", isOn: $state.config.ui.showMasks)
            Toggle("Show score heatmap", isOn: $state.config.ui.showHeatmap)
            Toggle("Confirm before moving files", isOn: $state.config.ui.confirmBeforeMove)
        }
    }
}

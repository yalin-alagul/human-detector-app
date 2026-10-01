import SwiftUI
import HumanDetectorCore

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @Binding var selection: SidebarItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                if (!state.modelReady || state.personModelMissing) && !state.isLoadingModels {
                    modelWarning
                }

                goalCard
                folderCard
                tuningCard
                modelsCard

                if let summary = state.summary {
                    summaryCard(summary)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var modelWarning: some View {
        Card(state.modelReady ? "No person model" : "Models not loaded", systemImage: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text(state.modelError ?? (state.modelReady
                    ? "Scans use Apple Vision only, which catches fewer people. Download a person model for better results."
                    : "Download a person model to start scanning."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.huggingFaceRepoID == nil {
                    Text("Models download from your Hugging Face repo. Add your username (and a token if the repo is private) in Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") { selection = .settings }
                } else {
                    HStack(spacing: Theme.rowGap) {
                        ForEach(state.missingNeededModels) { row in
                            Button {
                                state.downloadModel(row.stem)
                            } label: {
                                Label(
                                    row.sizeText.map { "Download \(row.stem) (\($0))" } ?? "Download \(row.stem)",
                                    systemImage: "arrow.down.circle"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.downloads[row.stem] != nil)
                        }
                    }
                }
            }
        }
    }

    private var modelsCard: some View {
        Card(
            "Models",
            systemImage: "shippingbox",
            trailing: AnyView(
                Button("Manage…") { selection = .models }
                    .controlSize(.small)
            )
        ) {
            ModelLibraryView()
        }
    }

    private var goalBinding: Binding<DetectionGoal> {
        Binding(
            get: { state.config.goal ?? .keepHumans },
            set: { state.config.goal = $0 }
        )
    }

    private var goalCard: some View {
        Card("Goal", systemImage: "person.crop.rectangle.stack") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Goal", selection: goalBinding) {
                    ForEach(DetectionGoal.allCases) { goal in
                        Text(goal.shortName).tag(goal)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(state.config.resolvedGoal.folderExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var folderCard: some View {
        Card("Folders", systemImage: "folder") {
            VStack(alignment: .leading, spacing: Theme.rowGap) {
                folderRow(
                    title: "Input",
                    path: state.inputURL?.path ?? state.config.io.inputPath,
                    symbol: "folder",
                    action: state.chooseInputFolder
                )
                Divider()
                folderRow(
                    title: "Output",
                    path: state.outputURL?.path ?? state.config.io.outputPath,
                    symbol: "tray.and.arrow.down",
                    action: state.chooseOutputFolder
                )
                Divider()
                Toggle("Move files into clean / review / trash", isOn: $state.config.behavior.quarantine)
                Toggle("Dry run (log verdicts, move nothing)", isOn: $state.config.behavior.dryRun)
            }
        }
    }

    private func folderRow(title: String, path: String, symbol: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(path.isEmpty ? "Not selected" : path)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .help(path.isEmpty ? "No folder selected" : path)
            }
            Spacer(minLength: 8)
            Button("Choose…", action: action)
        }
    }

    private var tuningCard: some View {
        Card(
            "Model",
            systemImage: "cpu",
            trailing: AnyView(
                Button("Auto for this Mac") { state.resetToAutoPreset() }
                    .controlSize(.small)
            )
        ) {
            VStack(alignment: .leading, spacing: Theme.gap) {
                Picker("Preset", selection: $state.config.performance.preset) {
                    ForEach(HardwarePreset.allCases) { preset in
                        Text(preset.shortName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: state.config.performance.preset) { _, newValue in
                    state.applyPreset(newValue)
                }

                StatGrid(items: [
                    .init(title: "Person model", value: state.personModelDescription, tint: .blue),
                    .init(title: "Face model", value: state.faceModelDescription, tint: .indigo),
                    .init(title: "Inference size", value: "\(state.config.person.imageSize) px"),
                ])

                Text(PresetResolver.tuning(for: state.config.performance.preset, hardware: state.hardware).note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isAllSkipped(_ summary: RunSummary) -> Bool {
        summary.total > 0 && summary.counts[.skipped, default: 0] == summary.total
    }

    private func summaryCard(_ summary: RunSummary) -> some View {
        Card("Last run", systemImage: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: Theme.gap) {
                StatGrid(items: [
                    .init(title: "Total", value: "\(summary.total)"),
                    .init(title: "Clean", value: "\(summary.counts[.clean, default: 0])", tint: .green),
                    .init(title: "Review", value: "\(summary.counts[.review, default: 0])", tint: .orange),
                    .init(title: "Trash", value: "\(summary.counts[.trash, default: 0])", tint: .red),
                    .init(title: "Seconds", value: String(format: "%.1f", summary.duration)),
                ])

                if summary.total == 0 || isAllSkipped(summary) {
                    Label(
                        summary.notes.last ?? "Nothing was processed.",
                        systemImage: "info.circle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.rowGap) { summaryButtons }
                    VStack(alignment: .leading, spacing: Theme.rowGap) { summaryButtons }
                }
            }
        }
    }

    @ViewBuilder
    private var summaryButtons: some View {
        Button {
            state.undoLastRun()
        } label: {
            Label("Undo this run", systemImage: "arrow.uturn.backward")
        }
        Button {
            state.resetManifest()
        } label: {
            Label("Re-run all", systemImage: "arrow.clockwise")
        }
        .help("Forget every past decision so the next scan reprocesses all files")
        Button {
            state.statusMessage = "Review folder is ready."
            selection = .review
        } label: {
            Label("Open review", systemImage: "square.grid.2x2")
        }
    }
}

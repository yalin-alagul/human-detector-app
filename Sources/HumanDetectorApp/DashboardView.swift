import SwiftUI
import HumanDetectorCore

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @Binding var selection: SidebarItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !state.modelReady {
                    modelWarning
                }

                goalCard
                folderCard
                tuningCard

                if let summary = state.summary {
                    summaryCard(summary)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private var modelWarning: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Models not loaded").font(.headline)
                Text(state.modelError ?? "Add a YOLO .mlpackage to Resources/Models.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set up models") { selection = .models }
        }
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var goalBinding: Binding<DetectionGoal> {
        Binding(
            get: { state.config.goal ?? .keepHumans },
            set: { state.config.goal = $0 }
        )
    }

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What do you want to keep?").font(.headline)
            Picker("Goal", selection: goalBinding) {
                ForEach(DetectionGoal.allCases) { goal in
                    Text(goal.displayName).tag(goal)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(state.config.resolvedGoal.folderExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Folders").font(.headline)
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
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func folderRow(title: String, path: String, symbol: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(path.isEmpty ? "Not selected" : path)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
            }
            Spacer()
            Button("Choose…", action: action)
        }
    }

    private var tuningCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model preset").font(.headline)
                Spacer()
                Button("Auto for this Mac") { state.resetToAutoPreset() }
                    .controlSize(.small)
            }
            Picker("Preset", selection: $state.config.performance.preset) {
                ForEach(HardwarePreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: state.config.performance.preset) { _, newValue in
                state.applyPreset(newValue)
            }

            HStack(spacing: 10) {
                MetricTile(title: "Person model", value: state.personModelDescription, tint: .blue)
                MetricTile(title: "Face model", value: state.faceModelDescription, tint: .indigo)
                MetricTile(title: "Input size", value: "\(state.config.person.imageSize) px")
            }
            Text(PresetResolver.tuning(for: state.config.performance.preset, hardware: state.hardware).note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func isAllSkipped(_ summary: RunSummary) -> Bool {
        summary.total > 0 && summary.counts[.skipped, default: 0] == summary.total
    }

    private func summaryCard(_ summary: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last run").font(.headline)
            HStack(spacing: 10) {
                MetricTile(title: "Total", value: "\(summary.total)")
                MetricTile(title: "Clean", value: "\(summary.counts[.clean, default: 0])", tint: .green)
                MetricTile(title: "Review", value: "\(summary.counts[.review, default: 0])", tint: .orange)
                MetricTile(title: "Trash", value: "\(summary.counts[.trash, default: 0])", tint: .red)
                MetricTile(title: "Seconds", value: String(format: "%.1f", summary.duration))
            }
            if summary.total == 0 || isAllSkipped(summary) {
                Label(
                    summary.notes.last ?? "Nothing was processed.",
                    systemImage: "info.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
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
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

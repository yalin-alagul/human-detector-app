import SwiftUI
import HumanDetectorCore

/// Every model the app knows about, with Download / Remove / Cancel per row.
/// Shared by the Dashboard card and the Models page.
struct ModelLibraryView: View {
    @EnvironmentObject private var state: AppState
    var showsFooter = true
    @State private var pendingRemoval: ModelRow?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            if state.modelLibrary.isEmpty {
                Text("No models yet. Set up Hugging Face in Settings, then press Check Hugging Face.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(state.modelLibrary.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                rowView(row)
            }
            if showsFooter {
                Divider()
                footer
            }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.displayName ?? "model")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { row in
            Button("Remove", role: .destructive) { state.removeModel(row.stem) }
        } message: { row in
            Text("\(row.stem) is deleted from this Mac. You can download it again from Hugging Face.")
        }
    }

    private func rowView(_ row: ModelRow) -> some View {
        let progress = state.downloads[row.stem]
        return HStack(spacing: 10) {
            Image(systemName: row.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(row.isInstalled ? Color.green : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if row.isInUse {
                        Text("In use")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(detail(for: row, progress: progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                }
            }
            Spacer(minLength: 8)
            if progress != nil {
                Button("Cancel") { state.cancelDownload(row.stem) }
            } else if row.isInstalled {
                Button("Remove", role: .destructive) { pendingRemoval = row }
                    .disabled(state.isRunning)
                    .help(state.isRunning ? "Stop the scan first" : "Delete this model from this Mac")
            } else {
                Button("Download") { state.downloadModel(row.stem) }
                    .disabled(state.huggingFaceRepoID == nil)
                    .help(state.huggingFaceRepoID == nil
                          ? "Set your Hugging Face username in Settings first"
                          : "Download from huggingface.co/\(state.huggingFaceRepoID ?? "")")
            }
        }
    }

    private func detail(for row: ModelRow, progress: Double?) -> String {
        var parts = [row.stem]
        if let size = row.sizeText { parts.append(size) }
        if let progress {
            parts.append("Downloading \(Int(progress * 100))%")
        } else if row.isInstalled {
            parts.append("Installed")
        } else if row.remoteBytes != nil {
            parts.append("On Hugging Face")
        } else {
            parts.append("Not downloaded")
        }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.rowGap) { footerButtons }
            VStack(alignment: .leading, spacing: Theme.rowGap) { footerButtons }
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        Button {
            state.checkHuggingFace()
        } label: {
            Label("Check Hugging Face", systemImage: "arrow.clockwise")
        }
        .disabled(state.isCheckingHuggingFace || state.huggingFaceRepoID == nil)
        Button {
            state.importModels()
        } label: {
            Label("Import from folder…", systemImage: "square.and.arrow.down")
        }
        Button {
            state.revealModelsFolder()
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        if state.isCheckingHuggingFace || state.isLoadingModels {
            ProgressView().controlSize(.small)
        }
    }
}

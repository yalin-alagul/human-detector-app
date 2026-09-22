import SwiftUI
import AppKit
import HumanDetectorCore

struct ReviewGridView: View {
    @EnvironmentObject private var state: AppState
    @State private var entries: [ManifestEntry] = []
    @State private var filter: Verdict = .review
    @State private var search = ""
    @State private var isLoading = false

    @State private var previewTarget: PreviewTarget?
    @State private var pendingMove: PendingMove?

    private struct PreviewTarget: Identifiable {
        let id: String
        let entry: ManifestEntry
    }

    private struct PendingMove: Identifiable {
        let id = UUID()
        let entry: ManifestEntry
        let verdict: Verdict
    }

    private var side: CGFloat {
        CGFloat(max(120, min(260, state.config.ui.thumbnailSize)))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .searchable(text: $search, prompt: "Filter by file name")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await reload() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { await reload() }
        .sheet(item: $previewTarget) { target in
            ReviewPreviewView(entry: target.entry)
                .environmentObject(state)
        }
        .confirmationDialog(
            "Move “\(pendingMove?.entry.fileName ?? "")”?",
            isPresented: Binding(
                get: { pendingMove != nil },
                set: { if !$0 { pendingMove = nil } }
            ),
            presenting: pendingMove
        ) { target in
            Button("Move to \(target.verdict.displayName)") {
                performMove(target.entry, target.verdict)
                pendingMove = nil
            }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: { target in
            Text("The file moves into the \(target.verdict.rawValue)/ folder. Undo Last Run puts it back.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading manifest…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView(
                "Nothing in \(filter.displayName.lowercased())",
                systemImage: filter.symbol,
                description: Text("Run a scan, or pick another verdict above.")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: side), spacing: 14)], spacing: 14) {
                    ForEach(filtered, id: \.stableID) { entry in
                        ReviewCell(entry: entry, size: side, onOpen: open, onReclassify: requestMove)
                    }
                }
                .padding(16)
            }
        }
    }

    private var header: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([Verdict.review, .trash, .clean, .skipped, .failed], id: \.self) { verdict in
                    Button {
                        filter = verdict
                    } label: {
                        VerdictBadge(verdict: verdict, count: count(for: verdict), isSelected: filter == verdict)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var filtered: [ManifestEntry] {
        entries
            .filter { $0.verdict == filter }
            .filter { search.isEmpty || $0.fileName.localizedCaseInsensitiveContains(search) }
            .sorted { $0.topScore > $1.topScore }
    }

    private func count(for verdict: Verdict) -> Int {
        entries.filter { $0.verdict == verdict }.count
    }

    @MainActor
    private func reload() async {
        isLoading = true
        entries = await state.loadManifestEntries()
        isLoading = false
    }

    private func open(_ entry: ManifestEntry) {
        previewTarget = PreviewTarget(id: entry.stableID, entry: entry)
    }

    private func requestMove(_ entry: ManifestEntry, _ verdict: Verdict) {
        guard entry.verdict != verdict else { return }
        if state.config.ui.confirmBeforeMove {
            pendingMove = PendingMove(entry: entry, verdict: verdict)
        } else {
            performMove(entry, verdict)
        }
    }

    private func performMove(_ entry: ManifestEntry, _ verdict: Verdict) {
        if state.reclassify(entry, to: verdict) {
            Task { await reload() }
        }
    }
}

private struct ReviewCell: View {
    let entry: ManifestEntry
    let size: CGFloat
    let onOpen: (ManifestEntry) -> Void
    let onReclassify: (ManifestEntry, Verdict) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailImage(url: url, size: size)
                .overlay(alignment: .bottomLeading) {
                    Text(entry.verdict.displayName)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(entry.verdict.color)
                        .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .padding(5)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(6)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onOpen(entry) }
                .onTapGesture { onOpen(entry) }

            Text(entry.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.relativePath)

            HStack(spacing: 6) {
                Text(String(format: "%.2f", entry.topScore))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.stage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contextMenu {
            Button("Open preview") { onOpen(entry) }
            Divider()
            Button("Move to Clean") { onReclassify(entry, .clean) }
            Button("Move to Review") { onReclassify(entry, .review) }
            Button("Move to Trash") { onReclassify(entry, .trash) }
        }
    }

    private var url: URL? {
        if let destination = entry.destinationPath { return URL(fileURLWithPath: destination) }
        if !entry.sourcePath.isEmpty { return URL(fileURLWithPath: entry.sourcePath) }
        return nil
    }
}

/// Large preview with detection boxes, honoring the UI toggles.
struct ReviewPreviewView: View {
    let entry: ManifestEntry
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var payload: PreviewPayload?
    @State private var failed = false

    private var url: URL? {
        if let destination = entry.destinationPath { return URL(fileURLWithPath: destination) }
        if !entry.sourcePath.isEmpty { return URL(fileURLWithPath: entry.sourcePath) }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            imageArea
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 560)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VerdictBadge(verdict: entry.verdict)
            Text(entry.fileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.relativePath)
            Spacer()
            Text(String(format: "person %.2f · face %.2f", entry.personScore, entry.faceScore))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    @ViewBuilder
    private var imageArea: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let payload {
                if state.config.ui.showBoxes {
                    DetectionOverlay(cgImage: payload.image, detections: payload.detections, color: .accentColor)
                        .padding(12)
                } else {
                    Image(decorative: payload.image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                }
            } else if failed {
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("The file could not be opened. It may have been moved or deleted.")
                )
            } else {
                ProgressView("Analyzing…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                reveal()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Spacer()
            moveButton(.clean)
            moveButton(.review)
            moveButton(.trash)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func moveButton(_ verdict: Verdict) -> some View {
        Button {
            if state.reclassify(entry, to: verdict) { dismiss() }
        } label: {
            Label(verdict.displayName, systemImage: verdict.symbol)
        }
        .disabled(entry.verdict == verdict || entry.destinationPath == nil)
    }

    private func reveal() {
        guard let path = entry.destinationPath ?? (entry.sourcePath.isEmpty ? nil : entry.sourcePath) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @MainActor
    private func load() async {
        guard let url else { failed = true; return }
        let result = await state.previewPayload(for: url)
        if let result {
            payload = result
        } else {
            failed = true
        }
    }
}

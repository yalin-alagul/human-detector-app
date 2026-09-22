import SwiftUI
import HumanDetectorCore

struct ReviewGridView: View {
    @EnvironmentObject private var state: AppState
    @State private var entries: [ManifestEntry] = []
    @State private var filter: Verdict = .review
    @State private var search = ""
    @State private var isLoading = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                ProgressView("Loading manifest…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView(
                    "Nothing in \(filter.displayName.lowercased())",
                    systemImage: filter.symbol,
                    description: Text("Run a scan, or pick another verdict above.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filtered, id: \.hash) { entry in
                            ReviewCell(entry: entry, onReclassify: reclassify, onReveal: state.revealInFinder)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .searchable(text: $search, prompt: "Filter by file name")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { reload() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ForEach([Verdict.review, .trash, .clean, .skipped, .failed], id: \.self) { verdict in
                Button {
                    filter = verdict
                } label: {
                    VerdictBadge(verdict: verdict, count: count(for: verdict))
                }
                .buttonStyle(.plain)
                .opacity(filter == verdict ? 1 : 0.55)
            }
            Spacer()
        }
        .padding(12)
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

    private func reload() {
        isLoading = true
        let loaded = state.manifestEntries()
        entries = loaded
        isLoading = false
    }

    private func reclassify(_ entry: ManifestEntry, _ verdict: Verdict) {
        state.reclassify(entry, to: verdict)
        reload()
    }
}

private struct ReviewCell: View {
    let entry: ManifestEntry
    let onReclassify: (ManifestEntry, Verdict) -> Void
    let onReveal: (ManifestEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailImage(url: url, size: 150)
                .overlay(alignment: .bottomLeading) {
                    Text(entry.verdict.displayName)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(entry.verdict.color)
                        .padding(6)
                }
            Text(entry.fileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Text(String(format: "%.2f", entry.topScore))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(entry.stage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Move to Clean") { onReclassify(entry, .clean) }
            Button("Move to Review") { onReclassify(entry, .review) }
            Button("Move to Trash") { onReclassify(entry, .trash) }
            Divider()
            Button("Reveal in Finder") { onReveal(entry) }
        }
    }

    private var url: URL? {
        if let destination = entry.destinationPath { return URL(fileURLWithPath: destination) }
        if !entry.sourcePath.isEmpty { return URL(fileURLWithPath: entry.sourcePath) }
        return nil
    }
}

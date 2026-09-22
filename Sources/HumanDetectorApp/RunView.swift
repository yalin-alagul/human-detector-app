import SwiftUI
import HumanDetectorCore

struct RunView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LogoHeader()
            Divider()

            if state.isRunning || state.progress != nil {
                progressSection
            } else {
                ContentUnavailableView(
                    "No scan running",
                    systemImage: "play.circle",
                    description: Text("Pick folders on the Dashboard, then start a scan.")
                )
            }

            if !state.recent.isEmpty {
                Text("Recent images").font(.headline).padding(.horizontal, 20)
                recentStrip
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let progress = state.progress {
                ProgressView(value: Double(progress.processed), total: Double(max(1, progress.total)))
                    .progressViewStyle(.linear)

                HStack(spacing: 10) {
                    MetricTile(title: "Processed", value: "\(progress.processed)/\(progress.total)")
                    MetricTile(title: "Speed", value: String(format: "%.1f img/s", progress.imagesPerSecond), tint: .blue)
                    MetricTile(title: "ETA", value: progress.etaSeconds.map { format($0) } ?? "—", tint: .indigo)
                }
                HStack(spacing: 10) {
                    MetricTile(title: "Clean", value: "\(progress.counts[.clean, default: 0])", tint: .green)
                    MetricTile(title: "Review", value: "\(progress.counts[.review, default: 0])", tint: .orange)
                    MetricTile(title: "Trash", value: "\(progress.counts[.trash, default: 0])", tint: .red)
                }

                Text(progress.currentPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 20)
    }

    private var recentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(state.recent.reversed(), id: \.hash) { entry in
                    VStack(spacing: 6) {
                        ThumbnailImage(url: thumbnailURL(for: entry), size: 120)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: entry.verdict.symbol)
                                    .font(.caption)
                                    .padding(4)
                                    .background(.thinMaterial, in: Circle())
                                    .foregroundStyle(entry.verdict.color)
                                    .padding(4)
                            }
                        Text(entry.fileName)
                            .font(.caption2)
                            .lineLimit(1)
                            .frame(width: 120)
                        Text(String(format: "%.2f", entry.topScore))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func thumbnailURL(for entry: ManifestEntry) -> URL? {
        if let destination = entry.destinationPath {
            return URL(fileURLWithPath: destination)
        }
        return URL(fileURLWithPath: entry.sourcePath)
    }

    private func format(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        if seconds < 3600 { return String(format: "%.0fm", seconds / 60) }
        return String(format: "%.1fh", seconds / 3600)
    }
}

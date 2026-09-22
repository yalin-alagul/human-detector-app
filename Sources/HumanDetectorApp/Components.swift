import SwiftUI
import AppKit
import HumanDetectorCore

// MARK: - Design system

enum Theme {
    static let corner: CGFloat = 12
    static let pad: CGFloat = 16
    static let gap: CGFloat = 12
    static let rowGap: CGFloat = 10

    static var cardFill: AnyShapeStyle { AnyShapeStyle(.regularMaterial) }
    static var hairline: Color { Color(nsColor: .separatorColor).opacity(0.6) }
    static var pageBackground: Color { Color(nsColor: .windowBackgroundColor) }
}

/// One card container for every panel in the app.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    var trailing: AnyView?
    @ViewBuilder var content: () -> Content

    init(
        _ title: String? = nil,
        systemImage: String? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            if title != nil || trailing != nil {
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.tint)
                            .imageScale(.medium)
                    }
                    if let title {
                        Text(title).font(.headline)
                    }
                    Spacer(minLength: 0)
                    trailing
                }
            }
            content()
        }
        .padding(Theme.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
    }
}

/// Compact stat block. No uppercase micro-caps and no monospaced font, so it
/// matches the rest of the interface.
struct StatTile: View {
    let title: String
    let value: String
    var tint: Color = .primary
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Wrapping row of stat tiles — replaces the fixed HStacks that clipped.
struct StatGrid: View {
    struct Item: Identifiable {
        let id = UUID()
        var title: String
        var value: String
        var tint: Color = .primary
        var detail: String?
    }

    let items: [Item]
    var minimum: CGFloat = 128

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minimum), spacing: Theme.rowGap)],
            alignment: .leading,
            spacing: Theme.rowGap
        ) {
            ForEach(items) { item in
                StatTile(title: item.title, value: item.value, tint: item.tint, detail: item.detail)
            }
        }
    }
}

/// Inline status message, used instead of a truncated toolbar label.
struct StatusBanner: View {
    let message: String
    var isWarning: Bool = false
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isWarning ? .orange : .secondary)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            (isWarning ? Color.orange.opacity(0.14) : Color.secondary.opacity(0.12)),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}

extension ManifestEntry {
    /// Unique even for duplicate hashes or failed rows with an empty hash.
    var stableID: String { "\(hash)|\(sourcePath)|\(destinationPath ?? "")" }
}

// MARK: - Brand header

/// The one place the logo is drawn. Used by the sidebar and by the Scan view so
/// the mark is identical in size and spacing everywhere.
struct LogoHeader: View {
    var showsTitle: Bool = true
    var logoSize: CGFloat = 24

    var body: some View {
        HStack(spacing: 8) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: logoSize, height: logoSize)
            if showsTitle {
                Text("Human Detector").font(.headline)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Verdict styling

extension Verdict {
    var color: Color {
        switch self {
        case .clean: return .green
        case .review: return .orange
        case .trash: return .red
        case .skipped: return .gray
        case .failed: return .purple
        }
    }

    var symbol: String {
        switch self {
        case .clean: return "checkmark.seal.fill"
        case .review: return "questionmark.circle.fill"
        case .trash: return "xmark.octagon.fill"
        case .skipped: return "arrow.uturn.forward.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

struct VerdictBadge: View {
    let verdict: Verdict
    var count: Int?
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: verdict.symbol)
            Text(count.map { "\(verdict.displayName) \($0)" } ?? verdict.displayName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            verdict.color.opacity(isSelected ? 0.28 : 0.14),
            in: Capsule()
        )
        .overlay(
            Capsule().strokeBorder(verdict.color.opacity(isSelected ? 0.9 : 0.25), lineWidth: 1)
        )
        .foregroundStyle(verdict.color)
    }
}

// MARK: - Async thumbnail

struct ThumbnailImage: View {
    let url: URL?
    var size: CGFloat = 160
    var contentMode: ContentMode = .fill
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) {
            guard let url else { image = nil; return }
            let target = Int(size * 2)
            let loaded = await Task.detached(priority: .utility) {
                ImageLoader.thumbnail(at: url, maxPixelSize: target)
            }.value
            if !Task.isCancelled { image = loaded }
        }
    }
}

// MARK: - Detection overlay

/// Draws normalized Vision boxes over an image. Vision's origin is bottom-left;
/// SwiftUI's is top-left, so y is flipped here.
struct DetectionOverlay: View {
    let cgImage: CGImage
    let detections: [Detection]
    var color: Color

    var body: some View {
        GeometryReader { geometry in
            let fitted = fittedRect(for: cgImage, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                ForEach(Array(detections.enumerated()), id: \.offset) { _, detection in
                    let rect = viewRect(for: detection.box, in: fitted)
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(color, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }

    /// The letterboxed image rect, so boxes line up with `.fit`.
    private func fittedRect(for image: CGImage, in size: CGSize) -> CGRect {
        let imageAspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        let boxAspect = size.width / max(1, size.height)
        var fitted = size
        if imageAspect > boxAspect {
            fitted.height = size.width / imageAspect
        } else {
            fitted.width = size.height * imageAspect
        }
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private func viewRect(for box: BoundingBox, in fitted: CGRect) -> CGRect {
        CGRect(
            x: fitted.minX + box.x * fitted.width,
            y: fitted.minY + (1 - box.y - box.height) * fitted.height,
            width: box.width * fitted.width,
            height: box.height * fitted.height
        )
    }
}

// MARK: - Score histogram

/// Bar histogram over top scores, with optional threshold marker lines.
struct ScoreHistogram: View {
    let scores: [Float]
    var bins: Int = 40
    var tint: Color = .accentColor
    var markers: [Float] = []

    var body: some View {
        Canvas { context, size in
            guard bins > 0 else { return }
            var buckets = [Int](repeating: 0, count: bins)
            for score in scores {
                let clamped = min(max(score, 0), 1)
                let index = min(bins - 1, Int(clamped * Float(bins)))
                buckets[index] += 1
            }
            let peak = max(1, buckets.max() ?? 1)
            let barWidth = size.width / CGFloat(bins)
            for (index, count) in buckets.enumerated() {
                let height = size.height * CGFloat(count) / CGFloat(peak)
                let rect = CGRect(
                    x: CGFloat(index) * barWidth,
                    y: size.height - height,
                    width: max(1, barWidth - 1),
                    height: height
                )
                context.fill(Path(rect), with: .color(tint.opacity(0.75)))
            }
            for marker in markers {
                let x = size.width * CGFloat(min(max(marker, 0), 1))
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }
}

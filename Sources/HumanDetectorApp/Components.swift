import SwiftUI
import HumanDetectorCore

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

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: verdict.symbol)
            Text(count.map { "\(verdict.displayName) \($0)" } ?? verdict.displayName)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(verdict.color.opacity(0.18), in: Capsule())
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
            ZStack(alignment: .topLeading) {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                ForEach(Array(detections.enumerated()), id: \.offset) { _, detection in
                    let rect = viewRect(for: detection.box, in: geometry.size)
                    Rectangle()
                        .stroke(color, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }

    private func viewRect(for box: BoundingBox, in size: CGSize) -> CGRect {
        CGRect(
            x: box.x * size.width,
            y: (1 - box.y - box.height) * size.height,
            width: box.width * size.width,
            height: box.height * size.height
        )
    }
}

// MARK: - Score histogram

/// Small bar histogram over the top scores recorded in a run.
struct ScoreHistogram: View {
    let scores: [Float]
    var bins: Int = 40
    var tint: Color = .accentColor

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
        }
    }
}

// MARK: - Small labelled metric

struct MetricTile: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

import SwiftUI
import HumanDetectorCore

/// Calibration mode: analyze a random sample once, then drag threshold sliders
/// and watch verdicts update with no further inference.
struct CalibrationView: View {
    @EnvironmentObject private var state: AppState

    @State private var items: [CalibrationItem] = []
    @State private var working = ThresholdConfig()
    @State private var isSampling = false
    @State private var sampleProgress = (0, 0)
    @State private var errorMessage: String?

    private var decisions: [(item: CalibrationItem, decision: Decision)] {
        Calibrator.reevaluate(items: items, thresholds: working, goal: state.config.resolvedGoal)
    }

    private var counts: [Verdict: Int] {
        var result: [Verdict: Int] = [:]
        for pair in decisions { result[pair.decision.verdict, default: 0] += 1 }
        return result
    }

    private var failedCount: Int { items.filter { $0.error != nil }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                controls
                if !items.isEmpty {
                    thresholdEditors
                    results
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { working = state.config.thresholds }
    }

    private var controls: some View {
        Card("Calibration", systemImage: "wand.and.stars") {
            VStack(alignment: .leading, spacing: Theme.gap) {
                Text("Run the pipeline on \(state.config.qa.calibrationSampleSize) random images, spot-check the verdicts, then tune thresholds until nothing that should be kept lands in Trash.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(state.config.resolvedGoal.folderExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.rowGap) { controlButtons }
                    VStack(alignment: .leading, spacing: Theme.rowGap) { controlButtons }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if failedCount > 0 {
                    Label("\(failedCount) sample image(s) could not be read and are not counted as clean.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        Button {
            runSample()
        } label: {
            Label(isSampling ? "Sampling…" : "Analyze sample", systemImage: "wand.and.stars")
        }
        .disabled(isSampling || state.config.io.inputPath.isEmpty)

        if isSampling {
            ProgressView(value: Double(sampleProgress.0), total: Double(max(1, sampleProgress.1)))
                .frame(width: 200)
            Text("\(sampleProgress.0)/\(sampleProgress.1)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Button("Apply thresholds") {
            state.config.thresholds = working
            state.statusMessage = "Calibrated thresholds applied."
        }
        .buttonStyle(.borderedProminent)
        .disabled(items.isEmpty)
    }

    private var thresholdEditors: some View {
        Card("Thresholds", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: Theme.rowGap) {
                slider("Person → trash", $working.yoloTrash)
                slider("Person review floor", $working.yoloReviewLow)
                slider("Face → trash", $working.faceTrash)
                slider("Face review floor", $working.faceReviewLow)
                slider("Human-rect → trash", $working.visionHumanTrash)
                slider("Body-pose → trash", $working.visionPoseTrash)
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Float>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float($0) }), in: 0...1)
            Text(String(format: "%.2f", value.wrappedValue))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private var results: some View {
        Card("Sample results", systemImage: "chart.bar") {
            VStack(alignment: .leading, spacing: Theme.gap) {
                StatGrid(items: [
                    .init(title: "Clean", value: "\(counts[.clean, default: 0])", tint: .green),
                    .init(title: "Review", value: "\(counts[.review, default: 0])", tint: .orange),
                    .init(title: "Trash", value: "\(counts[.trash, default: 0])", tint: .red),
                    .init(title: "Sample", value: "\(items.count)"),
                ])

                Text("Person score distribution")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ScoreHistogram(
                    scores: items.map { $0.signals.personTop },
                    bins: state.config.qa.histogramBins,
                    tint: .blue,
                    markers: [working.yoloReviewLow, working.yoloTrash]
                )
                .frame(height: 90)

                Text("Sample images").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                    ForEach(decisions, id: \.item.relativePath) { pair in
                        VStack(spacing: 4) {
                            ThumbnailImage(url: pair.item.url, size: 132)
                                .overlay(alignment: .topTrailing) {
                                    if pair.item.error != nil {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.caption)
                                            .padding(4)
                                            .background(.thinMaterial, in: Circle())
                                            .foregroundStyle(.orange)
                                            .padding(6)
                                    } else {
                                        Image(systemName: pair.decision.verdict.symbol)
                                            .font(.caption)
                                            .padding(4)
                                            .background(.thinMaterial, in: Circle())
                                            .foregroundStyle(pair.decision.verdict.color)
                                            .padding(6)
                                    }
                                }
                            Text(pair.item.relativePath)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(pair.item.relativePath)
                            Text(String(format: "p %.2f · f %.2f", pair.item.signals.personTop, pair.item.signals.faceTop))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 132)
                    }
                }
            }
        }
    }

    private func runSample() {
        guard !isSampling else { return }
        isSampling = true
        errorMessage = nil
        sampleProgress = (0, state.config.qa.calibrationSampleSize)

        let config = state.config
        let inputPath = state.config.io.inputPath
        let count = config.qa.calibrationSampleSize
        let seed = config.qa.calibrationSeed
        let inputScope = state.beginInputScope()

        Task {
            do {
                let files = try Calibrator.sample(
                    root: URL(fileURLWithPath: inputPath),
                    count: count,
                    seed: seed,
                    extensions: Set(config.io.supportedExtensions)
                )
                let suite = try DetectorSuite(config: config)
                let analyzed = try await Calibrator.analyze(
                    files: files,
                    config: config,
                    suite: suite,
                    onProgress: { done, total in
                        Task { @MainActor in sampleProgress = (done, total) }
                    }
                )
                await MainActor.run {
                    items = analyzed
                    isSampling = false
                    state.endInputScope(inputScope)
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSampling = false
                    state.endInputScope(inputScope)
                }
            }
        }
    }
}

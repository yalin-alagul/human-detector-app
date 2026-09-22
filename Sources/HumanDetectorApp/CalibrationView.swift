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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controls
                if !items.isEmpty {
                    thresholdEditors
                    results
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .onAppear { working = state.config.thresholds }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Calibration").font(.headline)
            Text("Run the pipeline on \(state.config.qa.calibrationSampleSize) random images, spot-check the verdicts, then tune thresholds until no human slips into Clean.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    runSample()
                } label: {
                    Label(isSampling ? "Sampling…" : "Analyze sample", systemImage: "wand.and.stars")
                }
                .disabled(isSampling || state.config.io.inputPath.isEmpty)

                if isSampling {
                    ProgressView(value: Double(sampleProgress.0), total: Double(max(1, sampleProgress.1)))
                        .frame(width: 200)
                }
                Spacer()
                Button("Apply thresholds") {
                    state.config.thresholds = working
                    state.statusMessage = "Calibrated thresholds applied."
                }
                .buttonStyle(.borderedProminent)
                .disabled(items.isEmpty)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var thresholdEditors: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Thresholds").font(.headline)
            slider("Person → trash", $working.yoloTrash)
            slider("Person review floor", $working.yoloReviewLow)
            slider("Face → trash", $working.faceTrash)
            slider("Face review floor", $working.faceReviewLow)
            slider("Human-rect → trash", $working.visionHumanTrash)
            slider("Body-pose → trash", $working.visionPoseTrash)
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func slider(_ title: String, _ value: Binding<Float>) -> some View {
        HStack {
            Text(title).frame(width: 170, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float($0) }), in: 0...1)
            Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                MetricTile(title: "Clean", value: "\(counts[.clean, default: 0])", tint: .green)
                MetricTile(title: "Review", value: "\(counts[.review, default: 0])", tint: .orange)
                MetricTile(title: "Trash", value: "\(counts[.trash, default: 0])", tint: .red)
                MetricTile(title: "Sample", value: "\(items.count)")
            }
            Text("Score distribution (person)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScoreHistogram(scores: items.map { $0.signals.personTop }, bins: state.config.qa.histogramBins, tint: .blue)
                .frame(height: 90)

            Text("Sample images").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 12)], spacing: 12) {
                ForEach(decisions, id: \.item.relativePath) { pair in
                    VStack(spacing: 4) {
                        ThumbnailImage(url: pair.item.url, size: 130)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: pair.decision.verdict.symbol)
                                    .font(.caption)
                                    .padding(4)
                                    .background(.thinMaterial, in: Circle())
                                    .foregroundStyle(pair.decision.verdict.color)
                                    .padding(4)
                            }
                        Text(pair.item.relativePath)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 130)
                        Text(String(format: "p %.2f · f %.2f", pair.item.signals.personTop, pair.item.signals.faceTop))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

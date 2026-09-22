import SwiftUI
import HumanDetectorCore
import AppKit

struct ModelsSetupView: View {
    @EnvironmentObject private var state: AppState

    private var expectedPersonModels: [String] {
        var stems: [String] = []
        for family in ModelFamily.allCases {
            for size in ModelSize.allCases {
                for task in ModelTask.allCases {
                    stems.append("\(family.rawValue)\(size.rawValue)-\(task.rawValue)")
                }
            }
        }
        return stems
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusCard
                searchPathsCard
                instructionsCard
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(state.modelReady ? "Models ready" : "Models missing",
                      systemImage: state.modelReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(state.modelReady ? .green : .orange)
                    .font(.headline)
                Spacer()
                Button {
                    state.refreshModelStatus()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            }
            LabeledContent("Person", value: state.personModelDescription)
            LabeledContent("Face", value: state.faceModelDescription)
            if let error = state.modelError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var searchPathsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where the app looks").font(.headline)
            ForEach(ModelRegistry.searchRoots(), id: \.path) { url in
                HStack {
                    Text(url.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if FileManager.default.fileExists(atPath: url.path) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Open Application Support") {
                    if let support = ConfigStore.defaultURL()?.deletingLastPathComponent() {
                        NSWorkspace.shared.open(support)
                    }
                }
                .controlSize(.small)
                Button("Open output folder") {
                    if let url = state.outputURL ?? (state.config.io.outputPath.isEmpty ? nil : URL(fileURLWithPath: state.config.io.outputPath)) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export the models once").font(.headline)
            Text("Run this from the repository root. It downloads the Ultralytics weights, exports them to CoreML, and drops them into `Resources/Models/`.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("""
            python3 -m venv .venv && source .venv/bin/activate
            pip install ultralytics coremltools onnx onnxruntime
            python Models/export_models.py --family yolo26 --sizes n s m x --task seg
            """)
            .font(.caption.monospaced())
            .padding(10)
            .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)

            Text("Bundled filenames the app resolves").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(expectedPersonModels.joined(separator: "  ·  "))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text("Optional face specialist: scrfd_10g_bnkps.mlpackage")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

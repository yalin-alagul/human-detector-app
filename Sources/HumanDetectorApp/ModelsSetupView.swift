import SwiftUI
import HumanDetectorCore

/// The full model manager: what's installed, what the Hugging Face repo has,
/// and where the files live. The app ships without models; everything here is
/// downloaded or imported on this Mac.
struct ModelsSetupView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                statusCard
                Card("Library", systemImage: "shippingbox") {
                    ModelLibraryView()
                }
                sourceCard
                storageCard
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var statusCard: some View {
        Card(
            state.isLoadingModels ? "Loading models…" : (state.modelReady ? "Models ready" : "Models missing"),
            systemImage: state.modelReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
            trailing: AnyView(
                Button {
                    state.refreshModelStatus()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            )
        ) {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Person", value: state.personModelDescription)
                LabeledContent("Face", value: state.faceModelDescription)
                if let error = state.modelError, !state.modelReady {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sourceCard: some View {
        Card("Hugging Face", systemImage: "icloud.and.arrow.down") {
            VStack(alignment: .leading, spacing: Theme.rowGap) {
                LabeledContent("Repository", value: state.huggingFaceRepoID.map { "huggingface.co/\($0)" } ?? "Not set")
                LabeledContent("Token", value: state.hasToken ? "Saved in Keychain" : "None (public repos only)")
                if let status = state.huggingFaceStatus {
                    Label(status.message, systemImage: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(status.isError ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Theme.rowGap) {
                    Button("Test connection") { state.testHuggingFace() }
                        .disabled(state.isCheckingHuggingFace)
                    Text("Change the username, repository and token in Settings → Hugging Face.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var storageCard: some View {
        Card("Storage", systemImage: "internaldrive") {
            VStack(alignment: .leading, spacing: Theme.rowGap) {
                Text(state.modelStore.directory.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("Models live outside the app so they can be added and removed at any time. Removing one also deletes its compiled cache.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

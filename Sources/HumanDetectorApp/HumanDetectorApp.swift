import SwiftUI
import HumanDetectorCore

@main
struct HumanDetectorApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1040, minHeight: 700)
                .onAppear { state.bootstrap() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Run") {
                Button("Start Scan") { state.startRun() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(state.isRunning)
                Button("Cancel Scan") { state.cancelRun() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!state.isRunning)
                Divider()
                Button("Undo Last Run") { state.undoLastRun() }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
                .frame(width: 720, height: 640)
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard, run, review, calibrate, settings, models
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .run: return "Scan"
        case .review: return "Review"
        case .calibrate: return "Calibrate"
        case .settings: return "Settings"
        case .models: return "Models"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
        case .run: return "play.circle"
        case .review: return "square.grid.2x2"
        case .calibrate: return "slider.horizontal.below.square.filled.and.square"
        case .settings: return "gearshape"
        case .models: return "shippingbox"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: SidebarItem = .dashboard

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .top) { LogoHeader() }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.hardware.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !state.modelReady {
                        Label("Models missing", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            detail
                .navigationTitle(selection.title)
                .toolbar { toolbar }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .dashboard: DashboardView(selection: $selection)
        case .run: RunView()
        case .review: ReviewGridView()
        case .calibrate: CalibrationView()
        case .settings: SettingsView()
        case .models: ModelsSetupView()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .status) {
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if state.isRunning {
                Button(role: .destructive) { state.cancelRun() } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
            } else {
                Button { state.startRun() } label: {
                    Label("Start Scan", systemImage: "play.circle")
                }
                .disabled(!state.modelReady)
            }
        }
    }
}

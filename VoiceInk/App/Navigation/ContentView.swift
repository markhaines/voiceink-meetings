import OSLog
import SwiftData
import SwiftUI

enum ViewType: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case modes = "Modes"
    case models = "AI Models"
    case transcribeAudio = "Transcribe Audio"
    case history = "History"
    case meetings = "Meetings"
    case audio = "Audio"
    case dictionary = "Dictionary"
    case settings = "Settings"

    var id: String { rawValue }
}

final class MainWindowNavigation: ObservableObject {
    static let shared = MainWindowNavigation()

    @Published var selectedView: ViewType = .dashboard

    private init() {}

    func navigate(to destination: String) {
        guard let viewType = ViewType(rawValue: destination) else {
            return
        }

        navigate(to: viewType)
    }

    func navigate(to destination: ViewType) {
        selectedView = destination
    }
}

struct ContentView: View {
    private let logger = Logger(subsystem: "com.hainesy.voiceinkmeetings", category: "ContentView")
    private static let detailBackgroundTintOpacity = 0.50
    @EnvironmentObject private var navigation: MainWindowNavigation
    @Environment(\.modelContext) private var modelContext
    // Owned here, not by `MeetingsView`: `detailView(for:)` below is a `@ViewBuilder` switch
    // over `navigation.selectedView`, so navigating away from `.meetings` destroys and
    // recreates that case's view entirely. A `MeetingRecordingController` owned as
    // `MeetingsView`'s own `@StateObject` would be torn down mid-recording the moment the
    // user clicked any other sidebar item, with no `engine.stop()` ever called -- silently
    // orphaning the capture and leaving the persisted row stuck `.recording` forever. Hoisted
    // to `ContentView` instead, which is created once by `VoiceInk.swift`'s `WindowGroup` and
    // outlives every `detailView(for:)` switch: only the switch's *content* changes when
    // `selectedView` changes, not `ContentView` itself, so this survives navigating away and
    // back. Injected via `.environmentObject` rather than passed as an init parameter because
    // `MeetingsView` is instantiated bare (`MeetingsView()`) from inside that switch.
    @StateObject private var meetingRecordingController = MeetingRecordingController()

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(selectedView: $navigation.selectedView)

            detailContent
        }
        .frame(width: AppWindowLayout.width)
        .frame(minHeight: AppWindowLayout.minimumHeight)
        .environmentObject(meetingRecordingController)
        .onAppear {
            logger.notice("ContentView appeared")
            meetingRecordingController.configure(modelContainer: modelContext.container)
        }
        .onDisappear {
            logger.notice("ContentView disappeared")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDestination)) { notification in
            if let destination = notification.userInfo?["destination"] as? String {
                logger.notice("navigateToDestination received: \(destination, privacy: .public)")
                navigation.navigate(to: destination)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        detailView(for: navigation.selectedView)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(detailBackground)
    }

    private var detailBackground: some View {
        ZStack {
            VisualEffectView(
                material: .sidebar,
                blendingMode: .behindWindow
            )

            AppTheme.Surface.window
                .opacity(Self.detailBackgroundTintOpacity)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private func detailView(for viewType: ViewType) -> some View {
        switch viewType {
        case .dashboard:
            DashboardView()
        case .models:
            ModelManagementView()
        case .transcribeAudio:
            AudioTranscribeView()
        case .history:
            InlineHistoryView()
        case .meetings:
            MeetingsView()
        case .audio:
            AudioSetupView()
        case .dictionary:
            DictionarySettingsView()
        case .modes:
            ModeView()
        case .settings:
            SettingsView()
        }
    }
}

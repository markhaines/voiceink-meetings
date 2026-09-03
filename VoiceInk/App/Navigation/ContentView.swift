import OSLog
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
    // `MeetingRecordingController` (consumed by `MeetingsView` via `@EnvironmentObject`) is
    // deliberately NOT owned here any more. It was originally hoisted from `MeetingsView` to
    // this view specifically so it would outlive `detailView(for:)`'s `@ViewBuilder` switch
    // over `navigation.selectedView` (which destroys/recreates whichever case's view is not
    // selected) -- but `ContentView` itself turned out to be a second door to the same defect:
    // `VoiceInk.swift`'s `Group { if hasCompletedOnboardingV2 { ContentView() } else {
    // OnboardingView() } }` destroys `ContentView`, and everything it owns, the moment
    // Settings resets that flag (`SettingsView.swift`'s "Reset Onboarding" action). A
    // `@StateObject` here would have been torn down exactly like the `MeetingsView` one was.
    // Now owned by `VoiceInkApp` itself (`VoiceInk.swift`), the one thing in this object graph
    // that is never conditionally swapped, and injected into environment above both branches
    // of that `if` -- so it reaches `ContentView` (and `MeetingsView` beneath it) the same way
    // regardless of which branch is showing. See `VoiceInk.swift`'s own comment for the full
    // reasoning and `FORK-PATCHES.md`'s "onboarding-reset" entry for the enumeration of every
    // root-view swap this was checked against.

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(selectedView: $navigation.selectedView)

            detailContent
        }
        .frame(width: AppWindowLayout.width)
        .frame(minHeight: AppWindowLayout.minimumHeight)
        .onAppear {
            logger.notice("ContentView appeared")
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

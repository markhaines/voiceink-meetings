import AppIntents
import AppKit
import FluidAudio
import OSLog
import SwiftData
import SwiftUI

@main
struct VoiceInkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let container: ModelContainer

    @StateObject private var engine: VoiceInkEngine
    @StateObject private var whisperModelManager: WhisperModelManager
    @StateObject private var fluidAudioModelManager: FluidAudioModelManager
    @StateObject private var transcriptionModelManager: TranscriptionModelManager
    @StateObject private var recorderUIManager: RecorderUIManager
    @StateObject private var recordingShortcutManager: RecordingShortcutManager
    @StateObject private var updaterViewModel: UpdaterViewModel
    @StateObject private var menuBarManager: MenuBarManager
    @StateObject private var mainWindowNavigation = MainWindowNavigation.shared
    @StateObject private var aiService = AIService()
    @StateObject private var enhancementService: AIEnhancementService
    @StateObject private var activeWindowService = ActiveWindowService.shared
    // Owned at app scope, not by `ContentView` (where it lived before this comment was
    // written) and not by `MeetingsView` (where it lived before that): both are child views
    // this `body` conditionally destroys and recreates -- `MeetingsView` by
    // `ContentView.detailView(for:)`'s sidebar switch, `ContentView` itself by the
    // `hasCompletedOnboardingV2` branch below swapping it for `OnboardingView` (Settings'
    // "Reset Onboarding" flips that flag at runtime). `VoiceInkApp` is the one thing in this
    // graph that is never conditionally swapped -- it is the `@main` entry point's own struct,
    // re-evaluated but never replaced -- so this is the actual lifetime boundary a live
    // recording needs. Injected into environment above BOTH branches of that `if`, not just
    // the `ContentView` one, so the object identity is the same regardless of which is
    // showing (see `body`, below). See `FORK-PATCHES.md`'s "onboarding-reset" entry for the
    // enumeration of every place this app swaps its root view, checked against this fix.
    @StateObject private var meetingRecordingController: MeetingRecordingController
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboardingV2 = false
    @State private var showMenuBarIcon = true
    @State private var didShowLaunchReminders = false

    // Audio cleanup manager for automatic deletion of old audio files
    private let audioCleanupManager = AudioCleanupManager.shared

    // Transcription auto-cleanup service for zero data retention
    private let transcriptionAutoCleanupService = TranscriptionAutoCleanupService.shared

    // Model prewarm service for optimizing model on wake from sleep
    @StateObject private var prewarmService: ModelPrewarmService

    init() {
        // Disable HTTP response caching — prevents API responses from being stored in Cache.db
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)

        AppDefaults.registerDefaults()
        AppLanguagePreference.applyStored()
        AppAppearancePreference.applyStored()
        OnboardingV2Migration.prepareIfNeeded()

        let logger = Logger(subsystem: "com.hainesy.voiceinkmeetings", category: "Initialization")
        // Keep existing model order stable; append new models after synced entities.
        let schema = Schema([
            Transcription.self,
            VocabularyWord.self,
            WordReplacement.self,
            SessionMetric.self,
            Meeting.self,
            MeetingSegment.self,
        ])
        let resolvedContainer: ModelContainer

        // Attempt 1: Try persistent storage
        do {
            resolvedContainer = try Self.createPersistentContainer(schema: schema, logger: logger)
        } catch let persistentError {
            // Attempt 2: Try in-memory storage
            do {
                resolvedContainer = try Self.createInMemoryContainer(schema: schema, logger: logger)
                logger.warning("Using in-memory storage as fallback. Data will not persist between sessions.")

                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Storage Warning")
                    alert.informativeText = String(
                        localized:
                            "VoiceInk couldn't access its storage location. Your transcriptions will not be saved between sessions."
                    )
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: "OK"))
                    alert.runModal()
                }
            } catch let memoryError {
                let persistentDetail = Self.fullErrorDescription(persistentError)
                let memoryDetail = Self.fullErrorDescription(memoryError)
                logger.critical(
                    "❌ All ModelContainer init attempts failed.\nPersistent:\n\(persistentDetail, privacy: .public)\nIn-memory:\n\(memoryDetail, privacy: .public)"
                )
                fatalError(
                    "VoiceInk failed to initialize storage.\nPersistent:\n\(persistentDetail)\nIn-memory:\n\(memoryDetail)"
                )
            }
        }

        container = resolvedContainer
        DictionaryService.removeExactDuplicateContent(context: resolvedContainer.mainContext, source: "launch")

        // PR #15 review round 3, B1-ii: reconciles any `Meeting` left `.recording`/`.paused` by
        // a process that no longer exists (crash, `kill -9`, power cut, or simply a quit that
        // outran `AppDelegate.applicationShouldTerminate(_:)`'s bounded finalize window -- see
        // that method's own comment). Must run here, synchronously, in `init()`, BEFORE this
        // `App`'s `body` -- and therefore any UI, and therefore any `MeetingRecordingController
        // .startMeeting` call in THIS process -- is ever evaluated: that ordering is what makes
        // "no live recording in this process yet" true by construction rather than merely
        // likely, so this can never race a meeting this same process is actively recording. See
        // `MeetingStore.reconcileInterruptedRecordings(in:)`'s own doc comment for the full
        // reasoning, including the residual it does not cover (two processes of the same build
        // launched directly and racing each other, rather than through the Dock/LaunchServices).
        // Same idiom as dictation's own `recorderUIManager.resetOnLaunch()` below, applied to
        // meetings' separate persisted lifecycle.
        //
        // PR #15 review round 4, B2: a failed reconciliation write used to be swallowed
        // silently (see `reconcileInterruptedRecordings`'s own doc comment) -- a stale
        // `.recording` row would then reappear at the NEXT launch too, with nothing having
        // told anyone the first attempt failed. Caught here and surfaced the same way this
        // `init()` already surfaces the in-memory-storage-fallback warning earlier above:
        // logged at `.critical`, plus a blocking `NSAlert` so Mark cannot miss it. NOT a
        // `fatalError` -- the container itself already resolved fine to get this far, so
        // hard-failing the whole app's launch (dictation included) over a meetings-only
        // housekeeping write would be a disproportionate response to a narrower problem than
        // the one that alert-vs-crash decision above is guarding against. The alert's wording
        // says plainly that a "Recording" badge in the Meetings list may not be trustworthy --
        // the specific harm this fix exists to prevent is Mark trusting a live-looking UI that
        // reconciliation could not actually make true.
        do {
            let reconciledCount = try MeetingStore.reconcileInterruptedRecordings(in: resolvedContainer)
            if reconciledCount > 0 {
                logger.notice("Reconciled \(reconciledCount) interrupted meeting(s) from a previous session.")
            }
        } catch {
            logger.critical(
                "Failed to reconcile interrupted meetings at launch: \(Self.fullErrorDescription(error), privacy: .public)"
            )
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = String(localized: "Meetings Storage Warning")
                alert.informativeText = String(
                    localized:
                        "VoiceInk couldn't check for meetings left over from a previous session. If any meeting in the Meetings list still shows as \"Recording,\" it may not actually be active -- treat that status as unreliable until this is resolved."
                )
                alert.alertStyle = .warning
                alert.addButton(withTitle: String(localized: "OK"))
                alert.runModal()
            }
        }

        // `MeetingRecordingController.configure(modelContainer:)` can be called directly here,
        // synchronously, rather than deferred to a view's `onAppear` -- `resolvedContainer` is
        // already resolved above, unlike in a view (where the `\.modelContext` environment key
        // it originally read isn't available until a view's own lifecycle callbacks run).
        let meetingRecordingController = MeetingRecordingController()
        meetingRecordingController.configure(modelContainer: resolvedContainer)
        _meetingRecordingController = StateObject(wrappedValue: meetingRecordingController)

        // Initialize services with proper sharing of instances
        let aiService = AIService()
        _aiService = StateObject(wrappedValue: aiService)
        aiService.refreshOllamaAvailabilityInBackground()

        let updaterViewModel = UpdaterViewModel()
        _updaterViewModel = StateObject(wrappedValue: updaterViewModel)

        let enhancementService = AIEnhancementService(aiService: aiService, modelContext: resolvedContainer.mainContext)
        _enhancementService = StateObject(wrappedValue: enhancementService)

        // 1. Create modelsDirectory URL
        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hainesy.VoiceInkMeetings")
        let modelsDirectory = appSupportDirectory.appendingPathComponent("WhisperModels")

        // 2. Create model managers
        let whisperModelManager = WhisperModelManager(modelsDirectory: modelsDirectory)
        let fluidAudioModelManager = FluidAudioModelManager()
        let transcriptionModelManager = TranscriptionModelManager(
            whisperModelManager: whisperModelManager,
            fluidAudioModelManager: fluidAudioModelManager
        )

        // 3. Create UI manager
        let recorderUIManager = RecorderUIManager()

        // 4. Create engine
        let engine = VoiceInkEngine(
            modelContext: resolvedContainer.mainContext,
            whisperModelManager: whisperModelManager,
            transcriptionModelManager: transcriptionModelManager,
            enhancementService: enhancementService
        )

        // 5. Configure circular deps
        recorderUIManager.configure(engine: engine, recorder: engine.recorder)
        engine.recorderUIManager = recorderUIManager

        // 6. Initialize model state
        // Migration and refreshAllAvailableModels must run before loadCurrentTranscriptionModel so renamed keys are remapped and imported models are present when restoring the saved selection.
        StreamingKeysMigration.run()
        whisperModelManager.createModelsDirectoryIfNeeded()
        whisperModelManager.loadAvailableModels()
        transcriptionModelManager.refreshAllAvailableModels()
        transcriptionModelManager.loadCurrentTranscriptionModel()

        _whisperModelManager = StateObject(wrappedValue: whisperModelManager)
        _fluidAudioModelManager = StateObject(wrappedValue: fluidAudioModelManager)
        _transcriptionModelManager = StateObject(wrappedValue: transcriptionModelManager)
        _recorderUIManager = StateObject(wrappedValue: recorderUIManager)
        _engine = StateObject(wrappedValue: engine)

        // 7. Create other services that depend on engine
        let recordingShortcutManager = RecordingShortcutManager(engine: engine, recorderUIManager: recorderUIManager)
        _recordingShortcutManager = StateObject(wrappedValue: recordingShortcutManager)

        let menuBarManager = MenuBarManager()
        _menuBarManager = StateObject(wrappedValue: menuBarManager)
        menuBarManager.configure(modelContainer: resolvedContainer, engine: engine)

        let activeWindowService = ActiveWindowService.shared
        _activeWindowService = StateObject(wrappedValue: activeWindowService)

        let prewarmService = ModelPrewarmService(
            transcriptionModelManager: transcriptionModelManager,
            whisperModelManager: whisperModelManager,
            modelContext: resolvedContainer.mainContext
        )
        _prewarmService = StateObject(wrappedValue: prewarmService)

        appDelegate.menuBarManager = menuBarManager
        // PR #15 review round 3, B1-i: lets `applicationShouldTerminate(_:)` find a live
        // recording to finalize before the app quits. See that method's own comment.
        appDelegate.meetingRecordingController = meetingRecordingController

        // Ensure no lingering recording state from previous runs
        Task {
            await recorderUIManager.resetOnLaunch()
        }

        AppShortcuts.updateAppShortcutParameters()

        let statsMigrationTask = SessionMetricMigrationService.shared.runStatsMigrationIfNeeded(
            modelContainer: resolvedContainer)
        let mainContext = resolvedContainer.mainContext
        Task { @MainActor in
            await statsMigrationTask?.value
            TranscriptionAutoCleanupService.shared.startMonitoring(modelContext: mainContext)

            let tokenBackfillTask = SessionMetricMigrationService.shared.runEnhancementTokenBackfillIfNeeded(
                modelContainer: resolvedContainer)
            await tokenBackfillTask?.value
        }
    }

    // MARK: - Container Creation Helpers

    private static func fullErrorDescription(_ error: Error, depth: Int = 0) -> String {
        let ns = error as NSError
        let indent = String(repeating: "  ", count: depth)
        var lines: [String] = []
        lines.append("\(indent)[\(ns.domain) \(ns.code)] \(ns.localizedDescription)")
        for (key, value) in ns.userInfo {
            let keyStr = "\(key)"
            if keyStr == NSUnderlyingErrorKey || keyStr == "NSDetailedErrors" { continue }
            lines.append("\(indent)  \(keyStr): \(value)")
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            lines.append("\(indent)  Underlying:")
            lines.append(fullErrorDescription(underlying, depth: depth + 2))
        }
        if let details = ns.userInfo["NSDetailedErrors"] as? [Error] {
            lines.append("\(indent)  DetailedErrors (\(details.count)):")
            for (i, detail) in details.enumerated() {
                lines.append("\(indent)    [\(i)]:")
                lines.append(fullErrorDescription(detail, depth: depth + 3))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func createPersistentContainer(schema: Schema, logger: Logger) throws -> ModelContainer {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hainesy.VoiceInkMeetings", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let defaultStoreURL = appSupportURL.appendingPathComponent("default.store")
        let dictionaryStoreURL = appSupportURL.appendingPathComponent("dictionary.store")
        let statsStoreURL = appSupportURL.appendingPathComponent("stats.store")
        let meetingsStoreURL = appSupportURL.appendingPathComponent("meetings.store")

        let transcriptSchema = Schema([Transcription.self])
        let transcriptConfig = ModelConfiguration(
            "default",
            schema: transcriptSchema,
            url: defaultStoreURL,
            cloudKitDatabase: .none
        )

        let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
        // Fork has no iCloud container / Developer Team yet (Phase 5); dictionary.store is
        // local-only until then. See FORK-PATCHES.md.
        let dictionaryCloudKit: ModelConfiguration.CloudKitDatabase = .none
        let dictionaryConfig = ModelConfiguration(
            "dictionary",
            schema: dictionarySchema,
            url: dictionaryStoreURL,
            cloudKitDatabase: dictionaryCloudKit
        )

        let statsSchema = Schema([SessionMetric.self])
        let statsConfig = ModelConfiguration(
            "stats",
            schema: statsSchema,
            url: statsStoreURL,
            cloudKitDatabase: .none
        )

        // Local-only, same as the other three stores (fork has no iCloud container yet — see
        // FORK-PATCHES.md). Meeting audio itself lives on disk under
        // `MeetingRuntimePaths.meetingAudioDirectory()`, not in this store; this only holds the
        // `Meeting`/`MeetingSegment` metadata and transcript rows.
        let meetingsSchema = Schema([Meeting.self, MeetingSegment.self])
        let meetingsConfig = ModelConfiguration(
            "meetings",
            schema: meetingsSchema,
            url: meetingsStoreURL,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(
                for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig, meetingsConfig)
        } catch {
            logger.error(
                "❌ Failed to create persistent ModelContainer:\n\(Self.fullErrorDescription(error), privacy: .public)")
            throw error
        }
    }

    private static func createInMemoryContainer(schema: Schema, logger: Logger) throws -> ModelContainer {
        let transcriptSchema = Schema([Transcription.self])
        let transcriptConfig = ModelConfiguration("default", schema: transcriptSchema, isStoredInMemoryOnly: true)

        let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
        let dictionaryConfig = ModelConfiguration("dictionary", schema: dictionarySchema, isStoredInMemoryOnly: true)

        let statsSchema = Schema([SessionMetric.self])
        let statsConfig = ModelConfiguration("stats", schema: statsSchema, isStoredInMemoryOnly: true)

        let meetingsSchema = Schema([Meeting.self, MeetingSegment.self])
        let meetingsConfig = ModelConfiguration("meetings", schema: meetingsSchema, isStoredInMemoryOnly: true)

        do {
            return try ModelContainer(
                for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig, meetingsConfig)
        } catch {
            logger.error(
                "❌ Failed to create in-memory ModelContainer:\n\(Self.fullErrorDescription(error), privacy: .public)")
            throw error
        }
    }

    var body: some Scene {
        Window("VoiceInk", id: AppWindowID.main) {
            Group {
                if hasCompletedOnboardingV2 {
                    ContentView()
                        .environmentObject(engine)
                        .environmentObject(whisperModelManager)
                        .environmentObject(fluidAudioModelManager)
                        .environmentObject(transcriptionModelManager)
                        .environmentObject(recorderUIManager)
                        .environmentObject(recordingShortcutManager)
                        .environmentObject(updaterViewModel)
                        .environmentObject(menuBarManager)
                        .environmentObject(mainWindowNavigation)
                        .environmentObject(aiService)
                        .environmentObject(enhancementService)
                        .modelContainer(container)
                        .onAppear {
                            showLaunchRemindersIfNeeded()

                            // Run due audio-only cleanup and schedule future checks when transcript cleanup is not managing retention.
                            if !UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled)
                                && UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled)
                            {
                                Task {
                                    await audioCleanupManager.runAutomaticCleanupIfNeeded(
                                        modelContext: container.mainContext)
                                }
                                audioCleanupManager.startAutomaticCleanup(modelContext: container.mainContext)
                            }

                            // Process any pending open-file request now that the main ContentView is ready.
                            if let pendingURL = appDelegate.pendingOpenFileURL {
                                NotificationCenter.default.post(
                                    name: .navigateToDestination, object: nil,
                                    userInfo: ["destination": "Transcribe Audio"])
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    NotificationCenter.default.post(
                                        name: .openFileForTranscription, object: nil, userInfo: ["url": pendingURL])
                                }
                                appDelegate.pendingOpenFileURL = nil
                            }
                        }
                        .background(
                            WindowAccessor { window in
                                WindowManager.shared.configureWindow(window)
                            }
                        )
                        .onDisappear {
                            whisperModelManager.unloadModel()

                            // Stop the automatic audio cleanup process
                            audioCleanupManager.stopAutomaticCleanup()
                        }
                } else {
                    OnboardingView(hasCompletedOnboardingV2: $hasCompletedOnboardingV2)
                        .environmentObject(fluidAudioModelManager)
                        .environmentObject(transcriptionModelManager)
                        .environmentObject(aiService)
                        .environmentObject(enhancementService)
                        .frame(width: AppWindowLayout.width)
                        .frame(minHeight: AppWindowLayout.minimumHeight)
                        .background(
                            WindowAccessor { window in
                                WindowManager.shared.configureWindow(window)
                            })
                }
            }
            // Injected above BOTH branches of the `if`, not only the `ContentView` one, so
            // `meetingRecordingController`'s identity is the same object whichever branch is
            // showing -- see that property's own declaration comment above.
            .environmentObject(meetingRecordingController)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: AppWindowLayout.width, height: AppWindowLayout.minimumHeight)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updaterViewModel: updaterViewModel)
            }
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(engine)
                .environmentObject(whisperModelManager)
                .environmentObject(fluidAudioModelManager)
                .environmentObject(transcriptionModelManager)
                .environmentObject(recorderUIManager)
                .environmentObject(recordingShortcutManager)
                .environmentObject(menuBarManager)
                .environmentObject(mainWindowNavigation)
                .environmentObject(updaterViewModel)
                .environmentObject(aiService)
                .environmentObject(enhancementService)
        } label: {
            let image: NSImage = {
                let ratio = $0.size.height / $0.size.width
                $0.size.height = 22
                $0.size.width = 22 / ratio
                return $0
            }(NSImage(named: "menuBarIcon")!)

            Image(nsImage: image)
                .background(MainWindowRequestBridge(menuBarManager: menuBarManager))
        }
        .menuBarExtraStyle(.menu)

        #if DEBUG
            WindowGroup("Debug") {
                Button("Toggle Menu Bar Only") {
                    menuBarManager.isMenuBarOnly.toggle()
                }
            }
        #endif
    }

    /// Only one notification fits on screen, so show at most one launch reminder.
    private func showLaunchRemindersIfNeeded() {
        guard !didShowLaunchReminders else { return }
        didShowLaunchReminders = true

        if !AXIsProcessTrusted() {
            NotificationManager.shared.showNotification(
                title: String(localized: "Accessibility permission is not provided"),
                type: .warning,
                duration: 7.0,
                actionButton: (String(localized: "Open Settings"), Self.openAccessibilitySettings)
            )
            return
        }

        if !ModeManager.shared.hasEnabledConfiguration {
            NotificationManager.shared.showNotification(
                title: String(localized: "No mode configured"),
                type: .warning,
                duration: 7.0,
                actionButton: (String(localized: "Manage Modes"), ModeSetupNavigator.openModesSettings)
            )
        }
    }

    private static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct MainWindowRequestBridge: View {
    @Environment(\.openWindow) private var openWindow
    let menuBarManager: MenuBarManager

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .showMainWindowRequested)) { _ in
                let existingWindow = WindowManager.shared.currentMainWindow()

                if existingWindow == nil {
                    menuBarManager.activateForPresentedWindow()
                    WindowManager.shared.prepareForUserRequestedMainWindow()
                    openWindow(id: AppWindowID.main)
                } else {
                    menuBarManager.activateForPresentedWindow()
                    openWindow(id: AppWindowID.main)
                    WindowManager.shared.showMainWindow()
                }
            }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        notifyWindowIfNeeded(for: view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        notifyWindowIfNeeded(for: nsView, context: context)
    }

    private func notifyWindowIfNeeded(for view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window,
                context.coordinator.window !== window
            {
                context.coordinator.window = window
                callback(window)
            }
        }
    }

    final class Coordinator {
        weak var window: NSWindow?
    }
}

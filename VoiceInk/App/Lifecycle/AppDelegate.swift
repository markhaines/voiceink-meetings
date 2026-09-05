import Cocoa
import SwiftUI
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarManager: MenuBarManager?

    // Fork addition (PR #15 review round 3, B1-i): weak for the same reason `menuBarManager`
    // above is -- this delegate does not own the controller's lifetime, `VoiceInkApp` does (see
    // `VoiceInk.swift`'s `meetingRecordingController` property and its own wiring of this
    // property). Used only by `applicationShouldTerminate(_:)` below.
    weak var meetingRecordingController: MeetingRecordingController?
    private var isTerminatingForMeetingFinalize = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarManager?.applyActivationPolicy()
    }

    // Fork addition (PR #15 review round 3, B1-i): without this, quitting mid-recording
    // (Cmd-Q, Dock > Quit, logout, shutdown) terminates the process without ever calling
    // `MeetingEngine.stop()` -- the persisted row stays `.recording` forever and the meeting's
    // completion data is lost. `applicationShouldTerminate(_:)` returning `.terminateLater` and
    // replying via `NSApp.reply(toApplicationShouldTerminate:)` once finalize finishes (or the
    // ceiling wins) is the standard AppKit hook for exactly this. `NSApplication
    // .willTerminateNotification` was considered first, per instruction, and rejected: it fires
    // only once AppKit has already committed to terminating, with nothing to delay that
    // decision, so an async `Task` started from it races the process's own teardown with no way
    // to make the process wait -- it cannot actually guarantee the finalize work runs to
    // completion, which is the entire requirement here. Only `applicationShouldTerminate(_:)`'s
    // `.terminateLater` reply lets this delegate hold up termination on purpose.
    //
    // Bounded via `raceAgainstCeiling` (`MeetingQuitRace.swift`), NOT a `withTaskGroup` -- see
    // that file's header for why a task-group shape is actually broken here (it cannot return
    // until every child genuinely finishes, and `MeetingEngine.stop()`'s call chain has no
    // cancellation checks anywhere that would let `cancelAll()` actually cut it short). This
    // method replies `true` to AppKit whichever side of the race wins -- a user who cannot quit
    // their Mac is a worse outcome than a stranded row, and a stranded row left by the ceiling
    // (or by anything this hook can never catch at all -- `kill -9`, a panic, a power cut) is
    // reconciled truthfully at next launch regardless
    // (`MeetingStore.reconcileInterruptedRecordings(in:)`, called from `VoiceInk.swift`'s
    // `init()`). This hook is a best-effort improvement layered on that safety net, not a
    // replacement for it.
    static let meetingFinalizeTimeoutSeconds: UInt64 = 5

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminatingForMeetingFinalize else { return .terminateLater }
        guard let controller = meetingRecordingController, controller.phase == .recording else {
            return .terminateNow
        }
        isTerminatingForMeetingFinalize = true

        raceAgainstCeiling(
            ceilingNanoseconds: Self.meetingFinalizeTimeoutSeconds * 1_000_000_000,
            work: { _ = await controller.stopMeetingAndWait() },
            onComplete: { _ in NSApp.reply(toApplicationShouldTerminate: true) }
        )

        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let menuBarManager, !menuBarManager.isMenuBarOnly {
            if WindowManager.shared.currentMainWindow() != nil {
                WindowManager.shared.showMainWindow()
                return false
            }

            WindowManager.shared.prepareForUserRequestedMainWindow()
            NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
            return false
        }

        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Stash URL when app cold-starts to avoid spawning a new window/tab
    var pendingOpenFileURL: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { SupportedMedia.isSupported(url: $0) }) else {
            return
        }

        if let menuBarManager {
            menuBarManager.activateForPresentedWindow()
        } else {
            AppPresentationPolicy.activateForUserFacingWindow()
        }

        if WindowManager.shared.currentMainWindow() == nil {
            // Cold start: do NOT create a window here to avoid extra window/tab.
            // Defer to SwiftUI's main window scene and let ContentView process this later.
            pendingOpenFileURL = url
            WindowManager.shared.prepareForUserRequestedMainWindow()
            NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
        } else {
            // Running: focus current window and route in-place to Transcribe Audio
            WindowManager.shared.showMainWindow()
            NotificationCenter.default.post(
                name: .navigateToDestination, object: nil, userInfo: ["destination": "Transcribe Audio"])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openFileForTranscription, object: nil, userInfo: ["url": url])
            }
        }
    }
}

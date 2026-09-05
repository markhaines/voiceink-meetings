// UI-facing wrapper around `MeetingEngine` (`Workflows/MeetingEngine.swift`), the first and
// only caller of that engine anywhere in the app today — nothing outside `Features/Meetings/`
// references it, and nothing inside it did either before this file (verified by grep before
// writing this). `MeetingEngine` is not an `ObservableObject`; its progress is reported via
// closures (`onMicHealthChanged`, etc.), not `@Published` properties. This type exists solely
// to translate "start/stop button tapped" into engine calls and surface the resulting
// idle/recording/error state to SwiftUI, nothing more.
//
// Wired with `NullMeetingTranscriptionCoordinator` explicitly (matches `MeetingEngine`'s own
// default) and `retainRecording: false`. The engine's own init doc says `retainRecording` has
// NO DEFAULT deliberately, because it decides whether a recording of the OTHER PARTICIPANTS on
// a call is written to disk, and there is no settings surface yet for a user to have chosen
// that. `false` here is that same reasoning applied at this call site, plus a second, concrete
// reason found while fixing this branch's launch/UI review round: even with it on,
// `MeetingEngineResult.retainedRecordingURL` is only ever a temp WAV path, never moved to
// permanent storage on this branch (that migration is explicitly a later stage's job -- see
// `MeetingEngine.swift`'s own header) -- and this controller does not capture that field from
// `stop()`'s result at all. Flipping the flag today would not give Mark a kept recording; it
// would leak an unreferenced temp file nothing shows or ever cleans up, which is a worse
// failure mode than the current honestly-empty row. See `FOLLOWUPS.md`'s "`retainRecording`
// stays false" entry. Real transcription (Stage 2c) is not built yet, so every meeting
// recorded through this controller persists with real audio capture and mic/system chunk
// rotation, but an empty transcript — see `MeetingsView.recordingDisclosureText`, which states
// this plainly rather than pretending nothing was recorded.
//
// Owned by `VoiceInkApp` itself (`VoiceInk.swift`, `@StateObject`), not by any view. It was
// owned by `MeetingsView`, then by `ContentView`, in earlier rounds of this same fix -- both
// were wrong for the same reason: each is a child view something above it conditionally
// destroys and recreates (`MeetingsView` by `ContentView.detailView(for:)`'s sidebar switch;
// `ContentView` by `VoiceInk.swift`'s `hasCompletedOnboardingV2` branch, flipped by Settings'
// "Reset Onboarding" action). `VoiceInkApp` is the one thing in the object graph that is never
// conditionally swapped, so this is the actual lifetime boundary a live recording needs -- see
// that file's own comment on this property and `FORK-PATCHES.md`'s "onboarding-reset" entry for
// the full reasoning and the enumeration of every root-view swap this was checked against.

import Combine
import Foundation
import SwiftData

@MainActor
final class MeetingRecordingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping
    }

    @Published private(set) var phase: Phase = .idle
    @Published var lastErrorMessage: String?

    // Configured once, right after creation, via `configure(modelContainer:)` rather than
    // taken as an init parameter -- kept that way even now that the call site is
    // `VoiceInkApp.init()` (which resolves its `ModelContainer` synchronously and could pass it
    // straight to a real init parameter) so this type's own public surface doesn't change
    // depending on which caller currently owns it. See `VoiceInk.swift`'s `init()`.
    private var modelContainer: ModelContainer?
    private var engine: MeetingEngine?

    /// Single-flight guard (`MeetingQuitRace.swift`, PR #15 review round 4, B1) so a SECOND
    /// caller that wants a meeting stopped (`AppDelegate.applicationShouldTerminate(_:)`
    /// finding `phase == .stopping`) gets the SAME task back via `stopTask()`, rather than
    /// starting a second one. Two concurrent calls into `engine.stop()` for one meeting would
    /// be a worse bug than the one this fixes -- see `stopTask()`'s own doc comment.
    private let stopSingleFlight = SingleFlightTask<Bool>()

    var isBusy: Bool {
        phase == .starting || phase == .stopping
    }

    func configure(modelContainer: ModelContainer) {
        guard self.modelContainer == nil else { return }
        self.modelContainer = modelContainer
    }

    func startMeeting(title: String) {
        guard phase == .idle, let modelContainer else { return }
        lastErrorMessage = nil
        phase = .starting

        let persistence = MeetingStore(modelContainer: modelContainer)
        let engine = MeetingEngine(
            title: title,
            persistence: persistence,
            transcriptionCoordinator: NullMeetingTranscriptionCoordinator(),
            retainRecording: false
        )
        self.engine = engine

        Task {
            do {
                try await engine.start()
                phase = .recording
            } catch {
                lastErrorMessage = error.localizedDescription
                self.engine = nil
                phase = .idle
            }
        }
    }

    func stopMeeting() {
        _ = stopTask()
    }

    /// Returns the currently in-flight stop `Task`, starting one only if none is already
    /// running (`stopSingleFlight`, above). Every caller that wants a meeting stopped -- the
    /// UI's Stop button (`stopMeeting()`, above) and `AppDelegate.applicationShouldTerminate(_:)`
    /// (which must cover BOTH `phase == .recording`, where nothing has started stopping yet,
    /// and `phase == .stopping`, where the user already pressed Stop and quit before it
    /// finished -- PR #15 review round 4, B1) -- goes through this single entry point. A
    /// caller that arrives after `phase` is already `.stopping` gets the SAME task back instead
    /// of creating a new one, so awaiting its `.value` waits for the REAL, already-in-progress
    /// finalize rather than a second, independent call into `engine.stop()` -- which would
    /// itself be a data race on `MeetingEngine`'s internal teardown state, a worse bug than the
    /// stranded row or lost finalize this whole fix exists to prevent.
    @discardableResult
    func stopTask() -> Task<Bool, Never> {
        stopSingleFlight.run { [weak self] in
            await self?.stopMeetingAndWait() ?? false
        }
    }

    /// The actual stop logic. Not called directly by any external caller any more (PR #15
    /// review round 4) -- `stopTask()` above is the shared entry point; this stays `internal`
    /// (not `private`) only because `MeetingQuitRaceTests`-style unit tests exercise it
    /// directly for its own guard behavior, matching this file's existing test-visibility
    /// convention.
    @discardableResult
    func stopMeetingAndWait() async -> Bool {
        guard let engine, phase == .recording else { return false }
        phase = .stopping

        do {
            let result = try await engine.stop()
            // `persistenceFailures` exists BECAUSE an earlier review round found meetings
            // could be lost silently (see `MeetingEngineResult`'s own doc comment) -- a
            // non-empty array here can mean the terminal `persistence.finish` write itself
            // failed, which leaves the row stuck `.recording`/`.paused` forever even though
            // this call just returned successfully. Surfacing it, not discarding it with
            // `_ =`, is the whole point of the field existing.
            if !result.persistenceFailures.isEmpty {
                lastErrorMessage = Self.persistenceFailureMessage(count: result.persistenceFailures.count)
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        self.engine = nil
        phase = .idle
        return true
    }

    private static func persistenceFailureMessage(count: Int) -> String {
        let plural = count == 1 ? "an update" : "\(count) updates"
        return "Meeting stopped, but \(plural) failed to save. It may be incomplete or still " +
            "show as Recording in the list -- check it there."
    }
}

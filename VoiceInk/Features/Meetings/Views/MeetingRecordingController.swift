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
// Owned by `ContentView` (`@StateObject`), not by `MeetingsView` -- see that file's
// `meetingRecordingController` comment for why: `MeetingsView` is destroyed and recreated by
// `ContentView`'s navigation switch every time the sidebar selection leaves and returns to
// `.meetings`, and this controller (and the `MeetingEngine` it drives) must outlive that so a
// recording in progress survives the user clicking around the sidebar.

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

    // `ModelContainer` is not available at `init` time from a SwiftUI view's `@StateObject`
    // (the environment that carries it, `\.modelContext`, is only readable from a view's body/
    // lifecycle callbacks, not its init) — so this is configured once, right after creation,
    // via `configure(modelContainer:)` rather than taken as an init parameter. See
    // `ContentView.onAppear`.
    private var modelContainer: ModelContainer?
    private var engine: MeetingEngine?

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
        guard let engine, phase == .recording else { return }
        phase = .stopping

        Task {
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
        }
    }

    private static func persistenceFailureMessage(count: Int) -> String {
        let plural = count == 1 ? "an update" : "\(count) updates"
        return "Meeting stopped, but \(plural) failed to save. It may be incomplete or still " +
            "show as Recording in the list -- check it there."
    }
}

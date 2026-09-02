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
// that. `false` here is that same reasoning applied at this call site, not a new decision: it
// is the conservative choice until a real settings surface exists, made explicit rather than
// left for a future caller to get wrong. Real transcription (Stage 2c) is not built yet, so
// every meeting recorded through this controller persists with real audio capture and mic/
// system chunk rotation, but an empty transcript — see `MeetingsView`'s empty-transcript
// messaging, which states this plainly rather than pretending nothing was recorded.

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
    // `MeetingsView.onAppear`.
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
                _ = try await engine.stop()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            self.engine = nil
            phase = .idle
        }
    }
}

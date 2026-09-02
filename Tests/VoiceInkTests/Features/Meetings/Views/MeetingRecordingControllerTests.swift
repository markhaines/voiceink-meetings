// Deliberately narrow: `MeetingRecordingController.startMeeting`/`stopMeeting` drive a real
// `MeetingEngine` against real mic/system-audio recorders (see that type's own header for why
// -- it is the UI's one real caller of the engine, wired with no fakes so the app it ships in
// behaves the same way this test would exercise). Actually starting a meeting therefore touches
// CoreAudio and needs microphone/audio-capture TCC consent, neither of which a CI runner has
// (see `.github/workflows/ci.yml`'s note on why `VoiceInkUITests` is skipped there for the same
// reason). What this file verifies instead is the controller's own guard logic, which needs
// none of that: the two states in which it must do nothing rather than crash or misbehave.

import SwiftData
import Testing

@testable import VoiceInk

@Suite("MeetingRecordingController")
@MainActor
struct MeetingRecordingControllerTests {
    @Test("starting before configure() is a no-op")
    func startBeforeConfigureIsNoOp() {
        let controller = MeetingRecordingController()

        controller.startMeeting(title: "Unconfigured")

        #expect(controller.phase == .idle)
        #expect(controller.lastErrorMessage == nil)
    }

    @Test("stopping while idle is a no-op")
    func stopWhileIdleIsNoOp() throws {
        let schema = Schema([Meeting.self, MeetingSegment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)

        let controller = MeetingRecordingController()
        controller.configure(modelContainer: container)

        controller.stopMeeting()

        #expect(controller.phase == .idle)
        #expect(controller.lastErrorMessage == nil)
    }

    @Test("configure() is one-shot: a later call cannot swap the container")
    func configureIsOneShot() throws {
        let schema = Schema([Meeting.self, MeetingSegment.self])
        let firstConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let secondConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let first = try ModelContainer(for: schema, configurations: firstConfig)
        let second = try ModelContainer(for: schema, configurations: secondConfig)

        let controller = MeetingRecordingController()
        controller.configure(modelContainer: first)
        controller.configure(modelContainer: second)

        // No public accessor for the stored container -- this only proves the second call
        // didn't crash or change observable state, which is the whole surface `configure`
        // exposes.
        #expect(controller.phase == .idle)
    }
}

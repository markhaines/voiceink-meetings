// Functional tests for the incremental persistence contract `MeetingSegmentPersistenceActor`
// defines for the not-yet-written MeetingEngine. Runs entirely against an in-memory SwiftData
// `ModelContainer` — no CoreAudio, no `AVAudioEngine`, no real devices.
//
// These tests exercise the actor's PUBLIC API only (`PersistentIdentifier` in, identifier
// out) — never a managed `Meeting`/`MeetingSegment` object crosses an `await` boundary here,
// which is itself part of what's being tested: if the actor's API let a managed object leak
// across, these calls would not compile without extra ceremony. See
// `MeetingSegmentPersistenceActorDurabilityTests.swift` for the real "crash mid-meeting, data
// survives on disk" guarantee, which this file does not attempt to test.

import Foundation
import SwiftData
import Testing

@testable import VoiceInk

@Suite("MeetingSegmentPersistenceActor")
struct MeetingSegmentPersistenceActorTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, MeetingSegment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func fetchMeeting(id: PersistentIdentifier, from container: ModelContainer) throws -> Meeting? {
        let readContext = ModelContext(container)
        return readContext.model(for: id) as? Meeting
    }

    @Test("startMeeting persists immediately, before any segment exists")
    func startMeetingPersistsImmediately() async throws {
        let container = try makeContainer()
        let actor = MeetingSegmentPersistenceActor(modelContainer: container)

        let meetingID = try await actor.startMeeting(title: "Design Review", audioDirectoryPath: "/tmp/m1")

        let reread = try fetchMeeting(id: meetingID, from: container)
        #expect(reread != nil)
        #expect(reread?.state == .recording)
        #expect(reread?.segments.isEmpty == true)
    }

    @Test("each appendSegment call is independently durable")
    func appendSegmentIsDurablePerCall() async throws {
        let container = try makeContainer()
        let actor = MeetingSegmentPersistenceActor(modelContainer: container)

        let meetingID = try await actor.startMeeting(title: "1:1", audioDirectoryPath: "/tmp/m2")

        try await actor.appendSegment(
            startOffset: 0, endOffset: 3, speakerLabel: "You", text: "Hi there",
            sourceChannel: .mic, to: meetingID
        )
        // Simulate "the process died here" by reading through an entirely separate context
        // before the second segment is ever appended.
        var reread = try fetchMeeting(id: meetingID, from: container)
        #expect(reread?.segments.count == 1)
        #expect(reread?.segments.first?.text == "Hi there")

        try await actor.appendSegment(
            startOffset: 3, endOffset: 6, speakerLabel: "Others", text: "Hello",
            sourceChannel: .system, to: meetingID
        )
        reread = try fetchMeeting(id: meetingID, from: container)
        #expect(reread?.segments.count == 2)
    }

    @Test("appendSegment assigns increasing orderIndex values")
    func appendSegmentAssignsOrderIndex() async throws {
        let container = try makeContainer()
        let actor = MeetingSegmentPersistenceActor(modelContainer: container)
        let meetingID = try await actor.startMeeting(title: "Standup", audioDirectoryPath: "/tmp/m3")

        let firstID = try await actor.appendSegment(
            startOffset: 0, endOffset: 1, speakerLabel: "You", text: "a",
            sourceChannel: .mic, to: meetingID
        )
        let secondID = try await actor.appendSegment(
            startOffset: 1, endOffset: 2, speakerLabel: "You", text: "b",
            sourceChannel: .mic, to: meetingID
        )

        let readContext = ModelContext(container)
        let first = try #require(readContext.model(for: firstID) as? MeetingSegment)
        let second = try #require(readContext.model(for: secondID) as? MeetingSegment)
        #expect(first.orderIndex == 0)
        #expect(second.orderIndex == 1)
    }

    @Test("updateDuration persists without requiring finish")
    func updateDurationPersists() async throws {
        let container = try makeContainer()
        let actor = MeetingSegmentPersistenceActor(modelContainer: container)
        let meetingID = try await actor.startMeeting(title: "Long meeting", audioDirectoryPath: "/tmp/m4")

        try await actor.updateDuration(4200, for: meetingID)

        let reread = try fetchMeeting(id: meetingID, from: container)
        #expect(reread?.duration == 4200)
        #expect(reread?.state == .recording)
    }

    @Test("updateState persists a pause independently of finish")
    func updateStatePersistsPause() async throws {
        let container = try makeContainer()
        let actor = MeetingSegmentPersistenceActor(modelContainer: container)
        let meetingID = try await actor.startMeeting(title: "Interrupted", audioDirectoryPath: "/tmp/m5")

        try await actor.updateState(.paused, for: meetingID)

        let reread = try fetchMeeting(id: meetingID, from: container)
        #expect(reread?.state == .paused)
        #expect(reread?.endDate == nil)
    }

    @Test("finish sets endDate, recomputes duration exactly, and completes the meeting")
    func finishCompletesMeeting() async throws {
        let container = try makeContainer()
        let actor = MeetingSegmentPersistenceActor(modelContainer: container)
        let start = Date(timeIntervalSince1970: 1_000)
        let meetingID = try await actor.startMeeting(
            title: "Wrap-up", audioDirectoryPath: "/tmp/m6", startDate: start
        )

        let end = start.addingTimeInterval(1_800)
        try await actor.finish(meetingID, endDate: end)

        let reread = try fetchMeeting(id: meetingID, from: container)
        #expect(reread?.state == .completed)
        #expect(reread?.endDate == end)
        #expect(reread?.duration == 1_800)
    }

    @Test("markFailed persists a failed meeting without touching its segments")
    func markFailedPreservesSegments() async throws {
        let container = try makeContainer()
        let actor = MeetingSegmentPersistenceActor(modelContainer: container)
        let meetingID = try await actor.startMeeting(title: "Dropped call", audioDirectoryPath: "/tmp/m7")
        try await actor.appendSegment(
            startOffset: 0, endOffset: 2, speakerLabel: "You", text: "can you hear",
            sourceChannel: .mic, to: meetingID
        )

        try await actor.markFailed(meetingID)

        let reread = try fetchMeeting(id: meetingID, from: container)
        #expect(reread?.state == .failed)
        #expect(reread?.segments.count == 1)
    }

    @Test("an identifier from a different store throws meetingNotFound rather than crashing")
    func unknownIdentifierThrows() async throws {
        let otherContainer = try makeContainer()
        let otherActor = MeetingSegmentPersistenceActor(modelContainer: otherContainer)
        let foreignID = try await otherActor.startMeeting(title: "Elsewhere", audioDirectoryPath: "/tmp/elsewhere")

        let container = try makeContainer()
        let actor = MeetingSegmentPersistenceActor(modelContainer: container)

        await #expect(throws: MeetingSegmentPersistenceActor.PersistenceError.self) {
            try await actor.updateDuration(10, for: foreignID)
        }
    }
}

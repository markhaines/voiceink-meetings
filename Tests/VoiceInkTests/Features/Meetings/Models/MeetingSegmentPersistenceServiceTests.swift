// Tests for the incremental persistence contract `MeetingSegmentPersistenceService` defines
// for the not-yet-written MeetingEngine. Runs entirely against an in-memory SwiftData
// `ModelContainer` — no CoreAudio, no `AVAudioEngine`, no real devices.
//
// The "a crash at minute 70 loses nothing" guarantee is exercised by opening a SECOND,
// independent `ModelContext` on the same container after each write and fetching through it —
// that only observes what has actually reached the store, not what merely lives in the
// writer's in-memory object graph, so it stands in for "the process died and something else
// reads the store next."

import Foundation
import SwiftData
import Testing

@testable import VoiceInk

@Suite("MeetingSegmentPersistenceService")
struct MeetingSegmentPersistenceServiceTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, MeetingSegment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func fetchMeeting(id: UUID, from container: ModelContainer) throws -> Meeting? {
        let readContext = ModelContext(container)
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })
        return try readContext.fetch(descriptor).first
    }

    @Test("startMeeting persists immediately, before any segment exists")
    func startMeetingPersistsImmediately() throws {
        let container = try makeContainer()
        let service = MeetingSegmentPersistenceService(context: ModelContext(container))

        let meeting = try service.startMeeting(title: "Design Review", audioDirectoryPath: "/tmp/m1")

        let reread = try fetchMeeting(id: meeting.id, from: container)
        #expect(reread != nil)
        #expect(reread?.state == .recording)
        #expect(reread?.segments.isEmpty == true)
    }

    @Test("each appendSegment call is independently durable")
    func appendSegmentIsDurablePerCall() throws {
        let container = try makeContainer()
        let writeContext = ModelContext(container)
        let service = MeetingSegmentPersistenceService(context: writeContext)

        let meeting = try service.startMeeting(title: "1:1", audioDirectoryPath: "/tmp/m2")

        try service.appendSegment(
            startOffset: 0, endOffset: 3, speakerLabel: "You", text: "Hi there",
            sourceChannel: .mic, to: meeting
        )
        // Simulate "the process died here" by reading through an entirely separate context
        // before the second segment is ever appended.
        var reread = try fetchMeeting(id: meeting.id, from: container)
        #expect(reread?.segments.count == 1)
        #expect(reread?.segments.first?.text == "Hi there")

        try service.appendSegment(
            startOffset: 3, endOffset: 6, speakerLabel: "Others", text: "Hello",
            sourceChannel: .system, to: meeting
        )
        reread = try fetchMeeting(id: meeting.id, from: container)
        #expect(reread?.segments.count == 2)
    }

    @Test("appendSegment assigns increasing orderIndex values")
    func appendSegmentAssignsOrderIndex() throws {
        let container = try makeContainer()
        let service = MeetingSegmentPersistenceService(context: ModelContext(container))
        let meeting = try service.startMeeting(title: "Standup", audioDirectoryPath: "/tmp/m3")

        let first = try service.appendSegment(
            startOffset: 0, endOffset: 1, speakerLabel: "You", text: "a",
            sourceChannel: .mic, to: meeting
        )
        let second = try service.appendSegment(
            startOffset: 1, endOffset: 2, speakerLabel: "You", text: "b",
            sourceChannel: .mic, to: meeting
        )

        #expect(first.orderIndex == 0)
        #expect(second.orderIndex == 1)
    }

    @Test("updateDuration persists without requiring finish")
    func updateDurationPersists() throws {
        let container = try makeContainer()
        let service = MeetingSegmentPersistenceService(context: ModelContext(container))
        let meeting = try service.startMeeting(title: "Long meeting", audioDirectoryPath: "/tmp/m4")

        try service.updateDuration(4200, for: meeting)

        let reread = try fetchMeeting(id: meeting.id, from: container)
        #expect(reread?.duration == 4200)
        #expect(reread?.state == .recording)
    }

    @Test("updateState persists a pause independently of finish")
    func updateStatePersistsPause() throws {
        let container = try makeContainer()
        let service = MeetingSegmentPersistenceService(context: ModelContext(container))
        let meeting = try service.startMeeting(title: "Interrupted", audioDirectoryPath: "/tmp/m5")

        try service.updateState(.paused, for: meeting)

        let reread = try fetchMeeting(id: meeting.id, from: container)
        #expect(reread?.state == .paused)
        #expect(reread?.endDate == nil)
    }

    @Test("finish sets endDate, recomputes duration exactly, and completes the meeting")
    func finishCompletesMeeting() throws {
        let container = try makeContainer()
        let service = MeetingSegmentPersistenceService(context: ModelContext(container))
        let start = Date(timeIntervalSince1970: 1_000)
        let meeting = try service.startMeeting(
            title: "Wrap-up", audioDirectoryPath: "/tmp/m6", startDate: start
        )

        let end = start.addingTimeInterval(1_800)
        try service.finish(meeting, endDate: end)

        let reread = try fetchMeeting(id: meeting.id, from: container)
        #expect(reread?.state == .completed)
        #expect(reread?.endDate == end)
        #expect(reread?.duration == 1_800)
    }

    @Test("markFailed persists a failed meeting without touching its segments")
    func markFailedPreservesSegments() throws {
        let container = try makeContainer()
        let service = MeetingSegmentPersistenceService(context: ModelContext(container))
        let meeting = try service.startMeeting(title: "Dropped call", audioDirectoryPath: "/tmp/m7")
        try service.appendSegment(
            startOffset: 0, endOffset: 2, speakerLabel: "You", text: "can you hear",
            sourceChannel: .mic, to: meeting
        )

        try service.markFailed(meeting)

        let reread = try fetchMeeting(id: meeting.id, from: container)
        #expect(reread?.state == .failed)
        #expect(reread?.segments.count == 1)
    }
}

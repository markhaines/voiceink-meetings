// Functional tests for the incremental persistence contract `MeetingStore` defines for the
// not-yet-written MeetingEngine. Runs entirely against an in-memory SwiftData
// `ModelContainer` — no CoreAudio, no `AVAudioEngine`, no real devices.
//
// These tests exercise the store's PUBLIC API only. Two things about how they are written are
// deliberate, not incidental:
//
// 1. **They never unwrap a `MeetingHandle`.** They cannot: the `PersistentIdentifier` inside is
//    `fileprivate` to `MeetingStore.swift`, so a test can no more reach it than production code
//    can. Reads back out of the store are therefore done by FETCHING from a separate
//    `ModelContext`, which is also the only honest way to ask "did this reach the store".
// 2. **No `ModelContext.model(for:)` anywhere.** It is not the Optional-returning "not found"
//    check it looks like: for an identifier the receiving context does not recognise it
//    fatal-errors the whole process rather than returning nil. Every lookup below is a
//    `FetchDescriptor`. See `MeetingStore.meeting(for:)` and `FORK-PATCHES.md`.
//
// See `MeetingStoreDurabilityTests.swift` for the real "crash mid-meeting, data survives on
// disk" guarantee, and `MeetingStoreIsolationTests.swift` for the runtime half of the
// isolation proof.

import Foundation
import SwiftData
import Testing

@testable import VoiceInk

@Suite("MeetingStore")
struct MeetingStoreTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, MeetingSegment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    /// Reads back through a context this test owns, never through the store's own. Each test
    /// gets its own container holding at most one meeting, so "the only meeting" is unambiguous.
    private func fetchOnlyMeeting(from container: ModelContainer) throws -> Meeting? {
        try ModelContext(container).fetch(FetchDescriptor<Meeting>()).first
    }

    private func fetchSegmentsInOrder(from container: ModelContainer) throws -> [MeetingSegment] {
        var descriptor = FetchDescriptor<MeetingSegment>()
        descriptor.sortBy = [SortDescriptor(\.startOffset), SortDescriptor(\.orderIndex)]
        return try ModelContext(container).fetch(descriptor)
    }

    @Test("startMeeting persists immediately, before any segment exists")
    func startMeetingPersistsImmediately() async throws {
        let container = try makeContainer()
        let store = MeetingStore(modelContainer: container)

        try await store.startMeeting(title: "Design Review", audioDirectoryPath: "/tmp/m1")

        let reread = try #require(try fetchOnlyMeeting(from: container))
        #expect(reread.title == "Design Review")
        #expect(reread.state == .recording)
        #expect(reread.segments.isEmpty)
    }

    @Test("each appendSegment call is independently durable")
    func appendSegmentIsDurablePerCall() async throws {
        let container = try makeContainer()
        let store = MeetingStore(modelContainer: container)

        let meeting = try await store.startMeeting(title: "1:1", audioDirectoryPath: "/tmp/m2")

        try await store.appendSegment(
            startOffset: 0, endOffset: 3, speakerLabel: "You", text: "Hi there",
            sourceChannel: .mic, to: meeting
        )
        // Simulate "the process died here" by reading through an entirely separate context
        // before the second segment is ever appended.
        var reread = try #require(try fetchOnlyMeeting(from: container))
        #expect(reread.segments.count == 1)
        #expect(reread.segments.first?.text == "Hi there")

        try await store.appendSegment(
            startOffset: 3, endOffset: 6, speakerLabel: "Others", text: "Hello",
            sourceChannel: .system, to: meeting
        )
        reread = try #require(try fetchOnlyMeeting(from: container))
        #expect(reread.segments.count == 2)
    }

    @Test("appendSegment assigns increasing orderIndex values")
    func appendSegmentAssignsOrderIndex() async throws {
        let container = try makeContainer()
        let store = MeetingStore(modelContainer: container)
        let meeting = try await store.startMeeting(title: "Standup", audioDirectoryPath: "/tmp/m3")

        try await store.appendSegment(
            startOffset: 0, endOffset: 1, speakerLabel: "You", text: "a",
            sourceChannel: .mic, to: meeting
        )
        try await store.appendSegment(
            startOffset: 1, endOffset: 2, speakerLabel: "You", text: "b",
            sourceChannel: .mic, to: meeting
        )

        let segments = try fetchSegmentsInOrder(from: container)
        #expect(segments.map(\.text) == ["a", "b"])
        #expect(segments.map(\.orderIndex) == [0, 1])
    }

    @Test("updateDuration persists without requiring finish")
    func updateDurationPersists() async throws {
        let container = try makeContainer()
        let store = MeetingStore(modelContainer: container)
        let meeting = try await store.startMeeting(title: "Long meeting", audioDirectoryPath: "/tmp/m4")

        try await store.updateDuration(4200, for: meeting)

        let reread = try #require(try fetchOnlyMeeting(from: container))
        #expect(reread.duration == 4200)
        #expect(reread.state == .recording)
    }

    @Test("updateState persists a pause independently of finish")
    func updateStatePersistsPause() async throws {
        let container = try makeContainer()
        let store = MeetingStore(modelContainer: container)
        let meeting = try await store.startMeeting(title: "Interrupted", audioDirectoryPath: "/tmp/m5")

        try await store.updateState(.paused, for: meeting)

        let reread = try #require(try fetchOnlyMeeting(from: container))
        #expect(reread.state == .paused)
        #expect(reread.endDate == nil)
    }

    @Test("finish sets endDate, recomputes duration exactly, and completes the meeting")
    func finishCompletesMeeting() async throws {
        let container = try makeContainer()
        let store = MeetingStore(modelContainer: container)
        let start = Date(timeIntervalSince1970: 1_000)
        let meeting = try await store.startMeeting(
            title: "Wrap-up", audioDirectoryPath: "/tmp/m6", startDate: start
        )

        let end = start.addingTimeInterval(1_800)
        try await store.finish(meeting, endDate: end)

        let reread = try #require(try fetchOnlyMeeting(from: container))
        #expect(reread.state == .completed)
        #expect(reread.endDate == end)
        #expect(reread.duration == 1_800)
    }

    @Test("markFailed persists a failed meeting without touching its segments")
    func markFailedPreservesSegments() async throws {
        let container = try makeContainer()
        let store = MeetingStore(modelContainer: container)
        let meeting = try await store.startMeeting(title: "Dropped call", audioDirectoryPath: "/tmp/m7")
        try await store.appendSegment(
            startOffset: 0, endOffset: 2, speakerLabel: "You", text: "can you hear",
            sourceChannel: .mic, to: meeting
        )

        try await store.markFailed(meeting)

        let reread = try #require(try fetchOnlyMeeting(from: container))
        #expect(reread.state == .failed)
        #expect(reread.segments.count == 1)
    }

    @Test("a handle from a different store throws meetingNotFound rather than crashing")
    func foreignHandleThrows() async throws {
        // Exercises `MeetingStore.meeting(for:)`'s registeredModel-then-fetch lookup against a
        // genuinely foreign `PersistentIdentifier`. Both of SwiftData's own lookup APIs crash
        // the process on this input rather than returning nil — `ModelContext.model(for:)`
        // immediately, and `ModelActor`'s `self[id, as:]` subscript on the next mutation. This
        // test is what caught both. See `MeetingStore.meeting(for:)`.
        let otherContainer = try makeContainer()
        let otherStore = MeetingStore(modelContainer: otherContainer)
        let foreignHandle = try await otherStore.startMeeting(
            title: "Elsewhere", audioDirectoryPath: "/tmp/elsewhere"
        )

        let container = try makeContainer()
        let store = MeetingStore(modelContainer: container)

        await #expect(throws: MeetingStoreError.self) {
            try await store.updateDuration(10, for: foreignHandle)
        }
    }
}

// Model-layer tests for `Meeting`/`MeetingSegment`. Runs entirely against an in-memory
// SwiftData `ModelContainer` — no CoreAudio, no `AVAudioEngine`, no real devices — so it needs
// none of the `TEST_RUNNER_VOICEINK_CI` skip gating `AudioGraphExceptionBridgeTests.swift` uses
// for tests that touch real audio hardware.

import Foundation
import SwiftData
import Testing

@testable import VoiceInk

@Suite("Meeting model")
struct MeetingModelTests {
    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([Meeting.self, MeetingSegment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    @Test("defaults to .recording state and empty segments")
    func newMeetingDefaults() throws {
        let context = try makeInMemoryContext()
        let meeting = Meeting(title: "Standup", audioDirectoryPath: "/tmp/meeting-1")
        context.insert(meeting)
        try context.save()

        #expect(meeting.state == .recording)
        #expect(meeting.segments.isEmpty)
        #expect(meeting.endDate == nil)
        #expect(meeting.actionItems.isEmpty)
        #expect(meeting.summary == nil)
    }

    @Test("state round-trips through its raw-string backing column")
    func stateRoundTrips() throws {
        let context = try makeInMemoryContext()
        let meeting = Meeting(title: "1:1", audioDirectoryPath: "/tmp/meeting-2")
        context.insert(meeting)

        for state: MeetingState in [.recording, .paused, .finalizing, .completed, .failed] {
            meeting.state = state
            try context.save()
            #expect(meeting.state == state)
        }
    }

    @Test("appending a segment establishes the inverse relationship")
    func segmentInverseRelationship() throws {
        let context = try makeInMemoryContext()
        let meeting = Meeting(title: "Planning", audioDirectoryPath: "/tmp/meeting-3")
        context.insert(meeting)

        let segment = MeetingSegment(
            startOffset: 0,
            endOffset: 2.5,
            speakerLabel: "You",
            text: "Let's get started",
            sourceChannel: .mic,
            orderIndex: 0,
            meeting: meeting
        )
        context.insert(segment)
        try context.save()

        #expect(meeting.segments.count == 1)
        #expect(meeting.segments.first?.text == "Let's get started")
        #expect(segment.meeting === meeting)
    }

    @Test("deleting a meeting cascades to its segments")
    func cascadeDeleteRemovesSegments() throws {
        let context = try makeInMemoryContext()
        let meeting = Meeting(title: "Retro", audioDirectoryPath: "/tmp/meeting-4")
        context.insert(meeting)

        for index in 0..<3 {
            let segment = MeetingSegment(
                startOffset: Double(index),
                endOffset: Double(index) + 1,
                speakerLabel: "You",
                text: "Line \(index)",
                sourceChannel: .mic,
                orderIndex: index,
                meeting: meeting
            )
            context.insert(segment)
        }
        try context.save()

        var descriptor = FetchDescriptor<MeetingSegment>()
        descriptor.sortBy = [SortDescriptor(\.orderIndex)]
        #expect(try context.fetch(descriptor).count == 3)

        context.delete(meeting)
        try context.save()

        #expect(try context.fetch(descriptor).isEmpty)
    }

    @Test("sourceChannel round-trips through its raw-string backing column")
    func sourceChannelRoundTrips() throws {
        let context = try makeInMemoryContext()
        let meeting = Meeting(title: "Sync", audioDirectoryPath: "/tmp/meeting-5")
        context.insert(meeting)

        let micSegment = MeetingSegment(
            startOffset: 0, endOffset: 1, speakerLabel: "You", text: "hi",
            sourceChannel: .mic, orderIndex: 0, meeting: meeting
        )
        let systemSegment = MeetingSegment(
            startOffset: 1, endOffset: 2, speakerLabel: "Others", text: "hello back",
            sourceChannel: .system, orderIndex: 1, meeting: meeting
        )
        context.insert(micSegment)
        context.insert(systemSegment)
        try context.save()

        #expect(micSegment.sourceChannel == .mic)
        #expect(systemSegment.sourceChannel == .system)
    }

    @Test("orderIndex breaks ties when startOffset is identical")
    func orderIndexBreaksTies() throws {
        let context = try makeInMemoryContext()
        let meeting = Meeting(title: "Overlap", audioDirectoryPath: "/tmp/meeting-6")
        context.insert(meeting)

        let first = MeetingSegment(
            startOffset: 5, endOffset: 6, speakerLabel: "You", text: "first",
            sourceChannel: .mic, orderIndex: 0, meeting: meeting
        )
        let second = MeetingSegment(
            startOffset: 5, endOffset: 6, speakerLabel: "Others", text: "second",
            sourceChannel: .system, orderIndex: 1, meeting: meeting
        )
        context.insert(second)
        context.insert(first)
        try context.save()

        var descriptor = FetchDescriptor<MeetingSegment>()
        descriptor.sortBy = [SortDescriptor(\.startOffset), SortDescriptor(\.orderIndex)]
        let ordered = try context.fetch(descriptor)

        #expect(ordered.map(\.text) == ["first", "second"])
    }
}

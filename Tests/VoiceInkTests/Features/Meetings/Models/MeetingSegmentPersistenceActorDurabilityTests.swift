// Tests the actual guarantee `MeetingSegmentPersistenceActor` claims — "a crash at minute 70
// of a meeting loses at most the segment in flight" — for real, against a temporary ON-DISK
// SwiftData store, not an in-memory one.
//
// An in-memory `ModelConfiguration` keeps its data alive only as long as the process (and, in
// practice, the one `ModelContainer` instance) that created it is alive; reading through a
// second `ModelContext` on that SAME container (as `MeetingSegmentPersistenceActorTests.swift`
// does) proves object-graph visibility across contexts, not that anything survived a process
// death. This file tears the writing `ModelContainer` down completely — the value goes out of
// scope, nothing keeps its file open in memory — then opens a brand-new `ModelContainer`
// against the same on-disk file and asserts every segment is still there, in order, and still
// attached to its meeting. That is the only thing that would actually catch a regression in
// the "loses nothing" guarantee; the in-memory tests would not.
//
// No CoreAudio, no `AVAudioEngine`, no real audio devices — only a temp-directory SQLite file,
// which CI runners have.

import Foundation
import SwiftData
import Testing

@testable import VoiceInk

@Suite("MeetingSegmentPersistenceActor durability")
struct MeetingSegmentPersistenceActorDurabilityTests {
    private func makeTempStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-meeting-durability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("segments written before a full container teardown are present after reopening the same on-disk store")
    func survivesContainerTeardown() async throws {
        let tempDirectory = try makeTempStoreDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let storeURL = tempDirectory.appendingPathComponent("meetings.store")
        let schema = Schema([Meeting.self, MeetingSegment.self])
        let expectedTexts = (0..<5).map { "minute \($0 * 60) update" }

        let meetingID: PersistentIdentifier
        let meetingIDValue: UUID
        do {
            // Scoped deliberately: `container` and `actor` go fully out of scope at the end of
            // this block, standing in for "the process died here" — nothing from this block
            // survives except what actually reached the on-disk file.
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: config)
            let actor = MeetingSegmentPersistenceActor(modelContainer: container)

            meetingID = try await actor.startMeeting(
                title: "Ninety minute sync", audioDirectoryPath: tempDirectory.path
            )
            // Captured now, via a plain read on the still-live container, because
            // `PersistentIdentifier` itself won't be safe to compare after the container
            // below is torn down and reopened (see the comment at the bottom of this test).
            // `Meeting.id` is this app's own stored UUID, unrelated to SwiftData's internal
            // identity, so it round-trips fine.
            meetingIDValue = try #require(ModelContext(container).fetch(FetchDescriptor<Meeting>()).first).id
            for index in 0..<5 {
                try await actor.appendSegment(
                    startOffset: Double(index) * 60,
                    endOffset: Double(index) * 60 + 30,
                    speakerLabel: index.isMultiple(of: 2) ? "You" : "Others",
                    text: expectedTexts[index],
                    sourceChannel: index.isMultiple(of: 2) ? .mic : .system,
                    to: meetingID
                )
            }
            // No `finish` call — the meeting is left `.recording`, exactly as a real crash
            // mid-meeting would leave it.
        }

        // A genuinely new container, opened fresh against the same file. Nothing here shares
        // any in-memory state with the block above.
        //
        // Deliberately NOT `readContext.model(for: meetingID)`: that call looks like a safe,
        // Optional-returning lookup but isn't — it FATAL-ERRORS the whole process if the
        // context it's called on hasn't already got the object registered (exactly the case
        // for a context that has never fetched anything yet), rather than returning a fault
        // it resolves lazily. A `FetchDescriptor` is a real round trip to the on-disk store,
        // which is also the more honest way to ask "is this actually durable on disk" in the
        // first place. See `MeetingSegmentPersistenceActor.meeting(for:)` for the same
        // reasoning applied to the actor's own lookups, and `FORK-PATCHES.md`'s Stage 2a
        // fix-round entry for the crash this produced before the test was written this way.
        let reopenedConfig = ModelConfiguration(schema: schema, url: storeURL)
        let reopenedContainer = try ModelContainer(for: schema, configurations: reopenedConfig)
        let readContext = ModelContext(reopenedContainer)

        let allMeetings = try readContext.fetch(FetchDescriptor<Meeting>())
        let reread = try #require(allMeetings.first)

        // NOT `reread.persistentModelID == meetingID`: Apple documents `PersistentIdentifier`
        // as valid only for the lifetime of the `ModelContainer` that produced it, not across
        // a relaunch/reopen — and this is not a theoretical caveat, it was proven empirically
        // here. Before this comment existed, this exact assertion FAILED against this exact
        // reopened store: same store UUID, same entity, same primary key in the debug
        // description, `==` still `false`. See `FORK-PATCHES.md`'s Stage 2a fix-round entry
        // for the verbatim mismatched values and what it implies for a future crash-recovery
        // feature (it must re-find a meeting by content/`Meeting.id`, never by a saved
        // `PersistentIdentifier`, across a relaunch).
        #expect(allMeetings.count == 1)
        #expect(reread.id == meetingIDValue)
        #expect(reread.title == "Ninety minute sync")
        #expect(reread.state == .recording)
        #expect(reread.endDate == nil)
        #expect(reread.segments.count == 5)

        let ordered = reread.segments.sorted { lhs, rhs in
            lhs.startOffset != rhs.startOffset ? lhs.startOffset < rhs.startOffset : lhs.orderIndex < rhs.orderIndex
        }
        #expect(ordered.map(\.text) == expectedTexts)
        // Reference equality, not identifier equality — but valid here precisely because
        // both sides were fetched into the SAME `readContext`, where a relationship fault
        // resolves to the one object that context has for that row.
        #expect(ordered.allSatisfy { $0.meeting === reread })
    }

    @Test("updateDuration and finish written before teardown both survive reopening the store")
    func finishSurvivesContainerTeardown() async throws {
        let tempDirectory = try makeTempStoreDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let storeURL = tempDirectory.appendingPathComponent("meetings.store")
        let schema = Schema([Meeting.self, MeetingSegment.self])
        let start = Date(timeIntervalSince1970: 2_000)
        let end = start.addingTimeInterval(900)

        let meetingID: PersistentIdentifier
        let meetingIDValue: UUID
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: config)
            let actor = MeetingSegmentPersistenceActor(modelContainer: container)

            meetingID = try await actor.startMeeting(
                title: "Clean finish", audioDirectoryPath: tempDirectory.path, startDate: start
            )
            meetingIDValue = try #require(ModelContext(container).fetch(FetchDescriptor<Meeting>()).first).id
            try await actor.updateDuration(600, for: meetingID)
            try await actor.finish(meetingID, endDate: end)
        }

        let reopenedConfig = ModelConfiguration(schema: schema, url: storeURL)
        let reopenedContainer = try ModelContainer(for: schema, configurations: reopenedConfig)
        let readContext = ModelContext(reopenedContainer)

        // See the sibling test above for why this reads via `fetch(FetchDescriptor<Meeting>())`
        // and compares `Meeting.id`, not `readContext.model(for: meetingID)` /
        // `persistentModelID` equality.
        let reread = try #require(readContext.fetch(FetchDescriptor<Meeting>()).first)
        #expect(reread.id == meetingIDValue)
        #expect(reread.state == .completed)
        #expect(reread.endDate == end)
        #expect(reread.duration == 900)
    }
}

// Tests the actual guarantee `MeetingStore` claims — "a crash at minute 70 of a meeting loses
// at most the segment in flight" — for real, against a temporary ON-DISK SwiftData store, not
// an in-memory one.
//
// An in-memory `ModelConfiguration` keeps its data alive only as long as the process (and, in
// practice, the one `ModelContainer` instance) that created it is alive; reading through a
// second `ModelContext` on that SAME container (as `MeetingStoreTests.swift` does) proves
// object-graph visibility across contexts, not that anything survived a process death. This
// file tears the writing `ModelContainer` down completely — the value goes out of scope,
// nothing keeps its file open in memory — then opens a brand-new `ModelContainer` against the
// same on-disk file and asserts every segment is still there, in order, and still attached to
// its meeting. That is the only thing that would actually catch a regression in the "loses
// nothing" guarantee; the in-memory tests would not.
//
// # Why this file genuinely pins the explicit-save contract
//
// It only does so because `MeetingStore` turns autosave OFF on its context (see
// `MeetingPersistenceEngine.init`). With SwiftData's autosave left on, this file would keep
// passing after every `try modelContext.save()` in the store was deleted — the framework would
// flush the pending changes on its own during teardown and the assertions below would still
// find the data. That was the state of this test before; it asserted durability that the store
// was not actually responsible for. Proven by deleting the `save()` from `appendSegment` and
// re-running: with autosave off the test fails on the segment count, so a future edit that
// drops a save cannot pass CI. The verbatim failure is quoted in `FORK-PATCHES.md`.
//
// No CoreAudio, no `AVAudioEngine`, no real audio devices — only a temp-directory SQLite file,
// which CI runners have.

import Foundation
import SwiftData
import Testing

@testable import VoiceInk

@Suite("MeetingStore durability")
struct MeetingStoreDurabilityTests {
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

        let meetingIDValue: UUID
        do {
            // Scoped deliberately: `container` and `store` go fully out of scope at the end of
            // this block, standing in for "the process died here" — nothing from this block
            // survives except what actually reached the on-disk file.
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: config)
            let store = MeetingStore(modelContainer: container)

            let meeting = try await store.startMeeting(
                title: "Ninety minute sync", audioDirectoryPath: tempDirectory.path
            )
            // Captured now, via a plain read on the still-live container, because a
            // `MeetingHandle` wraps a `PersistentIdentifier`, which won't be comparable after
            // the container below is torn down and reopened (see the comment at the bottom of
            // this test). `Meeting.id` is this app's own stored UUID, unrelated to SwiftData's
            // internal identity, so it round-trips fine.
            meetingIDValue = try #require(ModelContext(container).fetch(FetchDescriptor<Meeting>()).first).id
            for index in 0..<5 {
                try await store.appendSegment(
                    startOffset: Double(index) * 60,
                    endOffset: Double(index) * 60 + 30,
                    speakerLabel: index.isMultiple(of: 2) ? "You" : "Others",
                    text: expectedTexts[index],
                    sourceChannel: index.isMultiple(of: 2) ? .mic : .system,
                    to: meeting
                )
            }
            // No `finish` call — the meeting is left `.recording`, exactly as a real crash
            // mid-meeting would leave it.
        }

        // A genuinely new container, opened fresh against the same file. Nothing here shares
        // any in-memory state with the block above.
        //
        // Deliberately NOT `readContext.model(for:)`: that call looks like a safe,
        // Optional-returning lookup but isn't — it FATAL-ERRORS the whole process if the
        // context it's called on hasn't already got the object registered (exactly the case
        // for a context that has never fetched anything yet), rather than returning a fault
        // it resolves lazily. A `FetchDescriptor` is a real round trip to the on-disk store,
        // which is also the more honest way to ask "is this actually durable on disk" in the
        // first place. See `MeetingStore.meeting(for:)` for the same reasoning applied to the
        // store's own lookups, and `FORK-PATCHES.md`'s Stage 2a entries for the crash this
        // produced before the test was written this way.
        let reopenedConfig = ModelConfiguration(schema: schema, url: storeURL)
        let reopenedContainer = try ModelContainer(for: schema, configurations: reopenedConfig)
        let readContext = ModelContext(reopenedContainer)

        let allMeetings = try readContext.fetch(FetchDescriptor<Meeting>())
        let reread = try #require(allMeetings.first)

        // Compared by `Meeting.id`, not by `PersistentIdentifier`: Apple documents the latter
        // as valid only for the lifetime of the `ModelContainer` that produced it, not across
        // a relaunch/reopen — and this is not a theoretical caveat, it was proven empirically
        // here. Before this comment existed, the equivalent assertion FAILED against this exact
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

        let meetingIDValue: UUID
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: config)
            let store = MeetingStore(modelContainer: container)

            let meeting = try await store.startMeeting(
                title: "Clean finish", audioDirectoryPath: tempDirectory.path, startDate: start
            )
            meetingIDValue = try #require(ModelContext(container).fetch(FetchDescriptor<Meeting>()).first).id
            try await store.updateDuration(600, for: meeting)
            try await store.finish(meeting, endDate: end)
        }

        let reopenedConfig = ModelConfiguration(schema: schema, url: storeURL)
        let reopenedContainer = try ModelContainer(for: schema, configurations: reopenedConfig)
        let readContext = ModelContext(reopenedContainer)

        // See the sibling test above for why this reads via `fetch(FetchDescriptor<Meeting>())`
        // and compares `Meeting.id`.
        let reread = try #require(readContext.fetch(FetchDescriptor<Meeting>()).first)
        #expect(reread.id == meetingIDValue)
        #expect(reread.state == .completed)
        #expect(reread.endDate == end)
        #expect(reread.duration == 900)
    }
}

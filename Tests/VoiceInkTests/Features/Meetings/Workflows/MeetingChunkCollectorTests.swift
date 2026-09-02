// New tests for MeetingChunkCollector (ported verbatim from the donor's MeetingSession.swift,
// see MeetingChunkCollector.swift's own header) -- the donor never shipped a dedicated test file
// for this type, so this is new coverage, not a port.

import Foundation
import Testing

@testable import VoiceInk

@Suite("MeetingChunkCollector")
struct MeetingChunkCollectorTests {
    @Test("retired segments are returned by closeAndDrainSortedSegments, sorted by start then text")
    func retiredSegmentsAreDrainedSorted() async {
        let collector = MeetingChunkCollector()

        let taskB = Task { MeetingChunkCollector.Outcome(segments: [SpeechSegment(start: 2.0, end: 2.5, text: "b")], persistenceFailures: []) }
        let (registeredB, idB) = collector.add(taskB)
        #expect(registeredB)
        let outcomeB = await taskB.value
        #expect(collector.retire(id: idB, segments: outcomeB.segments))

        let taskA = Task { MeetingChunkCollector.Outcome(segments: [SpeechSegment(start: 1.0, end: 1.5, text: "a")], persistenceFailures: []) }
        let (registeredA, idA) = collector.add(taskA)
        #expect(registeredA)
        let outcomeA = await taskA.value
        #expect(collector.retire(id: idA, segments: outcomeA.segments))

        let drained = await collector.closeAndDrainSortedSegments()
        #expect(drained.segments.map(\.text) == ["a", "b"])
        #expect(drained.persistenceFailures.isEmpty)
    }

    @Test("closeAndDrainSortedSegments awaits still-pending tasks before returning")
    func drainAwaitsPendingTasks() async {
        let collector = MeetingChunkCollector()
        let task = Task { () -> MeetingChunkCollector.Outcome in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return MeetingChunkCollector.Outcome(segments: [SpeechSegment(start: 0, end: 1, text: "slow")], persistenceFailures: [])
        }
        let (registered, _) = collector.add(task)
        #expect(registered)

        // Never manually retired -- still pending when drain runs.
        let drained = await collector.closeAndDrainSortedSegments()
        #expect(drained.segments.map(\.text) == ["slow"])
        #expect(drained.persistenceFailures.isEmpty)
    }

    @Test("closeAndDrainSortedSegments surfaces persistence failures from a still-pending task it had to await")
    func drainSurfacesPersistenceFailuresFromPendingTask() async {
        struct StubError: Error {}
        let collector = MeetingChunkCollector()
        let task = Task { () -> MeetingChunkCollector.Outcome in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return MeetingChunkCollector.Outcome(
                segments: [SpeechSegment(start: 0, end: 1, text: "raced")],
                persistenceFailures: [StubError()]
            )
        }
        let (registered, _) = collector.add(task)
        #expect(registered)

        let drained = await collector.closeAndDrainSortedSegments()
        #expect(drained.segments.map(\.text) == ["raced"])
        #expect(drained.persistenceFailures.count == 1)
    }

    @Test("add after close is refused")
    func addAfterCloseIsRefused() async {
        let collector = MeetingChunkCollector()
        _ = await collector.closeAndDrainSortedSegments()

        let task = Task { MeetingChunkCollector.Outcome(segments: [SpeechSegment(start: 0, end: 1, text: "late")], persistenceFailures: []) }
        let (registered, _) = collector.add(task)
        #expect(!registered)
        task.cancel()
    }

    @Test("retire after close is refused, even for a task registered before close")
    func retireAfterCloseIsRefused() async {
        let collector = MeetingChunkCollector()
        let task = Task { MeetingChunkCollector.Outcome(segments: [SpeechSegment(start: 0, end: 1, text: "x")], persistenceFailures: []) }
        let (registered, id) = collector.add(task)
        #expect(registered)

        // Close races the retire: simulate by closing before the caller gets to retire.
        _ = await collector.closeAndDrainSortedSegments()
        #expect(!collector.retire(id: id, segments: [SpeechSegment(start: 0, end: 1, text: "x")]))
    }

    @Test("cancelAll cancels every pending task and closes the collector")
    func cancelAllCancelsPendingTasks() async {
        let collector = MeetingChunkCollector()
        let task = Task<MeetingChunkCollector.Outcome, Never> {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return MeetingChunkCollector.Outcome(segments: [SpeechSegment(start: 0, end: 1, text: "never")], persistenceFailures: [])
        }
        let (registered, _) = collector.add(task)
        #expect(registered)

        collector.cancelAll()
        #expect(task.isCancelled)

        // Collector is closed after cancelAll -- a later add is refused.
        let lateTask = Task { MeetingChunkCollector.Outcome(segments: [SpeechSegment(start: 0, end: 1, text: "late")], persistenceFailures: []) }
        let (lateRegistered, _) = collector.add(lateTask)
        #expect(!lateRegistered)
        lateTask.cancel()
    }
}

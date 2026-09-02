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

        let taskB = Task { [SpeechSegment(start: 2.0, end: 2.5, text: "b")] }
        let (registeredB, idB) = collector.add(taskB)
        #expect(registeredB)
        let segmentsB = await taskB.value
        #expect(collector.retire(id: idB, segments: segmentsB))

        let taskA = Task { [SpeechSegment(start: 1.0, end: 1.5, text: "a")] }
        let (registeredA, idA) = collector.add(taskA)
        #expect(registeredA)
        let segmentsA = await taskA.value
        #expect(collector.retire(id: idA, segments: segmentsA))

        let drained = await collector.closeAndDrainSortedSegments()
        #expect(drained.map(\.text) == ["a", "b"])
    }

    @Test("closeAndDrainSortedSegments awaits still-pending tasks before returning")
    func drainAwaitsPendingTasks() async {
        let collector = MeetingChunkCollector()
        let task = Task { () -> [SpeechSegment] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return [SpeechSegment(start: 0, end: 1, text: "slow")]
        }
        let (registered, _) = collector.add(task)
        #expect(registered)

        // Never manually retired -- still pending when drain runs.
        let drained = await collector.closeAndDrainSortedSegments()
        #expect(drained.map(\.text) == ["slow"])
    }

    @Test("add after close is refused")
    func addAfterCloseIsRefused() async {
        let collector = MeetingChunkCollector()
        _ = await collector.closeAndDrainSortedSegments()

        let task = Task { [SpeechSegment(start: 0, end: 1, text: "late")] }
        let (registered, _) = collector.add(task)
        #expect(!registered)
        task.cancel()
    }

    @Test("retire after close is refused, even for a task registered before close")
    func retireAfterCloseIsRefused() async {
        let collector = MeetingChunkCollector()
        let task = Task { [SpeechSegment(start: 0, end: 1, text: "x")] }
        let (registered, id) = collector.add(task)
        #expect(registered)

        // Close races the retire: simulate by closing before the caller gets to retire.
        _ = await collector.closeAndDrainSortedSegments()
        #expect(!collector.retire(id: id, segments: [SpeechSegment(start: 0, end: 1, text: "x")]))
    }

    @Test("cancelAll cancels every pending task and closes the collector")
    func cancelAllCancelsPendingTasks() async {
        let collector = MeetingChunkCollector()
        let task = Task<[SpeechSegment], Never> {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return [SpeechSegment(start: 0, end: 1, text: "never")]
        }
        let (registered, _) = collector.add(task)
        #expect(registered)

        collector.cancelAll()
        #expect(task.isCancelled)

        // Collector is closed after cancelAll -- a later add is refused.
        let lateTask = Task { [SpeechSegment(start: 0, end: 1, text: "late")] }
        let (lateRegistered, _) = collector.add(lateTask)
        #expect(!lateRegistered)
        lateTask.cancel()
    }
}

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
        #expect(collector.retire(id: idB, segments: outcomeB.segments, persistenceFailures: outcomeB.persistenceFailures))

        let taskA = Task { MeetingChunkCollector.Outcome(segments: [SpeechSegment(start: 1.0, end: 1.5, text: "a")], persistenceFailures: []) }
        let (registeredA, idA) = collector.add(taskA)
        #expect(registeredA)
        let outcomeA = await taskA.value
        #expect(collector.retire(id: idA, segments: outcomeA.segments, persistenceFailures: outcomeA.persistenceFailures))

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

    /// Regression test for the WATCHER-WINS half of the drain invariant, which survived two
    /// earlier fix rounds. The pending-task half above (`drainSurfacesPersistenceFailuresFrom
    /// PendingTask`) covers the case where `closeAndDrainSortedSegments()` reaches
    /// `await task.value` itself. This covers the other side of that same race: the chunk's own
    /// watcher Task got there first and retired the chunk BEFORE close, moving its segments into
    /// `completedSegments`. `retire` used to take only the segments, so the failures were
    /// dropped on the floor at that exact moment and the drain later handed back a segment it
    /// could no longer report a persistence failure for -- the transcript said the meeting was
    /// complete and `MeetingEngineResult.persistenceFailures` said it persisted cleanly, while
    /// the only record that it had not was a line on stderr.
    ///
    /// Deterministic by construction, with no timing at all: the task is awaited to completion
    /// and retired explicitly before `closeAndDrainSortedSegments()` is ever called, so the
    /// watcher-wins interleaving is not raced for, it is imposed.
    @Test("closeAndDrainSortedSegments surfaces persistence failures from a task retired before close")
    func drainSurfacesPersistenceFailuresFromRetiredTask() async {
        struct StubError: Error {}
        let collector = MeetingChunkCollector()
        let task = Task { () -> MeetingChunkCollector.Outcome in
            MeetingChunkCollector.Outcome(
                segments: [SpeechSegment(start: 0, end: 1, text: "retired with a failure")],
                persistenceFailures: [StubError()]
            )
        }
        let (registered, id) = collector.add(task)
        #expect(registered)

        // The watcher wins: it awaits the value and retires the chunk while the collector is
        // still open, exactly as `rotateChunkOnQueue`'s watcher Task does mid-meeting.
        let outcome = await task.value
        #expect(collector.retire(id: id, segments: outcome.segments, persistenceFailures: outcome.persistenceFailures))

        let drained = await collector.closeAndDrainSortedSegments()
        #expect(drained.segments.map(\.text) == ["retired with a failure"])
        #expect(drained.persistenceFailures.count == 1)
        #expect(drained.persistenceFailures.first is StubError)
    }

    /// The exclusivity half of the same invariant: a failure is reported ONCE, never twice.
    /// `retire` and the drain's own critical section take the same lock, so a retired task is
    /// gone from `pendingTasks` before the drain can snapshot it -- there is no interleaving in
    /// which the drain both reads `completedPersistenceFailures` and awaits the same task's
    /// `Outcome`. Asserted rather than reasoned about, because "reported once" is exactly the
    /// property a future edit that reports failures from both buckets would break silently.
    @Test("a retired chunk's persistence failure is reported exactly once, not once per bucket")
    func retiredFailureIsReportedExactlyOnce() async {
        struct StubError: Error {}
        let collector = MeetingChunkCollector()
        let task = Task { () -> MeetingChunkCollector.Outcome in
            MeetingChunkCollector.Outcome(
                segments: [SpeechSegment(start: 0, end: 1, text: "once")],
                persistenceFailures: [StubError()]
            )
        }
        let (registered, id) = collector.add(task)
        #expect(registered)
        let outcome = await task.value
        #expect(collector.retire(id: id, segments: outcome.segments, persistenceFailures: outcome.persistenceFailures))

        let drained = await collector.closeAndDrainSortedSegments()
        #expect(drained.segments.count == 1)
        #expect(drained.persistenceFailures.count == 1)
    }

    /// A second drain must not re-report what the first already handed back: the failure
    /// bucket is cleared with the segments it belongs to. Same reason the segment bucket is
    /// cleared -- a drain result describes the segments THAT call is returning.
    @Test("a second drain re-reports neither segments nor persistence failures")
    func secondDrainReportsNothingTwice() async {
        struct StubError: Error {}
        let collector = MeetingChunkCollector()
        let task = Task { () -> MeetingChunkCollector.Outcome in
            MeetingChunkCollector.Outcome(
                segments: [SpeechSegment(start: 0, end: 1, text: "drained")],
                persistenceFailures: [StubError()]
            )
        }
        let (registered, id) = collector.add(task)
        #expect(registered)
        let outcome = await task.value
        #expect(collector.retire(id: id, segments: outcome.segments, persistenceFailures: outcome.persistenceFailures))

        let first = await collector.closeAndDrainSortedSegments()
        #expect(first.segments.count == 1)
        #expect(first.persistenceFailures.count == 1)

        let second = await collector.closeAndDrainSortedSegments()
        #expect(second.segments.isEmpty)
        #expect(second.persistenceFailures.isEmpty)
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
        struct StubError: Error {}
        let collector = MeetingChunkCollector()
        let task = Task { MeetingChunkCollector.Outcome(segments: [SpeechSegment(start: 0, end: 1, text: "x")], persistenceFailures: []) }
        let (registered, id) = collector.add(task)
        #expect(registered)

        // Close races the retire: simulate by closing before the caller gets to retire.
        _ = await collector.closeAndDrainSortedSegments()
        #expect(!collector.retire(id: id, segments: [SpeechSegment(start: 0, end: 1, text: "x")], persistenceFailures: [StubError()]))
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

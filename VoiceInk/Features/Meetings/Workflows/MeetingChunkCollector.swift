// Ported from Muesli-HQ/muesli (native/MuesliNative/Sources/MuesliNativeApp/MeetingSession.swift,
// lines 8-92 -- `MeetingChunkCollector` was a top-level type in the donor's MeetingSession.swift,
// split into its own file here since this fork's MeetingSession port (`MeetingEngine.swift`) is
// itself a large file. `SpeechSegment` resolves to this fork's own type.
//
// ONE DELIBERATE DEVIATION FROM THE DONOR: the tracked `Task`'s result type is `Outcome`
// (segments PLUS the persistence attempt's failures), not bare `[SpeechSegment]`. The donor has
// no per-chunk persistence layer at all, so it never had anything to track here beyond
// transcription. This fork's persistence is folded into the SAME `Task` the collector tracks
// (see `add(_:)`/`retire(id:segments:persistenceFailures:)`), specifically so that `retire`
// succeeding is a genuine guarantee that persistence for that chunk already ran to completion
// -- not merely that persistence was *about* to be attempted by some other, unsynchronized
// caller -- and so that `retire` carries the OUTCOME of that persistence, not just its
// segments: a retirement that dropped the failures on the floor left the drain returning
// segments whose persistence failures it could no longer report, the same defect one step
// further along. See
// `closeAndDrainSortedSegments()`'s doc comment and `MeetingEngine.swift`'s `stop()` for why
// that distinction is load-bearing: an earlier version of this file called `retire` BEFORE its
// caller persisted, which let `stop()` observe a chunk as "already completed" (and so skip
// re-persisting it, correctly) while its actual persistence attempt was still in flight or had
// already failed silently to stderr -- the exact defect `persistPending` (this file's previous
// deviation, now removed) was meant to close for a DIFFERENT race but did not close for this
// one, because it only ever ran for tasks `stop()` observed as still-pending, never for ones a
// concurrent `retire` had *just* claimed.
//
// MIT License
//
// Copyright (c) 2026 Pranav Hari
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// See NOTICE for full attribution.

import Foundation
import os

/// Collects the results of per-chunk transcription `Task`s for one audio source (mic or
/// system) across a meeting. Chunks can finish transcribing in a different order than they
/// were rotated in, so completed segments are accumulated unordered and only sorted at drain
/// time (`closeAndDrainSortedSegments()`).
final class MeetingChunkCollector {
    /// What a tracked `Task` resolves to: the transcribed segments AND the outcome of
    /// persisting them, bundled into the SAME unit this collector awaits. Bundling them is
    /// what makes `retire` succeeding a genuine guarantee that persistence already ran -- see
    /// this file's header. `persistenceFailures` is empty on full success (including the
    /// trivial case of no segments to persist).
    struct Outcome {
        let segments: [SpeechSegment]
        let persistenceFailures: [Error]

        static let empty = Outcome(segments: [], persistenceFailures: [])
    }

    private struct PendingTask {
        let id: UUID
        let task: Task<Outcome, Never>
    }

    private struct State {
        // Only in-flight tasks live here. Completed tasks are retired into
        // completedSegments so Task objects and their captured state don't
        // accumulate for the full meeting duration.
        var pendingTasks: [PendingTask] = []
        var completedSegments: [SpeechSegment] = []
        // The persistence failures of retired tasks, held alongside their segments for exactly
        // as long as those segments are held, so a drain returns BOTH halves of what it hands
        // back. See `retire(id:segments:persistenceFailures:)`.
        var completedPersistenceFailures: [Error] = []
        var isClosed = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Register a chunk task (transcription and, per this file's deviation from the donor,
    /// its persistence attempt). Returns the retire ID to pass to retire(id:segments:) once
    /// the task completes.
    func add(_ task: Task<Outcome, Never>) -> (registered: Bool, retireID: UUID) {
        let id = UUID()
        let registered = lock.withLock { state in
            guard !state.isClosed else { return false }
            state.pendingTasks.append(PendingTask(id: id, task: task))
            return true
        }
        return (registered, id)
    }

    /// Move a completed task's segments AND that task's persistence failures into the
    /// collector, dropping the Task reference. Must be called from the watcher Task AFTER
    /// awaiting the task's value -- which, because persistence is bundled into that same value
    /// (`Outcome`), means AFTER persistence for `segments` has already run to completion.
    ///
    /// `persistenceFailures` is taken here, not left to the watcher alone, because leaving it
    /// to the watcher alone was the open half of this file's invariant. The watcher still logs
    /// them (that is the right and only reporting channel at minute 40, when no `stop()` is in
    /// sight and there is no result object to report into) -- but a segment and the outcome of
    /// persisting it must not part company at the moment they are retired, or the drain hands
    /// back a segment whose failure it can no longer see. Concretely: watcher retires with a
    /// failure -> drain returns the segment from `completedSegments` -> the failure reached
    /// stderr and nothing else, while `MeetingEngineResult.persistenceFailures` said the
    /// meeting persisted cleanly. Holding the failure next to its segment costs one array and
    /// removes that asymmetry outright, with no timing dependence and nothing to get wrong:
    /// there is no attempt anywhere in this type to work out whether a given retirement was
    /// "racing `stop()`" or not, because any such test would be a race-detection heuristic and
    /// this file has already been defeated twice by reasoning of that shape.
    ///
    /// Reported exactly once, structurally. `retire` and `closeAndDrainSortedSegments()`'s own
    /// critical section take the SAME lock, so one of them runs first and the other sees its
    /// effect: if `retire` wins, the task is gone from `pendingTasks` before the drain
    /// snapshots it, and the failures travel in `completedPersistenceFailures`; if the drain
    /// wins, `isClosed` is already set, this returns `false` having stored nothing, and the
    /// failures travel via `await task.value` instead. Never both, never neither.
    func retire(id: UUID, segments: [SpeechSegment], persistenceFailures: [Error]) -> Bool {
        lock.withLock { state in
            guard !state.isClosed else { return false }
            state.completedSegments.append(contentsOf: segments)
            state.completedPersistenceFailures.append(contentsOf: persistenceFailures)
            state.pendingTasks.removeAll { $0.id == id }
            return true
        }
    }

    /// Closes the collector, drains it, and returns every collected segment sorted by start,
    /// plus the persistence failures of every one of those segments.
    ///
    /// THE INVARIANT, in full: for every segment in the returned array, that segment's
    /// persistence attempt has run to completion, and any failure from that attempt is in the
    /// returned `persistenceFailures`. Both halves, for both sides of the race, with no gap
    /// between them.
    ///
    /// For a task already `retire`d before this ran: its persistence already completed before
    /// `retire` succeeded (see this file's header), and its failures were stored beside its
    /// segments by that same `retire` call, so they are returned from `completedPersistence
    /// Failures` here. An earlier revision deliberately did NOT return these, arguing they were
    /// "old, already-logged mid-meeting failures" that a drain result had no business
    /// revisiting. Review rejected that, correctly: the argument is about WHEN the failure
    /// happened, but the result object's contract is about WHICH SEGMENTS it is handing back --
    /// and it is handing this one back. A drain that returns a segment while withholding the
    /// reason it never reached disk reports a clean meeting for a transcript that is only
    /// partly persisted, which is the entire failure mode this type exists to prevent. The
    /// watcher's stderr log stays exactly as it was (unchanged, and still the only report a
    /// mid-meeting failure gets at the time it happens); this is not a second mid-meeting
    /// reporting channel, it is the same failure staying attached to its segment until someone
    /// drains it.
    ///
    /// For a task NOT yet `retire`d when this ran (still in `pendingTasks`): its own watcher
    /// Task is concurrently racing to reach the same `await task.value` and then call `retire`,
    /// which is now guaranteed to fail (`isClosed`) -- but that race is harmless, because
    /// `Task.value` only ever executes the task's body once no matter how many callers await
    /// it, and persistence lives INSIDE that body. So whichever of {this call, the watcher}
    /// observes the result first, persistence itself already ran (or is running) exactly once;
    /// this call awaits that same completion and returns its failures, so the chunk's
    /// persistence outcome reaches `MeetingEngine.stop()`'s result rather than only the
    /// watcher's stderr log (which still fires too, redundantly but harmlessly, for whichever
    /// side loses the `retire` race).
    func closeAndDrainSortedSegments() async -> (segments: [SpeechSegment], persistenceFailures: [Error]) {
        let (tasksToAwait, alreadyCompleted, alreadyCompletedFailures) = lock.withLock { state in
            state.isClosed = true
            let tasks = state.pendingTasks.map { $0.task }
            let completed = state.completedSegments
            let completedFailures = state.completedPersistenceFailures
            state.pendingTasks.removeAll()
            state.completedSegments.removeAll()
            state.completedPersistenceFailures.removeAll()
            return (tasks, completed, completedFailures)
        }

        var segments = alreadyCompleted
        var persistenceFailures = alreadyCompletedFailures
        for task in tasksToAwait {
            let outcome = await task.value
            segments.append(contentsOf: outcome.segments)
            persistenceFailures.append(contentsOf: outcome.persistenceFailures)
        }

        let sorted = segments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
        return (sorted, persistenceFailures)
    }

    func waitUntilRetired() async {
        while true {
            let tasks = lock.withLock { $0.pendingTasks.map(\.task) }
            guard !tasks.isEmpty else { return }
            for task in tasks {
                _ = await task.value
            }
            await Task.yield()
        }
    }

    func cancelAll() {
        let tasksToCancel = lock.withLock { state in
            state.isClosed = true
            let tasks = state.pendingTasks.map { $0.task }
            state.pendingTasks.removeAll()
            state.completedSegments.removeAll()
            // Discarded with the segments they belong to: `cancelAll` is the discard path
            // (`MeetingEngine.discard()`), where the caller has said it wants none of this
            // meeting's output. Keeping failures for a transcript nobody will read would be
            // reporting on a meeting that no longer exists.
            state.completedPersistenceFailures.removeAll()
            return tasks
        }
        tasksToCancel.forEach { $0.cancel() }
    }
}

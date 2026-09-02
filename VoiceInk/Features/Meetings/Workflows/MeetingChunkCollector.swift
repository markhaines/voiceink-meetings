// Ported from Muesli-HQ/muesli (native/MuesliNative/Sources/MuesliNativeApp/MeetingSession.swift,
// lines 8-92 -- `MeetingChunkCollector` was a top-level type in the donor's MeetingSession.swift,
// split into its own file here since this fork's MeetingSession port (`MeetingEngine.swift`) is
// itself a large file. `SpeechSegment` resolves to this fork's own type.
//
// ONE DELIBERATE DEVIATION FROM THE DONOR: the tracked `Task`'s result type is `Outcome`
// (segments PLUS the persistence attempt's failures), not bare `[SpeechSegment]`. The donor has
// no per-chunk persistence layer at all, so it never had anything to track here beyond
// transcription. This fork's persistence is folded into the SAME `Task` the collector tracks
// (see `add(_:)`/`retire(id:segments:)`), specifically so that `retire` succeeding is a
// genuine guarantee that persistence for that chunk already ran to completion -- not merely
// that persistence was *about* to be attempted by some other, unsynchronized caller. See
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

    /// Move a completed task's segments into the collector and drop the Task reference. Must
    /// be called from the watcher Task AFTER awaiting the task's value -- which, because
    /// persistence is bundled into that same value (`Outcome`), means AFTER persistence for
    /// `segments` has already run to completion. `persistenceFailures` from that same
    /// `Outcome` are the watcher's own responsibility to report (it has no result object to
    /// report into mid-meeting, so it logs); this method only tracks segments, matching its
    /// pre-existing scope.
    func retire(id: UUID, segments: [SpeechSegment]) -> Bool {
        lock.withLock { state in
            guard !state.isClosed else { return false }
            state.completedSegments.append(contentsOf: segments)
            state.pendingTasks.removeAll { $0.id == id }
            return true
        }
    }

    /// Closes the collector, drains it, and returns every collected segment sorted by start,
    /// plus the persistence failures of whichever chunks this call itself had to wait out.
    ///
    /// For a task already `retire`d before this ran: its persistence already completed before
    /// `retire` succeeded (see this file's header), so nothing further to await or report --
    /// its failures, if any, were already the watcher's to log, same as any other mid-meeting
    /// chunk. This method does not revisit them; doing so would mean reporting old, already-
    /// logged mid-meeting failures through a result object that exists to report exactly the
    /// segments THIS call had to drain, not the whole meeting's persistence history.
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
        let (tasksToAwait, alreadyCompleted) = lock.withLock { state in
            state.isClosed = true
            let tasks = state.pendingTasks.map { $0.task }
            let completed = state.completedSegments
            state.pendingTasks.removeAll()
            state.completedSegments.removeAll()
            return (tasks, completed)
        }

        var segments = alreadyCompleted
        var persistenceFailures: [Error] = []
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
            return tasks
        }
        tasksToCancel.forEach { $0.cancel() }
    }
}

// Extracted out of `AppDelegate.applicationShouldTerminate(_:)` (PR #15 review round 3, B1-i)
// specifically so this race's one actual load-bearing property -- the ceiling fires even if
// `work` never returns at all -- is unit-testable (`MeetingQuitRaceTests.swift`) without any
// real `MeetingEngine`, CoreAudio, or SwiftData involved.
//
// SUPERSEDES a first attempt at this fix that used `withTaskGroup(of: Void.self) { ... }` with
// `group.cancelAll()` after `group.next()` returned. That shape is BROKEN for this use: a task
// group cannot return from its closure until every child task it started has actually
// finished, and `cancelAll()` only REQUESTS cancellation -- it does not detach or abandon a
// running child. Swift's cancellation is cooperative: a task that never checks
// `Task.isCancelled` (or isn't suspended on something that itself responds to cancellation,
// like `Task.sleep`) simply keeps running to completion regardless of being marked cancelled.
// `MeetingEngine.stop()` -- what `MeetingRecordingController.stopMeetingAndWait()` awaits -- is
// exactly that case: read in full for this fix, its `Task.isCancelled` checks (exactly two)
// both gate unrelated MID-MEETING chunk-rotation tasks (`rotateChunkOnQueue`/
// `rotateSystemChunkOnQueue`), not `stop()`'s own body, which is a straight-line sequence of
// synchronous CoreAudio teardown calls (`meetingMicRecorder.stop()`, `systemAudioRecorder
// .stop()`) and actor-isolated SwiftData saves (`persistence.finish`, `persistSegments`) with
// no cancellation check anywhere in that chain. A synchronous call blocking the thread cannot
// be preempted by cancellation at all -- there is no suspension point for cancellation to be
// observed at. So the task-group version could, in the exact scenario it exists to guard
// against (a wedged finalize), hang forever waiting for `stopMeetingAndWait()` to return,
// never call `NSApp.reply(toApplicationShouldTerminate:)`, and leave Mark unable to quit his
// Mac -- strictly worse than the stranded row this fix exists to prevent, and the opposite of
// what its own comment claimed.
//
// This version uses two INDEPENDENT, UNSTRUCTURED `Task`s instead. Neither is a structured
// child of the other or of any group, so nothing here ever awaits `work` to decide when to
// call `onComplete` -- the ceiling's own `Task.sleep` fires on its own schedule regardless of
// what `work` is doing. If `work` is still running when the ceiling wins, it is not cancelled
// and not awaited: it is simply abandoned, left running against a process that
// `applicationShouldTerminate(_:)`'s caller is about to tear down anyway. If it manages to
// persist anything before the process actually exits, that write survives -- incremental
// persistence already tolerates a meeting stopping mid-write, which is the entire reason it
// exists. If it doesn't, the row is left exactly where it was, for `MeetingStore
// .reconcileInterruptedRecordings(in:)` to reconcile truthfully on next launch.
//
// HIDDEN DEPENDENCY, stated explicitly so a future reader does not have to rediscover it: the
// ceiling `Task`'s `Task.sleep` continuation resumes ON THE MAIN ACTOR (both `Task`s below are
// `Task { @MainActor in ... }`). That resumption can only happen when the main actor is
// actually free to run it. Today it is, because of a specific, checkable fact about the code
// this races: `MeetingEngine` -- and every concrete type on its `stop()` call chain
// (`CoreAudioSystemRecorder`, `RouteAwareMeetingMicRecorder`, `MeetingRecordingWriter`,
// `MeetingChunkCollector`) -- carries NO `@MainActor` annotation anywhere (grepped across
// `Features/Meetings/{Capture,Models,Workflows}/`; the one `@MainActor` hit in that whole tree
// is `CoreAudioSystemRecorder.openSystemAudioSettings()`, an unrelated static function never
// on the `stop()` path). Because `MeetingEngine.stop()` is therefore a plain NONISOLATED async
// function, calling it via `await` from a `@MainActor` context (`MeetingRecordingController
// .stopMeetingAndWait()`) does NOT keep it running on that caller's actor -- per SE-0338
// ("Clarify the Execution of Non-Actor-Isolated Async Functions", in effect on this project's
// toolchain), a nonisolated async function hops onto the default global concurrent executor
// for its own execution, and only touches the caller's actor again at points where it needs
// that actor's isolated state (which `stop()` never does mid-flight). Verified empirically,
// not just cited: a throwaway script reproducing this exact shape (a `@MainActor` caller
// `await`-ing a plain nonisolated `async` method) printed `Thread.isMainThread == true` in the
// caller and `== false` inside the callee, confirming the hop actually happens on this Swift
// toolchain rather than assuming the proposal's text still describes current behavior.
//
// This is why the synchronous CoreAudio teardown and SwiftData saves inside `stop()`'s body
// run OFF the main actor/main thread today, which is exactly what keeps the main actor free
// for this file's ceiling to fire on schedule -- and it is why the `MeetingQuitRaceTests.swift`
// fixture blocks a DETACHED thread (via `DispatchSemaphore.wait()` bridged through
// `withCheckedContinuation`), not the main actor: that is what models the real, current case.
//
// **This guarantee would break silently if the `stop()` path ever became main-actor-isolated**
// -- e.g. `MeetingEngine` (or just `stop()`) gaining a `@MainActor` annotation, or any type on
// its call chain doing so. `await engine.stop()` would then run its entire synchronous prefix
// directly on the main thread instead of hopping off it; if that prefix ever blocks (a wedged
// CoreAudio teardown, a stuck file write -- the exact scenario this whole fix exists for), the
// main actor itself would be blocked, the ceiling's own `Task.sleep` continuation could not
// resume, `NSApp.reply` would never fire, and the app would become unquittable again --
// silently, because `MeetingQuitRaceTests.swift`'s fixture is a nonisolated closure on a
// detached thread and would keep passing regardless: it exercises `raceAgainstCeiling` in
// isolation, not `MeetingEngine`'s actual isolation. A test that swaps in a genuinely
// `@MainActor`-isolated, synchronously-blocking `work` closure WOULD demonstrate this failure
// mode directly (spawn both `Task { @MainActor in ... }`s and let a real `Thread.sleep` inside
// the `@MainActor` `work` monopolize the main thread ahead of the ceiling's own resumption) --
// considered and deliberately NOT added as a permanent test: it would be pinning down a
// hypothetical about Swift's actor-isolation rules in the abstract, not guarding against a
// plausible accidental regression in this codebase, since marking `MeetingEngine` or any of
// its collaborators `@MainActor` would be an obvious, deliberate, single-line change to files
// this ledger already tracks closely (`FORK-PATCHES.md`) -- not something that could sneak in
// unnoticed the way a comment going stale can. If that ever changes, re-verify this file's
// central claim first, the same way it was verified here: check for `@MainActor` on
// `MeetingEngine`'s call chain, and re-run the throwaway isolation script described above.

import Foundation

/// Runs `work` and races it against `ceilingNanoseconds`, calling `onComplete` from whichever
/// finishes first. A second call (from the loser, if it ever finishes) is a no-op. Not
/// `async`/non-blocking by design: the caller (`AppDelegate.applicationShouldTerminate(_:)`)
/// must return `.terminateLater` to AppKit synchronously, before either race participant has
/// necessarily run at all.
/// `sleep`, PR #15 review round 4 (non-blocking suggestion, accepted): defaults to real
/// `Task.sleep`, but is injectable so a test can prove the WINNER-SELECTION LOGIC (whichever
/// side calls `complete` first) deterministically -- ordering, not wall-clock timing -- immune
/// to CI-runner scheduling jitter. `MeetingQuitRaceTests.RaceOrderingTests` uses this to make
/// the ceiling "fire" essentially instantly while `work` is held open on a manually-controlled
/// gate, with no real-time assertion anywhere in that test. The existing wall-clock test
/// (`ceilingWinsOverNonCancellableWork`, using the real default `sleep` and a real
/// `DispatchSemaphore`-blocked thread) stays alongside it as a smoke test of the actual
/// production code path end to end -- the deterministic test proves the LOGIC is right; the
/// wall-clock one proves the REAL default wiring still behaves the same way.
@MainActor
func raceAgainstCeiling(
    ceilingNanoseconds: UInt64,
    work: @escaping () async -> Void,
    onComplete: @escaping @MainActor (_ workFinished: Bool) -> Void,
    sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
) {
    var didComplete = false
    func complete(_ workFinished: Bool) {
        guard !didComplete else { return }
        didComplete = true
        onComplete(workFinished)
    }

    Task { @MainActor in
        await work()
        complete(true)
    }
    Task { @MainActor in
        try? await sleep(ceilingNanoseconds)
        complete(false)
    }
}

// MARK: - Phase coverage (PR #15 review round 4, B1)

/// Whether `AppDelegate.applicationShouldTerminate(_:)` should hold termination to let a
/// meeting finalize, given the recording controller's current phase. Extracted into its own
/// pure, directly-testable function specifically because the PREVIOUS shape of this decision
/// (`controller.phase == .recording`, inlined in `AppDelegate.swift`) silently missed the
/// natural "press Stop, then quit" sequence: by the time a user does that,
/// `MeetingRecordingController.stopMeeting()` has already flipped `phase` to `.stopping`
/// synchronously, so the old `== .recording` check failed, `applicationShouldTerminate`
/// returned `.terminateNow`, and AppKit killed the IN-FLIGHT finalize -- losing the final chunk
/// transcription and the terminal `persistence.finish` write. See `MeetingQuitRaceTests
/// .shouldRaceMeetingFinalizeTests` for a test that reproduces exactly that regression against
/// the pre-fix single-case shape and confirms the current one covers it.
///
/// Every value `MeetingRecordingController.Phase` can take, and why each answer is what it is:
///
/// - `.idle`: no meeting is open. Nothing to strand or lose. `false`.
/// - `.starting`: `MeetingEngine.start()` is in flight, and it calls `persistence
///   .startMeeting(...)` near the top of its own body -- before the audio pipeline is even set
///   up -- so a `Meeting` row may already exist as `.recording` by the time this phase is
///   externally visible. Quitting here CAN strand a row, the same shape as `.recording`. But
///   nothing valuable has been captured yet to lose: transcription is stubbed regardless
///   (`NullMeetingTranscriptionCoordinator`) and no segments exist yet, so `MeetingStore
///   .reconcileInterruptedRecordings(in:)` on the NEXT launch recovers exactly the same end
///   state (`.failed`, zero segments) that racing this phase would produce. Blocking
///   termination here would only delay quitting for zero additional data preserved.
///   Deliberately `false`, not raced.
/// - `.recording`: a live recording with segments/duration that a graceful `stop()` can still
///   flush. `true` -- covered since round 3.
/// - `.stopping`: THIS round's fix. A `stop()` is already in flight, whose final chunk
///   transcription and terminal `persistence.finish` write would otherwise be killed mid-flight
///   by an unguarded `.terminateNow`. `true` -- raced against the SAME task already running,
///   via `MeetingRecordingController.stopTask()`, never a second call into `engine.stop()`.
///
/// There is no `.paused` case of `Phase` to cover: `MeetingRecordingController` never calls
/// `MeetingEngine.pause()`/`resume()` at all -- `MeetingsView` exposes only Start/Stop, no
/// Pause control (grep-verified: no `pause`/`resume` call anywhere under `Features/Meetings/
/// Views/`). The `.paused` case a reviewer might expect belongs to the separate, PERSISTED
/// `MeetingState` enum (rendered by `MeetingStateBadge` for rows in the list) -- reachable in
/// principle if some other caller ever drove the engine's pause/resume, but no caller in this
/// codebase does, so it cannot occur through this controller today.
func shouldRaceMeetingFinalize(forPhase phase: MeetingRecordingController.Phase) -> Bool {
    switch phase {
    case .idle, .starting:
        return false
    case .recording, .stopping:
        return true
    }
}

// MARK: - Single-flight stop task (PR #15 review round 4, B1)

/// A single-flight cache for one in-progress `Task`: `run(_:)` returns the currently running
/// task if one exists, or starts a new one via `operation` if not, and clears itself once that
/// task completes (success, failure, or early return -- the `defer` covers every exit path).
///
/// Extracted as its own small, generic, directly-testable type (rather than the bespoke
/// `activeStopTask` bookkeeping this replaced) for the same reason `raceAgainstCeiling` above
/// was extracted in round 3: the property it guarantees --- `operation` is never invoked a
/// second time while a first call is still running --- needs to be provably true independent
/// of `MeetingEngine`/CoreAudio, which a `MeetingRecordingController`-level test cannot reach
/// without real audio hardware and TCC consent this CI runner does not have. See
/// `MeetingRecordingController.stopTask()` for the real call site, and
/// `MeetingQuitRaceTests.SingleFlightTaskTests` for the proof.
@MainActor
final class SingleFlightTask<Success: Sendable> {
    private var active: Task<Success, Never>?

    /// Returns the in-flight task if one exists; otherwise starts `operation` on a new task and
    /// returns that. `operation` itself is never invoked while a previous call's task is still
    /// running -- a caller that arrives in between gets the SAME task back, so awaiting its
    /// `.value` waits for the REAL, already-in-progress work, not a second, independent one.
    func run(_ operation: @escaping () async -> Success) -> Task<Success, Never> {
        if let active {
            return active
        }
        let task = Task { [weak self] () -> Success in
            defer { self?.active = nil }
            return await operation()
        }
        active = task
        return task
    }
}

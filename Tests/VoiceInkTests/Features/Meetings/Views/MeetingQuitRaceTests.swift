// Proves the one property `raceAgainstCeiling` (`MeetingQuitRace.swift`) exists for: the
// ceiling fires even if `work` never returns AT ALL, because it does not rely on cancellation
// to cut `work` short. The fixture below is deliberately NOT `Task.sleep` for the "slow work"
// side -- `Task.sleep` cancels cooperatively the instant it is asked to, so a fixture built on
// it would only prove the EASY case (work that responds to cancellation) and would have let
// the broken `withTaskGroup` + `cancelAll()` version this file's header describes pass too.
// Instead this blocks a REAL OS thread on `DispatchSemaphore.wait()`, bridged into `async`
// through `withCheckedContinuation`, which ignores cancellation entirely -- the same shape
// `MeetingEngine.stop()`'s own synchronous CoreAudio teardown calls have (no suspension point,
// nothing to cancel).

import Foundation
import Testing

@testable import VoiceInk

@Suite("raceAgainstCeiling")
@MainActor
struct MeetingQuitRaceTests {
    // Timing margins here are deliberately generous, not tight -- a CI run of this exact test
    // (GitHub Actions run 33960646746, PR #15) failed on a shared/loaded runner with the
    // ceiling firing in 1.801s against this test's original `< 1.0s` assertion: a real
    // scheduling-jitter false failure, not a defect in `raceAgainstCeiling` itself (the
    // `workFinished == false` half, proving the CEILING and not the work fired, still held).
    // The margins below are chosen to comfortably absorb CI-runner jitter of that size while
    // remaining far short of `workHoldSeconds`, so the assertions still mean something.
    // `nonisolated`: plain constants, but captured from a `@Sendable` closure that runs on a
    // detached thread below -- referencing a `@MainActor`-isolated static property from there
    // is a warning (would be an error in stricter concurrency modes) even though nothing about
    // these values actually needs main-actor isolation.
    private nonisolated static let ceilingNanoseconds: UInt64 = 200_000_000 // 200ms
    private nonisolated static let workHoldSeconds: TimeInterval = 60 // far longer than any deadline below
    private nonisolated static let pollDeadlineSeconds: TimeInterval = 10
    private nonisolated static let maxAcceptableElapsedSeconds: TimeInterval = 8

    @Test("the ceiling wins, and fires within it, when work ignores cancellation and never returns in time")
    func ceilingWinsOverNonCancellableWork() async throws {
        // Held open for far longer than either deadline below, so if the race is ever fixed to
        // (incorrectly) wait for `work`, this test hangs/fails loudly rather than passing by
        // accident.
        let workNeverFinishesInTime: @Sendable () async -> Void = {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread {
                    let semaphore = DispatchSemaphore(value: 0)
                    _ = semaphore.wait(timeout: .now() + Self.workHoldSeconds)
                    continuation.resume()
                }
            }
        }

        let recorder = RaceCompletionRecorder()
        let start = Date()

        raceAgainstCeiling(
            ceilingNanoseconds: Self.ceilingNanoseconds,
            work: workNeverFinishesInTime,
            onComplete: { workFinished in
                Task { await recorder.record(workFinished: workFinished, elapsed: Date().timeIntervalSince(start)) }
            }
        )

        // Poll rather than a fixed sleep, bounded well under `workHoldSeconds`: if `onComplete`
        // hasn't fired by `pollDeadlineSeconds`, the ceiling did not bound the race and this
        // test must fail rather than hang forever alongside it.
        let deadline = Date().addingTimeInterval(Self.pollDeadlineSeconds)
        while await recorder.count == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let recorded = await recorder.all
        #expect(recorded.count == 1, "onComplete must fire exactly once")
        let outcome = try #require(recorded.first)
        // The reply happened within a generous bound (not the 200ms ceiling exactly -- CI
        // scheduling jitter alone has been observed to add well over a second)...
        #expect(
            outcome.elapsed < Self.maxAcceptableElapsedSeconds,
            "expected the ceiling to fire well under \(Self.maxAcceptableElapsedSeconds)s, took \(outcome.elapsed)s"
        )
        // ...AND it was the ceiling that fired, not the (impossible within workHoldSeconds) work
        // finishing -- without this second assertion, a race that happened to call onComplete
        // quickly for some other reason would pass the timing check without actually proving
        // the ceiling is what bounded it. This assertion, not the timing one above, is the one
        // that actually distinguishes "the ceiling worked" from "something else finished fast."
        #expect(outcome.workFinished == false, "expected the ceiling to win, not the never-finishing work")
    }

    @Test("work wins when it finishes before the ceiling, and onComplete fires exactly once")
    func workWinsWhenFasterThanCeiling() async throws {
        let recorder = RaceCompletionRecorder()

        raceAgainstCeiling(
            ceilingNanoseconds: 2_000_000_000,
            work: { /* returns immediately */ },
            onComplete: { workFinished in
                Task { await recorder.record(workFinished: workFinished, elapsed: 0) }
            }
        )

        let deadline = Date().addingTimeInterval(Self.pollDeadlineSeconds)
        while await recorder.count == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let recorded = await recorder.all
        #expect(recorded.count == 1)
        #expect(recorded.first?.workFinished == true)
    }
}

private actor RaceCompletionRecorder {
    private(set) var all: [(workFinished: Bool, elapsed: TimeInterval)] = []
    var count: Int { all.count }
    func record(workFinished: Bool, elapsed: TimeInterval) {
        all.append((workFinished, elapsed))
    }
}

// MARK: - Deterministic ordering (PR #15 review round 4, non-blocking suggestion accepted)

/// Proves `raceAgainstCeiling`'s winner-selection logic by controlling ORDER, not wall-clock
/// time: the injected `sleep` resolves with no real delay, and `work` is held open on a
/// manually-released gate, so which side "wins" is deterministic regardless of CI-runner
/// scheduling jitter. Complements, rather than replaces, `MeetingQuitRaceTests
/// .ceilingWinsOverNonCancellableWork()` above, which stays as a wall-clock smoke test of the
/// real default `Task.sleep` wiring end to end.
@Suite("raceAgainstCeiling ordering (deterministic)")
@MainActor
struct RaceOrderingTests {
    @Test("the injected sleep resolving before work is released makes the ceiling win, deterministically")
    func ceilingWinsWhenSleepResolvesFirst() async throws {
        let gate = ReleaseGate()
        let recorder = RaceCompletionRecorder()

        raceAgainstCeiling(
            ceilingNanoseconds: 0,
            work: { await gate.waitForRelease() }, // never released in this test
            onComplete: { workFinished in
                Task { await recorder.record(workFinished: workFinished, elapsed: 0) }
            },
            sleep: { _ in /* resolves with no delay -- simulates the ceiling firing first */ }
        )

        let deadline = Date().addingTimeInterval(5)
        while await recorder.count == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let recorded = await recorder.all
        #expect(recorded.count == 1)
        #expect(recorded.first?.workFinished == false)
    }

    // PR #15 review round 5, B1: this test previously parked BOTH `work` and the injected
    // `sleep` on the SAME `ReleaseGate` and released it once, leaving which continuation
    // actually resumed first to unspecified actor scheduling -- so the "work wins,
    // deterministically" claim was false: the test could pass or fail with no production
    // change at all, which is exactly the class of flaky test this file exists to replace.
    // Fixed with SEPARATE gates: only `workGate` is released, so `work` can win by
    // construction -- `sleepGate` is never touched until the second half below, so there is
    // nothing left for scheduling order to decide. Verified genuinely deterministic by running
    // this test 20 times in a row locally: 20/20 passed (see this round's report).
    @Test("work completing before the injected sleep ever resolves makes work win, deterministically")
    func workWinsWhenReleasedBeforeSleepResolves() async throws {
        let workGate = ReleaseGate()
        let sleepGate = ReleaseGate()
        let recorder = RaceCompletionRecorder()

        raceAgainstCeiling(
            ceilingNanoseconds: 0,
            work: { await workGate.waitForRelease() },
            onComplete: { workFinished in
                Task { await recorder.record(workFinished: workFinished, elapsed: 0) }
            },
            // Held on its OWN gate, untouched below until the second half of this test --
            // nothing here can make it resolve before `workGate` does.
            sleep: { _ in await sleepGate.waitForRelease() }
        )

        await workGate.release()

        let deadline = Date().addingTimeInterval(5)
        while await recorder.count == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let recorded = await recorder.all
        #expect(recorded.count == 1)
        #expect(recorded.first?.workFinished == true)

        // The loser arriving late must not produce a second `onComplete` -- releasing the
        // sleep gate now, after work has already won, must be a no-op.
        await sleepGate.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        let recordedAfterLoserArrives = await recorder.all
        #expect(recordedAfterLoserArrives.count == 1, "the loser's late arrival must not produce a second onComplete")
    }
}

// MARK: - shouldRaceMeetingFinalize (PR #15 review round 4, B1)

/// Reproduces the exact regression B1 describes: the round-3 guard only covered `phase ==
/// .recording`, so the natural "press Stop, then quit" sequence (where `phase` is already
/// `.stopping` by the time the user quits) fell through to `.terminateNow` and killed the
/// in-flight finalize. `.stoppingIsRaced()` below is written against the CURRENT, real
/// `shouldRaceMeetingFinalize(forPhase:)` and passes; it was run against a deliberately
/// reverted, pre-fix copy of that function (`== .recording` only) first, and failed there --
/// see `FORK-PATCHES.md`'s "PR #15 review round 3/4 report" for the verbatim before/after
/// `xcodebuild test` output. This test is what would catch a future regression back to that
/// shape; it does not itself demonstrate the historical failure (the reverted code no longer
/// exists in this file).
@Suite("shouldRaceMeetingFinalize")
struct ShouldRaceMeetingFinalizeTests {
    @Test("idle and starting are not raced")
    func idleAndStartingAreNotRaced() {
        #expect(shouldRaceMeetingFinalize(forPhase: .idle) == false)
        #expect(shouldRaceMeetingFinalize(forPhase: .starting) == false)
    }

    @Test("recording is raced")
    func recordingIsRaced() {
        #expect(shouldRaceMeetingFinalize(forPhase: .recording) == true)
    }

    @Test("stopping is raced -- the exact case B1 found missing")
    func stoppingIsRaced() {
        #expect(shouldRaceMeetingFinalize(forPhase: .stopping) == true)
    }
}

// MARK: - SingleFlightTask (PR #15 review round 4, B1)

/// Proves the property `MeetingRecordingController.stopTask()` depends on to guarantee "never
/// more than one live call into `engine.stop()`": `run(_:)` called a second time while a first
/// call's task is still in flight must return that SAME task, not start a second one -- proven
/// here by a `work` closure that increments a counter and blocks on a continuation until the
/// test releases it, so the test can assert the counter stays at 1 across two `run(_:)` calls
/// while the first is deliberately held open, then reaches exactly 1 (not 2) once released.
@Suite("SingleFlightTask")
@MainActor
struct SingleFlightTaskTests {
    @Test("a second run() while the first is still in flight returns the same task and does not invoke operation again")
    func secondRunWhileInFlightDoesNotDuplicateWork() async throws {
        let single = SingleFlightTask<Int>()
        let gate = ReleaseGate()

        let firstTask = single.run {
            await gate.invocationStarted()
            await gate.waitForRelease()
            return 1
        }

        // Called again before the first has any chance to finish (it's parked on `gate`) --
        // this must NOT start a second `operation`.
        let secondTask = single.run {
            await gate.invocationStarted()
            await gate.waitForRelease()
            return 2
        }

        // Give the first task a chance to actually start running (enter `operation` and park on
        // the gate) before asserting the invocation count -- otherwise this could pass trivially
        // because neither task has been scheduled yet.
        let startDeadline = Date().addingTimeInterval(5)
        while await gate.startedCount == 0 && Date() < startDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await gate.startedCount == 1, "operation must have started exactly once by now")

        await gate.release()

        let firstResult = await firstTask.value
        let secondResult = await secondTask.value

        #expect(await gate.startedCount == 1, "operation must never have started a second time")
        // Both callers observe the SAME task's result -- `1`, from the first operation closure,
        // never `2` from the second, which never ran.
        #expect(firstResult == 1)
        #expect(secondResult == 1)
    }

    @Test("run() after a prior call has completed starts a genuinely new task")
    func runAfterCompletionStartsFresh() async throws {
        let single = SingleFlightTask<Int>()

        let first = await single.run { 1 }.value
        let second = await single.run { 2 }.value

        #expect(first == 1)
        #expect(second == 2)
    }
}

/// Test-only synchronization: lets a test hold an `operation` closure open (simulating a
/// still-in-progress `engine.stop()`) and observe exactly how many times it started, without
/// any real CoreAudio/`MeetingEngine` involved.
private actor ReleaseGate {
    private(set) var startedCount = 0
    // A single stored continuation would drop a second SIMULTANEOUS waiter on the same gate
    // instance (its continuation would overwrite the first's, which would then never resume).
    // No current test relies on two waiters sharing one gate at once -- `RaceOrderingTests
    // .workWinsWhenReleasedBeforeSleepResolves()` was rewritten to use SEPARATE gates for
    // `work` and `sleep` specifically to avoid that ambiguity (see that test's own comment,
    // PR #15 review round 5, B1) -- but holding every waiter, not just the most recent, is
    // cheap and correct regardless of how a future test uses this type.
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func invocationStarted() {
        startedCount += 1
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        let waiters = continuations
        continuations = []
        for continuation in waiters {
            continuation.resume()
        }
    }
}

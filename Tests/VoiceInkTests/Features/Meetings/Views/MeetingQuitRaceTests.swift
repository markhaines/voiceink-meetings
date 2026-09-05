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

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
    @Test("the ceiling wins, and fires within it, when work ignores cancellation and never returns in time")
    func ceilingWinsOverNonCancellableWork() async throws {
        // Held open for 30s -- far longer than the 200ms ceiling below, and far longer than
        // this test's own 2s failure deadline -- so if the race is ever fixed to (incorrectly)
        // wait for `work`, this test hangs/fails loudly rather than passing by accident.
        let workNeverFinishesInTime: @Sendable () async -> Void = {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread {
                    let semaphore = DispatchSemaphore(value: 0)
                    _ = semaphore.wait(timeout: .now() + 30)
                    continuation.resume()
                }
            }
        }

        let recorder = RaceCompletionRecorder()
        let start = Date()

        raceAgainstCeiling(
            ceilingNanoseconds: 200_000_000,
            work: workNeverFinishesInTime,
            onComplete: { workFinished in
                Task { await recorder.record(workFinished: workFinished, elapsed: Date().timeIntervalSince(start)) }
            }
        )

        // Poll rather than a fixed sleep, bounded well under the 30s `work` holds its thread
        // for: if `onComplete` hasn't fired by 2s, the ceiling did not bound the race and this
        // test must fail rather than hang forever alongside it.
        let deadline = Date().addingTimeInterval(2)
        while await recorder.count == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let recorded = await recorder.all
        #expect(recorded.count == 1, "onComplete must fire exactly once")
        let outcome = try #require(recorded.first)
        // The reply happened within the ceiling...
        #expect(outcome.elapsed < 1.0, "expected the 200ms ceiling to fire well under 1s, took \(outcome.elapsed)s")
        // ...AND it was the ceiling that fired, not the (impossible-within-2s) work finishing --
        // without this second assertion, a race that happened to call onComplete quickly for
        // some other reason would pass the timing check without actually proving the ceiling
        // is what bounded it.
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

        let deadline = Date().addingTimeInterval(1)
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

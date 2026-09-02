// New for this fork (Stage 2c fix round, cross-vendor review finding B3). Not a port.
//
// Proves the three properties `ADAPTER-HANDOVER.md` §5 requires of a "correct port" of the
// donor's diarizer preload behavior, using the test-only `loadManager`-injecting initializer and
// the `internal` `resolvedManager()` seam, so none of this needs real CoreML models OR a real
// audio file on disk (unlike `diarize(fileAt:)`, `resolvedManager()` never touches the
// filesystem):
//   1. `sharedLoadIsJoinedNotDuplicated` -- two concurrent callers trigger exactly ONE load.
//   2. `cancelledWaiterReturnsPromptlyWithoutAbortingTheSharedLoad` -- a cancelled joiner returns
//      quickly and the OTHER waiter still gets the real result.
//   3. `hungLoadSurfacesAsATimeoutRatherThanHangingForever` -- the B3 ceiling-actually-bites proof:
//      a loader that never returns is raced against a short deadline, and `resolvedManager()`
//      completes (with a thrown timeout) within a bounded wall-clock window, not indefinitely.

import FluidAudio
import Testing
@testable import VoiceInk

@Suite("FluidAudioMeetingDiarizer")
struct FluidAudioMeetingDiarizerTests {

    private actor CallCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    @Test("a load that never returns surfaces as a timeout within the configured ceiling, not indefinitely")
    func hungLoadSurfacesAsATimeoutRatherThanHangingForever() async throws {
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 0.2) {
            // Simulates a genuinely hung native load: sleeps far longer than the deadline and
            // never checks cancellation, matching a CoreML compile that does not respond to
            // Task.cancel() -- exactly the failure mode B3 is about.
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            fatalError("should never reach here -- the 0.2s deadline must win the race")
        }

        let started = ContinuousClock.now
        await #expect(throws: FluidAudioMeetingDiarizerError.self) {
            _ = try await diarizer.resolvedManager()
        }
        let elapsed = started.duration(to: .now)

        // Generous upper bound (5s) well above the 0.2s deadline but far below the 60s hang --
        // proves completion is BOUNDED, not that it is instantaneous.
        #expect(elapsed < .seconds(5))
    }

    @Test("a hung load's failure is the specific .loadTimedOut case, not a generic error")
    func hungLoadFailureIsSpecificallyTimedOut() async {
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 0.1) {
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            fatalError("should never reach here")
        }

        await #expect(throws: FluidAudioMeetingDiarizerError.loadTimedOut) {
            _ = try await diarizer.resolvedManager()
        }
    }

    @Test("two concurrent callers share ONE load -- the loader runs exactly once")
    func sharedLoadIsJoinedNotDuplicated() async throws {
        let loadCalls = CallCounter()
        let gate = Gate()
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 10) {
            await loadCalls.increment()
            await gate.wait()
            return DiarizerManager(config: .default)
        }

        async let first: DiarizerManager = diarizer.resolvedManager()
        async let second: DiarizerManager = diarizer.resolvedManager()

        // Let both calls register as waiters before releasing the load.
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        await gate.open()

        _ = try await (first, second)

        #expect(await loadCalls.count == 1)
    }

    @Test("a cancelled waiter returns promptly WITHOUT aborting the shared load for the other waiter")
    func cancelledWaiterReturnsPromptlyWithoutAbortingTheSharedLoad() async throws {
        let gate = Gate()
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 10) {
            await gate.wait()
            return DiarizerManager(config: .default)
        }

        let cancelledTask = Task {
            try await diarizer.resolvedManager()
        }
        let survivingTask = Task {
            try await diarizer.resolvedManager()
        }

        // Give both a moment to register as waiters, then cancel only the first.
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelledTask.cancel()

        let cancelledOutcome = await cancelledTask.result
        #expect(throws: CancellationError.self) { try cancelledOutcome.get() }

        // The surviving waiter must still complete successfully once the shared load finishes --
        // proof the cancellation above did not touch the shared load itself.
        await gate.open()
        _ = try await survivingTask.value
    }

    @Test("a successful load is reused on the next call, no second load")
    func successfulLoadIsCachedAcrossCalls() async throws {
        let loadCalls = CallCounter()
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 10) {
            await loadCalls.increment()
            return DiarizerManager(config: .default)
        }

        _ = try await diarizer.resolvedManager()
        _ = try await diarizer.resolvedManager()

        #expect(await loadCalls.count == 1)
    }

    @Test("a failed load is retried on the next call, not permanently poisoned")
    func failedLoadIsRetriedNotPoisoned() async throws {
        struct LoadFailure: Error {}
        let loadCalls = CallCounter()
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 10) {
            let attempt = await loadCalls.count
            await loadCalls.increment()
            if attempt == 0 { throw LoadFailure() }
            return DiarizerManager(config: .default)
        }

        await #expect(throws: LoadFailure.self) { _ = try await diarizer.resolvedManager() }
        _ = try await diarizer.resolvedManager()

        #expect(await loadCalls.count == 2)
    }
}

/// Deterministic suspend/release point, same shape as `MeetingEngineTests.swift`'s own `Gate` --
/// holds a load open exactly as long as a test needs, rather than approximating a race with a
/// fixed `Task.sleep` delay.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let toResume = waiters
        waiters.removeAll()
        toResume.forEach { $0.resume() }
    }
}

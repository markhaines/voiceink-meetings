// New for this fork (Stage 2c fix rounds 3 and 4). Not a port.
//
// WHY THE CEILING FIXTURE LOOKS LIKE THIS. Round 2's ceiling test injected a loader whose body
// was `try await Task.sleep(nanoseconds: 60 * 1_000_000_000)` with a comment claiming it "never
// checks cancellation", raced it against a 0.2s deadline, and reported the caller returning in
// 0.214s. Those numbers were real. The property was wrong: `Task.sleep` IS cancellation-aware, so
// the moment `group.cancelAll()` ran it threw and the "60s" loader was finished -- which is the
// only reason the enclosing `withTaskGroup` (structured: it cannot return until every child
// completes) could return at all. That test could not have failed even if the ceiling were
// entirely fictional, which it was.
//
// `CancellationBlindLoader` below is blind for real, and `roundTwoStructuredCeilingDoesNotBoundABlindLoader`
// is its control: the same fixture against round 2's shape, with the opposite outcome.
//
// Round 4 adds two more properties to this file:
//   * B4.3, the circuit breaker: a permanently stuck load must not let later attempts accumulate
//     more stuck loads. `abandonedLoadsAreCappedSoTheyCannotAccumulate` proves the cap holds
//     across repeated attempts, and that a refused attempt is FAST rather than waiting out
//     another deadline.
//   * B4.4, the injection seam: `injectedLoadStepCannotSupplyTheManagerTheActorResolves` proves a
//     manager a caller constructs and retains is never the manager the actor resolves. The seam's
//     type makes supplying one inexpressible; this pins the behaviour as well.

import FluidAudio
import Foundation
import Testing
@testable import VoiceInk

@Suite("FluidAudioMeetingDiarizer")
struct FluidAudioMeetingDiarizerTests {

    // MARK: - B2: the operation ceiling, proved against a cancellation-BLIND load

    @Test("a cancellation-BLIND load is bounded by the ceiling: the caller returns while the loader is provably still running")
    func hungCancellationBlindLoadIsBoundedByTheCeiling() async throws {
        let loader = CancellationBlindLoader()
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 0.2) { try await loader.run() }

        let started = ContinuousClock.now
        await #expect(throws: FluidAudioMeetingDiarizerError.loadTimedOut) {
            try await diarizer.resolvedManagerIdentity()
        }
        let elapsed = started.duration(to: .now)

        // (1) The caller came back, and quickly. Generous upper bound: this is a boundedness
        //     claim, not a latency one.
        #expect(elapsed < .seconds(5))

        // (2) ...and it did NOT come back because the loader finished. THIS is the assertion
        //     round 2 was missing. Its loader had already thrown by the time the caller
        //     returned, so "the caller returned" said nothing about a stuck load.
        #expect(loader.startCount == 1)
        #expect(loader.finishCount == 0)
        #expect(loader.isStillRunning)

        // (3) The loader is genuinely parked, not merely slow: it completes only once the test
        //     releases it, and reports that cancellation HAD been delivered to its task and was
        //     ignored -- which is the failure mode the ceiling exists for.
        loader.release()
        try await waitUntil("the blind loader finishes after release") { loader.finishCount == 1 }
        #expect(loader.observedCancellationOnFinish == true)
    }

    @Test("CONTROL: round 2's withTaskGroup ceiling does NOT bound the same blind loader")
    func roundTwoStructuredCeilingDoesNotBoundABlindLoader() async throws {
        // A test that passes proves nothing unless it could have failed. Round 2's ceiling test
        // passed and the ceiling was fictional, so this control closes that hole from the other
        // side: it runs the SAME cancellation-blind loader against round 2's EXACT racing shape,
        // reproduced below, and asserts that shape does not come back.
        let loader = CancellationBlindLoader()
        let returned = FlagBox()

        let raced = Task {
            _ = await Self.roundTwoRunWithDeadline(timeoutSeconds: 0.2) { try await loader.run() }
            returned.set()
        }

        // 2s: ten times the 0.2s deadline round 2 claimed to enforce, and well past the wall
        // clock the new design's equivalent test takes end to end.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        #expect(loader.isStillRunning)
        #expect(
            returned.isSet == false,
            """
            Round 2's withTaskGroup ceiling returned against a cancellation-blind loader. If this \
            ever passes, the control has stopped controlling -- check that CancellationBlindLoader \
            is still genuinely blind (a stray Task.sleep or cancellation check inside it is exactly \
            the mistake round 2 made).
            """
        )

        loader.release()
        _ = await raced.value
        #expect(returned.isSet)
    }

    // MARK: - B4.3: the circuit breaker on abandoned loads

    @Test("abandoned loads are capped: repeated attempts refuse fast instead of accumulating stuck loads")
    func abandonedLoadsAreCappedSoTheyCannotAccumulate() async throws {
        let loader = CancellationBlindLoader()
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 0.2) { try await loader.run() }

        // Attempt 1 blows its deadline and is abandoned while still running.
        await #expect(throws: FluidAudioMeetingDiarizerError.loadTimedOut) {
            try await diarizer.resolvedManagerIdentity()
        }
        #expect(loader.startCount == 1)

        // Five further attempts, standing in for five more meetings ending against a
        // permanently stuck CoreML load. Round 3 would have started five more loads.
        for _ in 0..<5 {
            let started = ContinuousClock.now
            await #expect(throws: FluidAudioMeetingDiarizerError.loadAbandonedAndStillOutstanding) {
                try await diarizer.resolvedManagerIdentity()
            }
            // Refused BEFORE any task is created, so it does not wait out another deadline.
            // 0.15s is comfortably under the 0.2s ceiling; a refusal that waited would exceed it.
            #expect(started.duration(to: .now) < .milliseconds(150))
        }
        // The cap held: still exactly ONE load ever started, and it is still the stuck one.
        #expect(loader.startCount == 1)
        #expect(loader.finishCount == 0)

        // The breaker closes by itself when the abandoned load finally returns...
        loader.release()
        try await waitUntil("the abandoned load reports back") { loader.finishCount == 1 }

        // ...and only then does a fresh load start. Two, not seven. (The second `release()` is
        // pre-signalled so the fresh load does not park too: `CancellationBlindLoader` parks on
        // EVERY call, which is what a permanently stuck native load would do.)
        loader.release()
        try await diarizer.resolvedManagerIdentity()
        #expect(loader.startCount == 2)
    }

    @Test("a late result from an abandoned load is quarantined and never becomes the resolved manager")
    func lateResultFromAnAbandonedLoadIsQuarantined() async throws {
        let loader = CancellationBlindLoader()
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 0.2) { try await loader.run() }

        await #expect(throws: FluidAudioMeetingDiarizerError.loadTimedOut) {
            try await diarizer.resolvedManagerIdentity()
        }

        // Let the abandoned generation-1 load finish, late. Its manager must be dropped.
        loader.release()
        try await waitUntil("the abandoned load finishes late") { loader.finishCount == 1 }

        // If generation 1's result had been installed, this call would return it WITHOUT running
        // the load step again. A second start is therefore the quarantine proof. (Pre-signalled
        // so generation 2 does not park as well -- the fixture parks on every call.)
        loader.release()
        let resolved = try await diarizer.resolvedManagerIdentity()
        #expect(loader.startCount == 2)

        // And the generation that did win stays won.
        let again = try await diarizer.resolvedManagerIdentity()
        #expect(again == resolved)
        #expect(loader.startCount == 2)
    }

    // MARK: - B4.4: the injection seam cannot supply the manager

    @Test("a manager an injected load step constructs and retains is never the manager the actor resolves")
    func injectedLoadStepCannotSupplyTheManagerTheActorResolves() async throws {
        // The seam's TYPE already makes supplying a manager inexpressible: `loadStep` returns
        // Void. This pins the behaviour too, against the exact shape the round-3 seam allowed --
        // a caller constructing a manager, retaining it, and expecting the actor to adopt it.
        let retainedByCaller = UncheckedBox(DiarizerManager(config: .default))
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 10) {
            _ = retainedByCaller.value
        }

        let resolved = try await diarizer.resolvedManagerIdentity()

        #expect(resolved != ObjectIdentifier(retainedByCaller.value))
    }

    // MARK: - Shared-load and waiter-cancellation properties (carried over, still required)

    @Test("two concurrent callers share ONE load -- the load step runs exactly once")
    func sharedLoadIsJoinedNotDuplicated() async throws {
        let loadCalls = CallCounter()
        let gate = Gate()
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 10) {
            await loadCalls.increment()
            await gate.wait()
        }

        async let first: ObjectIdentifier = diarizer.resolvedManagerIdentity()
        async let second: ObjectIdentifier = diarizer.resolvedManagerIdentity()

        // Let both calls register as waiters before releasing the load.
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        await gate.open()

        let (firstIdentity, secondIdentity) = try await (first, second)
        #expect(await loadCalls.count == 1)
        // One load, and both callers resolved the SAME instance -- not just the same count.
        #expect(firstIdentity == secondIdentity)
    }

    @Test("a cancelled waiter returns promptly WITHOUT aborting the shared load for the other waiter")
    func cancelledWaiterReturnsPromptlyWithoutAbortingTheSharedLoad() async throws {
        let gate = Gate()
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 10) {
            await gate.wait()
        }

        let cancelledTask = Task {
            try await diarizer.resolvedManagerIdentity()
        }
        let survivingTask = Task {
            try await diarizer.resolvedManagerIdentity()
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

    @Test("a successful load is reused on the next call: one load, and the SAME instance both times")
    func successfulLoadIsCachedAcrossCalls() async throws {
        let loadCalls = CallCounter()
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 10) {
            await loadCalls.increment()
        }

        let first = try await diarizer.resolvedManagerIdentity()
        let second = try await diarizer.resolvedManagerIdentity()

        #expect(await loadCalls.count == 1)
        #expect(first == second)
    }

    @Test("a failed load is retried on the next call, not permanently poisoned")
    func failedLoadIsRetriedNotPoisoned() async throws {
        struct LoadFailure: Error {}
        let loadCalls = CallCounter()
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 10) {
            let attempt = await loadCalls.count
            await loadCalls.increment()
            if attempt == 0 { throw LoadFailure() }
        }

        await #expect(throws: LoadFailure.self) { try await diarizer.resolvedManagerIdentity() }
        try await diarizer.resolvedManagerIdentity()

        // A load that FAILS is not an abandoned load: it reported back, so the circuit breaker
        // never opens and the retry is immediate.
        #expect(await loadCalls.count == 2)
    }

    // MARK: - Helpers

    /// Round 2's `runWithDeadline`, reproduced here with its structure unchanged, purely so the
    /// control above can attack it: one child running the real load, one child sleeping the
    /// deadline, `group.next()`, `group.cancelAll()`, return. `withTaskGroup` is structured --
    /// leaving the group awaits EVERY child -- so `cancelAll()` bounds nothing a child chooses to
    /// ignore, which is the whole defect.
    ///
    /// The element type is `Result<Void, Error>` rather than round 2's
    /// `Result<DiarizerManager, Error>`; round 2 could write the latter only because it also
    /// shipped `extension DiarizerManager: @unchecked Sendable {}`, which B3 removed. The
    /// structural property under attack -- that leaving the group awaits the loader child -- is
    /// identical either way.
    private static func roundTwoRunWithDeadline(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Void
    ) async -> Result<Void, Error> {
        await withTaskGroup(of: Result<Void, Error>.self) { group in
            group.addTask {
                do {
                    return .success(try await operation())
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(timeoutSeconds, 0) * 1_000_000_000))
                return .failure(FluidAudioMeetingDiarizerError.loadTimedOut)
            }
            let first = await group.next() ?? .failure(FluidAudioMeetingDiarizerError.loadDidNotProduceManager)
            group.cancelAll()
            return first
        }
    }

    private func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(5),
        _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("timed out waiting for: \(what)")
    }

    private actor CallCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }
}

/// A load step that is genuinely BLIND to cooperative cancellation -- the whole point of this
/// fixture, and the thing round 2's `Task.sleep` loader was not.
///
/// Nothing in this path checks `Task.isCancelled` and nothing in it can throw `CancellationError`.
/// `withCheckedContinuation` has no cancellation semantics whatsoever: a cancelled task parked on
/// one stays parked. The only thing that can resume it is `release()`, called by the test. The
/// blocking wait itself runs on a detached OS thread (`Thread.detachNewThread` +
/// `DispatchSemaphore.wait()`, a kernel wait `Task.cancel()` cannot interrupt), so the
/// cooperative thread pool is never blocked -- the load genuinely keeps running after
/// cancellation instead of merely appearing to.
///
/// `observedCancellationOnFinish` closes the loop: when it finally does return, it records
/// whether cancellation had been delivered to its task. `true` means the ceiling cancelled the
/// load, the load ignored it, and the caller had already been let go anyway.
private final class CancellationBlindLoader: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _startCount = 0
    private var _finishCount = 0
    private var _observedCancellationOnFinish: Bool?

    var startCount: Int { lock.withLock { _startCount } }
    var finishCount: Int { lock.withLock { _finishCount } }
    var observedCancellationOnFinish: Bool? { lock.withLock { _observedCancellationOnFinish } }
    var isStillRunning: Bool { lock.withLock { _startCount > _finishCount } }

    func run() async throws {
        lock.withLock { _startCount += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = self.gate
            Thread.detachNewThread {
                gate.wait()
                continuation.resume()
            }
        }
        let wasCancelled = Task.isCancelled
        lock.withLock {
            _finishCount += 1
            _observedCancellationOnFinish = wasCancelled
        }
    }

    /// Releases exactly one parked `run()` call.
    func release() { gate.signal() }
}

/// Test-only, and it exists to be DEFEATED: `injectedLoadStepCannotSupplyTheManagerTheActorResolves`
/// uses it to retain a manager across the `@Sendable` load-step boundary and then proves the
/// actor did not adopt it. Production code cannot do the equivalent, because the load step's
/// return type has nowhere to put a manager.
private final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
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

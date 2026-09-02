// New for this fork (Stage 2c fix round 3, cross-vendor review finding B2). Not a port.
//
// WHY THIS FILE WAS REWRITTEN. Round 2's ceiling test looked like a proof and was not one. It
// injected a loader whose body was `try await Task.sleep(nanoseconds: 60 * 1_000_000_000)` with
// a comment claiming it "never checks cancellation", raced it against a 0.2s deadline, and
// reported the caller returning in 0.214s. Those numbers were real. The property they
// demonstrated was the wrong one: `Task.sleep` IS cancellation-aware, so the moment
// `group.cancelAll()` ran it threw `CancellationError` and the "60s" loader was finished --
// which is precisely why the enclosing `withTaskGroup` (structured: it cannot return until every
// child completes) was able to return at all. The test proved cooperative cancellation works. It
// could not have failed even if the ceiling were entirely fictional, which it was.
//
// The fixture that binds is `CancellationBlindLoader` below: nothing in its path checks
// `Task.isCancelled`, nothing in it can throw `CancellationError`, and the only thing that can
// ever complete it is the test calling `release()`. The ceiling test now asserts not just that
// the caller returned on time, but that at the moment it returned the loader had NOT finished --
// the assertion whose absence made round 2's evidence non-binding.

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
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 0.2) { try await loader.load() }

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

    @Test("after the ceiling fires, the next attempt starts a FRESH load rather than joining the abandoned one")
    func afterTheCeilingFiresTheNextAttemptStartsAFreshLoad() async throws {
        let loader = CancellationBlindLoader()
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 0.2) { try await loader.load() }

        await #expect(throws: FluidAudioMeetingDiarizerError.loadTimedOut) {
            try await diarizer.resolvedManagerIdentity()
        }
        #expect(loader.startCount == 1)

        await #expect(throws: FluidAudioMeetingDiarizerError.loadTimedOut) {
            try await diarizer.resolvedManagerIdentity()
        }
        // 2, not 1: the second call did not attach itself to the load the first call gave up on.
        #expect(loader.startCount == 2)
        #expect(loader.finishCount == 0)

        loader.release()
        loader.release()
        try await waitUntil("both abandoned loads drain") { loader.finishCount == 2 }
    }

    @Test("a late result from an abandoned load is quarantined and never becomes the resolved manager")
    func lateResultFromAnAbandonedLoadIsQuarantined() async throws {
        let blind = CancellationBlindLoader()
        let replacement = UncheckedBox(DiarizerManager(config: .default))
        let attempts = AttemptCounter()

        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 0.2) {
            // Attempt 1 hangs blind until the test releases it; every later attempt resolves
            // instantly to a DIFFERENT manager, so "which instance won" is observable.
            attempts.next() == 1 ? try await blind.load() : replacement.value
        }

        await #expect(throws: FluidAudioMeetingDiarizerError.loadTimedOut) {
            try await diarizer.resolvedManagerIdentity()
        }
        let afterTimeout = try await diarizer.resolvedManagerIdentity()
        #expect(afterTimeout == ObjectIdentifier(replacement.value))

        // Now let the abandoned generation-1 load finish, late. Its result must be dropped: it
        // is reported against a load id the actor has already moved past.
        blind.release()
        try await waitUntil("the abandoned load finishes late") { blind.finishCount == 1 }

        let afterLateArrival = try await diarizer.resolvedManagerIdentity()
        #expect(afterLateArrival == ObjectIdentifier(replacement.value))
        #expect(afterLateArrival == afterTimeout)
    }

    @Test("CONTROL: round 2's withTaskGroup ceiling does NOT bound the same blind loader")
    func roundTwoStructuredCeilingDoesNotBoundABlindLoader() async throws {
        // A test that passes proves nothing unless it could have failed. Round 2's ceiling test
        // passed and the ceiling was fictional, so this control closes that hole from the other
        // side: it runs the SAME cancellation-blind loader against round 2's EXACT racing shape,
        // reproduced below, and asserts that shape does not come back.
        //
        // Without this, `hungCancellationBlindLoadIsBoundedByTheCeiling` passing could still mean
        // the fixture is simply easy. With it, the fixture is shown to defeat the old design and
        // be survived by the new one -- which is the only thing that makes the new one's pass
        // meaningful.
        let loader = CancellationBlindLoader()
        let returned = FlagBox()

        let raced = Task {
            _ = await Self.roundTwoRunWithDeadline(timeoutSeconds: 0.2) { try await loader.load() }
            returned.set()
        }

        // 2s: ten times the 0.2s deadline round 2 claimed to enforce, and ~3x the wall clock the
        // new design's equivalent test takes end to end.
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

    /// Round 2's `runWithDeadline`, reproduced here with its structure unchanged, purely so the
    /// control above can attack it: one child running the real load, one child sleeping the
    /// deadline, `group.next()`, `group.cancelAll()`, return. `withTaskGroup` is structured --
    /// leaving the group awaits EVERY child -- so `cancelAll()` bounds nothing a child chooses to
    /// ignore, which is the whole defect.
    ///
    /// One deliberate difference from the shipped original: the group's element type is
    /// `Result<ObjectIdentifier, Error>` rather than `Result<DiarizerManager, Error>`. Round 2
    /// could write the latter only because it also shipped `extension DiarizerManager: @unchecked
    /// Sendable {}`, which B3 removed; `TaskGroup` requires a `Sendable` element. The structural
    /// property under attack -- that leaving the group awaits the loader child -- is identical
    /// either way.
    private static func roundTwoRunWithDeadline(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> DiarizerManager
    ) async -> Result<ObjectIdentifier, Error> {
        await withTaskGroup(of: Result<ObjectIdentifier, Error>.self) { group in
            group.addTask {
                do {
                    return .success(ObjectIdentifier(try await operation()))
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

    // MARK: - Shared-load and waiter-cancellation properties (carried over, still required)

    @Test("two concurrent callers share ONE load -- the loader runs exactly once")
    func sharedLoadIsJoinedNotDuplicated() async throws {
        let loadCalls = CallCounter()
        let gate = Gate()
        let diarizer = FluidAudioMeetingDiarizer(loadOperationTimeout: 10) {
            await loadCalls.increment()
            await gate.wait()
            return DiarizerManager(config: .default)
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
            return DiarizerManager(config: .default)
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
            return DiarizerManager(config: .default)
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
            return DiarizerManager(config: .default)
        }

        await #expect(throws: LoadFailure.self) { try await diarizer.resolvedManagerIdentity() }
        try await diarizer.resolvedManagerIdentity()

        #expect(await loadCalls.count == 2)
    }

    // MARK: - Helpers

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

/// A loader that is genuinely BLIND to cooperative cancellation -- the whole point of this
/// fixture, and the thing round 2's `Task.sleep` loader was not.
///
/// Nothing in this path checks `Task.isCancelled` and nothing in it can throw `CancellationError`.
/// `withCheckedContinuation` has no cancellation semantics whatsoever: a cancelled task parked on
/// one stays parked. The only thing that can resume it is `release()`, called by the test. The
/// blocking wait itself runs on a detached OS thread (`Thread.detachNewThread` +
/// `DispatchSemaphore.wait()`, a kernel wait `Task.cancel()` cannot interrupt), so the
/// cooperative thread pool is never blocked -- the loader genuinely keeps running after
/// cancellation instead of merely appearing to.
///
/// `observedCancellationOnFinish` closes the loop: when the loader finally does return, it
/// records whether cancellation had been delivered to its task. `true` means the ceiling
/// cancelled the load, the load ignored it, and the caller had already been let go anyway.
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

    func load() async throws -> DiarizerManager {
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
        return DiarizerManager(config: .default)
    }

    /// Releases exactly one parked `load()` call.
    func release() { gate.signal() }
}

/// Lets a test share one non-`Sendable` `DiarizerManager` with a `@Sendable` loader closure.
/// Test-only, and narrower than what it replaces: round 2 shipped
/// `extension DiarizerManager: @unchecked Sendable {}` in PRODUCTION code, which promised the
/// whole target that FluidAudio's mutable class was safe to share.
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

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
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

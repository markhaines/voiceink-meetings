// Fork-owned (no donor equivalent). Not a port.
//
// Batch speaker diarization for `MeetingTranscriptionCoordinator.diarizeSystemAudio(at:)`, using
// FluidAudio's own `DiarizerManager` directly. `ADAPTER-HANDOVER.md` §5 requires
// `DiarizerRuntimePolicy.resolve(for:)` be called once and its `.modelConfiguration` applied
// whenever a `DiarizerManager`'s models are loaded (the M1/macOS-15.1 GPU-avoidance workaround,
// FluidAudio issue #344) -- the default `loadManager` closure below is that one call site.
//
// FIX ROUND 3 (cross-vendor review, B2 and B3). Two earlier designs were defeated here:
//
//   * Round 1 joined an in-flight load with no operation ceiling at all. `diarizeSystemAudio` is
//     awaited from `MeetingEngine.stop()`, so a hung CoreML load hung meeting completion
//     indefinitely: Mark ends a 90-minute meeting and the app never finishes it.
//   * Round 2 added a ceiling built out of `withTaskGroup`, racing the loader against a timeout
//     child and calling `group.cancelAll()` when the timeout won. Review found that this is not
//     a ceiling at all. `withTaskGroup` is STRUCTURED concurrency: the group cannot return until
//     every child task has finished, so leaving the group still awaits the loader. Against a
//     loader that ignores cooperative cancellation -- which is the only failure mode the ceiling
//     exists for -- the caller waited exactly as long as it would have with no ceiling. Round 2's
//     own test appeared to prove otherwise (a "60s" loader finishing in 0.214s against a 0.2s
//     deadline) because its loader was `try await Task.sleep`, which IS cancellation-aware and
//     threw the instant `cancelAll()` ran. Real numbers, wrong property: it proved cooperative
//     cancellation, not a ceiling.
//
// Round 3 makes the ceiling structural. The load runs in an UNSTRUCTURED `Task` that nothing
// ever awaits, and the deadline is a SEPARATE unstructured `Task` that expires on its own clock.
// Waiters are resumed by whichever of the two fires first, and neither one awaits the other, so
// a caller's return time is bounded by the deadline task alone -- independently of whether the
// loader can be cancelled, or ever finishes:
//
//   1. Shared load: a second concurrent caller joins the SAME in-flight load (`activeLoadID`),
//      never starting a second one.
//   2. Hard operation deadline (`loadOperationTimeout`, default 30s). `expireLoad` resumes every
//      waiter with `.loadTimedOut` and returns. It cancels the load task best-effort and then
//      forgets it; it never awaits it. A cancellation-BLIND loader is bounded by this, which is
//      the property `FluidAudioMeetingDiarizerTests.hungCancellationBlindLoadIsBoundedByTheCeiling`
//      proves with a loader that blocks on a `DispatchSemaphore` on a detached thread and cannot
//      be interrupted by `Task.cancel()` at all.
//   3. Quarantine by load ID: an abandoned load that eventually DOES finish calls `finishLoad`
//      with its own id, sees it is no longer `activeLoadID`, and drops its result on the floor.
//      It can never install a manager into a generation that already gave up on it. The abandoned
//      `DiarizerManager` (if one is ever produced) is simply released.
//   4. Fresh load, never a dead one: `expireLoad` clears `activeLoadID`, so the NEXT
//      `diarize`/`resolvedManagerIdentity` starts a brand-new load with a new id rather than
//      joining the abandoned one. Same for a failed load -- "a failed diarization is recoverable"
//      (audio and segments are already persisted by the time this runs at `stop()`).
//   5. Prompt waiter cancellation: a caller whose own Task is cancelled while joining returns
//      immediately with `CancellationError` via `cancelWaiter`, WITHOUT touching the shared load
//      or any other waiter.
//
// B3: round 2 wrote `extension DiarizerManager: @unchecked Sendable {}`. Review was right that
// this is a MODULE-WIDE promise about a third-party mutable class that every future FluidAudio
// bump would silently inherit, regardless of what the comment above it said. It is gone. The
// only `@unchecked` conformance left is `LoadedDiarizerBox` below: a `private`, single-field
// wrapper whose entire justification is one hop, from the load task into this actor. Nothing
// outside this actor is ever handed a `DiarizerManager` -- not even the test seam, which returns
// an `ObjectIdentifier` (a `Sendable` value type) rather than the manager itself.

import FluidAudio
import Foundation

/// Carries a `DiarizerManager` across exactly one isolation hop: from the unstructured load task
/// into `FluidAudioMeetingDiarizer.finishLoad(id:_:)`, which stores it in actor-isolated state
/// and never lets it out again.
///
/// `private` on purpose. The `@unchecked` promise is scoped to THIS box and its two use sites in
/// this file, not to `DiarizerManager`, so it cannot be inherited by any other code in the target
/// and a future FluidAudio version cannot quietly acquire it. The promise itself is true by
/// construction: the box is created inside the load task, immediately consumed by the actor, and
/// the manager it carries is reachable from nowhere else at that moment (the load task's own
/// reference goes out of scope on the next line).
private struct LoadedDiarizerBox: @unchecked Sendable {
    let manager: DiarizerManager
}

enum FluidAudioMeetingDiarizerError: Error, Equatable {
    case loadTimedOut
    case loadDidNotProduceManager
}

actor FluidAudioMeetingDiarizer: MeetingSystemAudioDiarizing {
    private let audioConverter = AudioConverter()
    private let loadOperationTimeout: TimeInterval
    private let loadManager: @Sendable () async throws -> DiarizerManager

    private var loadedManager: DiarizerManager?
    /// Identifies the load generation waiters are currently attached to. `nil` means no load is
    /// in flight -- including immediately after `expireLoad` gave up on one that is still
    /// running, which is what makes the next attempt a fresh load rather than a join.
    private var activeLoadID: UUID?
    private var loadTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(
        config: DiarizerConfig = .default,
        modelsDirectory: URL? = nil,
        loadOperationTimeout: TimeInterval = 30
    ) {
        self.loadOperationTimeout = loadOperationTimeout
        self.loadManager = {
            let directory = modelsDirectory ?? DiarizerModels.defaultModelsDirectory()
            let policy = DiarizerRuntimePolicy.resolve(for: .current())
            let models = try await DiarizerModels.load(
                from: directory,
                configuration: policy.modelConfiguration
            )
            let manager = DiarizerManager(config: config)
            manager.initialize(models: models)
            return manager
        }
    }

    /// Test-only seam: injects the loader directly so a hang (or any other outcome) can be
    /// simulated deterministically without real CoreML models -- production code always uses
    /// the initializer above. See `FluidAudioMeetingDiarizerTests.swift`.
    init(loadOperationTimeout: TimeInterval, loadManager: @escaping @Sendable () async throws -> DiarizerManager) {
        self.loadOperationTimeout = loadOperationTimeout
        self.loadManager = loadManager
    }

    func diarize(fileAt url: URL) async throws -> DiarizationResult? {
        let manager = try await resolvedManager()
        let samples = try audioConverter.resampleAudioFile(url)
        return try manager.performCompleteDiarization(samples)
    }

    /// Test seam for the shared-load/deadline/quarantine state machine, so it can be exercised
    /// without `diarize(fileAt:)`'s real file I/O (which would need an actual audio file on disk,
    /// unrelated to what those tests prove).
    ///
    /// It returns the loaded manager's OBJECT IDENTITY, never the manager. That is not a
    /// stylistic choice: it is what lets B3's fix hold. `ObjectIdentifier` is a `Sendable` value,
    /// so this seam widens the actor's exclusive ownership of `DiarizerManager` by exactly
    /// nothing, while still letting a test assert that two calls resolved the SAME instance.
    @discardableResult
    func resolvedManagerIdentity() async throws -> ObjectIdentifier {
        ObjectIdentifier(try await resolvedManager())
    }

    private func resolvedManager() async throws -> DiarizerManager {
        if let loadedManager { return loadedManager }
        let generation = startLoadIfNeeded()
        try await join(generation: generation)
        if let loadedManager { return loadedManager }
        throw FluidAudioMeetingDiarizerError.loadDidNotProduceManager
    }

    /// Starts a load generation: one unstructured task for the load, one for its deadline.
    ///
    /// The two are deliberately siblings, not parent and child. Nothing in this actor ever awaits
    /// `loadTask`, so nothing in this actor can be delayed by it -- that is the whole of B2's fix.
    /// Both are `Task`, not `withTaskGroup`/`async let`, because both of those are structured and
    /// would reintroduce exactly the "cannot return until the child finishes" property that made
    /// round 2's ceiling fictional.
    private func startLoadIfNeeded() -> UUID {
        if let activeLoadID { return activeLoadID }
        let id = UUID()
        activeLoadID = id

        let loader = loadManager
        loadTask = Task { [weak self] in
            let outcome: Result<LoadedDiarizerBox, Error>
            do {
                outcome = .success(LoadedDiarizerBox(manager: try await loader()))
            } catch {
                outcome = .failure(error)
            }
            await self?.finishLoad(id: id, outcome)
        }

        let timeoutNanoseconds = UInt64(max(loadOperationTimeout, 0) * 1_000_000_000)
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            // Reached whether or not the sleep was cancelled: a cancelled sleep throws, `try?`
            // swallows it, and `expireLoad`'s own id guard makes the call a no-op if this
            // generation already finished. So a cancelled deadline can never expire a live load.
            await self?.expireLoad(id: id)
        }

        return id
    }

    /// Called by the load task when the loader finally returns -- which may be long after this
    /// generation was abandoned. The id guard is the quarantine: a late result from a load the
    /// actor already gave up on is dropped, never installed.
    private func finishLoad(id: UUID, _ outcome: Result<LoadedDiarizerBox, Error>) {
        guard activeLoadID == id else { return }
        activeLoadID = nil
        loadTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        switch outcome {
        case .success(let box):
            loadedManager = box.manager
            resumeAllWaiters(with: .success(()))
        case .failure(let error):
            resumeAllWaiters(with: .failure(error))
        }
    }

    /// The ceiling. Resumes every waiter and returns; it does NOT await the load task, so how
    /// long the loader takes -- or whether it ever stops -- has no bearing on when the caller of
    /// `diarize`/`resolvedManagerIdentity` gets control back.
    ///
    /// `loadTask?.cancel()` is honestly best-effort and is not what makes the bound hold: a stuck
    /// CoreML compile may ignore it entirely. It is here so a loader that DOES cooperate stops
    /// burning CPU, nothing more.
    private func expireLoad(id: UUID) {
        guard activeLoadID == id else { return }
        activeLoadID = nil
        loadTask?.cancel()
        loadTask = nil
        deadlineTask = nil
        resumeAllWaiters(with: .failure(FluidAudioMeetingDiarizerError.loadTimedOut))
    }

    /// Registers this call as a waiter on the in-flight load and suspends until either the load
    /// generation ends -- broadcast to every waiter by `finishLoad` or `expireLoad` -- or THIS
    /// call's own Task is cancelled, in which case `cancelWaiter` resumes just this continuation
    /// with `CancellationError` and removes it, WITHOUT touching the load or any other waiter.
    ///
    /// One residual, disclosed rather than papered over: a caller whose Task is ALREADY cancelled
    /// when it reaches here races `onCancel` against the registration below. If `onCancel` wins,
    /// `cancelWaiter` finds no entry and this call waits for the generation to end normally
    /// instead of returning immediately. That is a latency cost, not a hang -- and specifically
    /// not a hang BECAUSE of B2's fix: the generation is bounded by `expireLoad` regardless of
    /// what the loader does, so the worst case is one `loadOperationTimeout`, not forever. Left
    /// as is; closing it needs a pre-registration cancellation check whose own race is no simpler.
    private func join(generation: UUID) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard activeLoadID == generation else {
                    // The generation ended between `startLoadIfNeeded()` returning and this
                    // closure running. Not reachable today -- both run in one uninterrupted
                    // actor-isolated step, since `withCheckedThrowingContinuation` invokes its
                    // body synchronously -- but parking on a generation nobody will ever
                    // broadcast to is the one way this state machine could hang, so it is
                    // guarded rather than argued. Resume immediately and let `resolvedManager`
                    // re-read `loadedManager`: a generation that ended in success has already
                    // installed it, and one that ended any other way surfaces as
                    // `.loadDidNotProduceManager` instead of an indefinite wait.
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func resumeAllWaiters(with result: Result<Void, Error>) {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values {
            continuation.resume(with: result)
        }
    }
}

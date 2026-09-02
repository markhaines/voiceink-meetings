// Fork-owned (no donor equivalent). Not a port.
//
// Batch speaker diarization for `MeetingTranscriptionCoordinator.diarizeSystemAudio(at:)`, using
// FluidAudio's own `DiarizerManager` directly. `ADAPTER-HANDOVER.md` §5 requires
// `DiarizerRuntimePolicy.resolve(for:)` be called once and its `.modelConfiguration` applied
// whenever a `DiarizerManager`'s models are loaded (the M1/macOS-15.1 GPU-avoidance workaround,
// FluidAudio issue #344) -- the default `loadModels` closure below is that one call site.
//
// THE LOAD STATE MACHINE, and the three review rounds that shaped it:
//
//   * Round 1 joined an in-flight load with no ceiling. `diarizeSystemAudio` is awaited from
//     `MeetingEngine.stop()`, so a hung CoreML load hung meeting completion indefinitely: Mark
//     ends a 90-minute meeting and the app never finishes it.
//   * Round 2 built a ceiling out of `withTaskGroup` + `group.cancelAll()`. That is not a
//     ceiling: `withTaskGroup` is STRUCTURED, so leaving the group awaits the loader anyway. Its
//     test appeared to prove otherwise only because the injected loader was `Task.sleep`, which
//     IS cancellation-aware and threw the instant cancellation arrived. Real numbers, wrong
//     property.
//   * Round 3 replaced it with an UNSTRUCTURED load task and a separate, independently expiring
//     deadline task. That ceiling is real and is proved against a genuinely cancellation-blind
//     loader (`FluidAudioMeetingDiarizerTests.hungCancellationBlindLoadIsBoundedByTheCeiling`,
//     with `roundTwoStructuredCeilingDoesNotBoundABlindLoader` as its control).
//   * Round 4 fixed what round 3 under-disclosed (B4.3) and a seam it got wrong (B4.4). Both
//     below.
//
// Properties this actor holds:
//   1. Shared load: concurrent callers join the SAME in-flight generation (`activeLoadID`).
//   2. Hard operation deadline (`loadOperationTimeout`, default 30s). `expireLoad` resumes every
//      waiter and returns; it never awaits the loader, so a cancellation-BLIND load cannot make a
//      caller wait past the deadline.
//   3. Quarantine by load id: a late result from an abandoned generation is dropped, never
//      installed.
//   4. Circuit breaker (round 4, B4.3). Round 3 disclosed "one abandoned load alongside its
//      replacement", which understated it: a PERMANENTLY stuck load is abandoned and every later
//      `stop()` could start another, accumulating unbounded cancellation-blind CoreML loads. The
//      id guard prevents stale STATE, not stale RESOURCES. `maxOutstandingAbandonedLoads` (1)
//      now caps it: while an abandoned load has not returned, a new attempt fails FAST with
//      `.loadAbandonedAndStillOutstanding` instead of starting another. So at most two loads can
//      ever be in flight at once -- one live, one abandoned -- regardless of how many meetings
//      end. The breaker closes by itself when the abandoned load finally returns (including by
//      throwing, if it cooperates with cancellation); if it never returns, failing fast forever
//      is the correct outcome, not a regression.
//   5. Prompt waiter cancellation: a caller whose own Task is cancelled while joining returns
//      with `CancellationError` without touching the load or any other waiter.
//
// B4.4 -- WHO CAN SUPPLY A MANAGER. Round 3 said "nothing outside this actor is ever handed a
// `DiarizerManager`" and backed it with a `private` box. Review found the hole: the injectable
// initializer took `() async throws -> DiarizerManager`, so any same-module caller (not only a
// test) could construct a manager, RETAIN it, hand it in, and hold a second reference to
// something the actor then treated as exclusively its own. This is the third test-only seam on
// this project that turned out to be a real hole.
//
// The fix is the seam's TYPE, not a configuration gate. `#if DEBUG` would not have been
// sufficient -- the next integrator writes and runs code in Debug, which is exactly how the
// previous two seams leaked. Instead:
//   * The stored seam is `() async throws -> DiarizerModels?`.
//   * The production initializer supplies real `DiarizerModels`.
//   * The injectable initializer takes `() async throws -> Void` and always yields `nil` models.
//     Its parameter type cannot express "here is a manager", so a caller cannot supply one,
//     whatever their intent. `FluidAudioSharedModelAttacks.swift` asserts the old
//     manager-returning initializer no longer compiles.
//   * The actor constructs every `DiarizerManager` itself, inside `finishLoad`, from models it
//     was given. `DiarizerModels` is FluidAudio's own `public struct ... Sendable` whose
//     memberwise initializer is NOT public, so no code in this target can fabricate one either.
// Consequence: "the manager is reachable from nowhere else" is now true against the available
// API, not just against current call sites. `injectedLoadStepCannotSupplyTheManagerTheActorResolves`
// pins it at runtime as well.
//
// B3 (round 3, still holds): there is no `extension DiarizerManager: @unchecked Sendable {}` --
// that was a module-wide promise about a third-party mutable class that every future FluidAudio
// bump would inherit. Round 3 replaced it with a private box; round 4's redesign removes even
// that, because `DiarizerModels` is already `Sendable` and the manager is never carried across an
// isolation boundary at all. There is no `@unchecked` conformance left in this file.

import FluidAudio
import Foundation

enum FluidAudioMeetingDiarizerError: Error, Equatable {
    case loadTimedOut
    case loadDidNotProduceManager
    /// The circuit breaker (B4.3): a previous load blew its deadline and has still not returned,
    /// so this attempt refused to start another rather than accumulate stuck CoreML loads.
    case loadAbandonedAndStillOutstanding
}

actor FluidAudioMeetingDiarizer: MeetingSystemAudioDiarizing {
    /// At most one abandoned (deadline-blown, not yet returned) load may be outstanding. One,
    /// not a larger number: the failure this bounds is a permanently stuck native load, and a
    /// second one has never been shown to help where the first did not.
    private static let maxOutstandingAbandonedLoads = 1

    private let audioConverter = AudioConverter()
    private let config: DiarizerConfig
    private let loadOperationTimeout: TimeInterval
    /// Returns the models a new `DiarizerManager` should be initialized with, or `nil` for the
    /// injectable initializer's model-free manager. It CANNOT return a manager: see B4.4 above.
    private let loadModels: @Sendable () async throws -> DiarizerModels?

    private var loadedManager: DiarizerManager?
    /// Identifies the load generation waiters are currently attached to. `nil` means no load is
    /// in flight -- including immediately after `expireLoad` gave up on one that is still
    /// running, which is what makes the next attempt a fresh load rather than a join.
    private var activeLoadID: UUID?
    private var loadTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Generations whose deadline fired and whose loader has not reported back yet. Drives the
    /// circuit breaker.
    private var outstandingAbandonedLoads = 0

    init(
        config: DiarizerConfig = .default,
        modelsDirectory: URL? = nil,
        loadOperationTimeout: TimeInterval = 30
    ) {
        self.config = config
        self.loadOperationTimeout = loadOperationTimeout
        self.loadModels = {
            let directory = modelsDirectory ?? DiarizerModels.defaultModelsDirectory()
            let policy = DiarizerRuntimePolicy.resolve(for: .current())
            return try await DiarizerModels.load(
                from: directory,
                configuration: policy.modelConfiguration
            )
        }
    }

    /// Injectable seam for exercising the load state machine deterministically without real
    /// CoreML models. `loadStep` decides only WHEN (and whether) a load generation completes --
    /// hang, throw, succeed. It cannot decide WHAT manager results, because its type has no way
    /// to carry one; the actor always constructs that itself. That is the whole of B4.4's fix,
    /// and it is why this initializer being `internal` rather than gated behind `#if DEBUG` is
    /// safe: a production-module caller gains no capability a test has.
    ///
    /// The manager it produces has no models loaded, so it must not be used for inference. That
    /// is a property of the seam's own contract, not a rule anyone has to remember: `nil` models
    /// are reachable only through this initializer, and `DiarizerModels`' memberwise initializer
    /// is not public, so no caller in this target can supply real ones through it.
    init(
        loadOperationTimeout: TimeInterval,
        config: DiarizerConfig = .default,
        loadStep: @escaping @Sendable () async throws -> Void
    ) {
        self.config = config
        self.loadOperationTimeout = loadOperationTimeout
        self.loadModels = {
            try await loadStep()
            return nil
        }
    }

    func diarize(fileAt url: URL) async throws -> DiarizationResult? {
        let manager = try await resolvedManager()
        let samples = try audioConverter.resampleAudioFile(url)
        return try manager.performCompleteDiarization(samples)
    }

    /// Test seam for the shared-load/deadline/quarantine/breaker state machine, so it can be
    /// exercised without `diarize(fileAt:)`'s real file I/O (which would need an actual audio
    /// file on disk, unrelated to what those tests prove).
    ///
    /// It returns the loaded manager's OBJECT IDENTITY, never the manager. `ObjectIdentifier` is
    /// a `Sendable` value, so this seam widens the actor's exclusive ownership by exactly
    /// nothing, while still letting a test assert that two calls resolved the SAME instance -- or,
    /// for B4.4, that a manager an injected closure constructed is NOT the one resolved.
    @discardableResult
    func resolvedManagerIdentity() async throws -> ObjectIdentifier {
        ObjectIdentifier(try await resolvedManager())
    }

    private func resolvedManager() async throws -> DiarizerManager {
        if let loadedManager { return loadedManager }
        let generation = try startLoadIfNeeded()
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
    ///
    /// Throws rather than starting anything when the circuit breaker is open (B4.3). That throw
    /// happens before either task is created, so a refused attempt costs nothing and returns
    /// immediately -- it does not wait out another deadline.
    private func startLoadIfNeeded() throws -> UUID {
        if let activeLoadID { return activeLoadID }
        guard outstandingAbandonedLoads < Self.maxOutstandingAbandonedLoads else {
            throw FluidAudioMeetingDiarizerError.loadAbandonedAndStillOutstanding
        }
        let id = UUID()
        activeLoadID = id

        let load = loadModels
        let managerConfig = config
        loadTask = Task { [weak self] in
            let outcome: Result<DiarizerManager, Error>
            do {
                // Constructed HERE, from models, never supplied by a caller (B4.4). This is the
                // only `DiarizerManager` construction site outside the actor's own state, and the
                // reference does not outlive this statement: `finishLoad` takes ownership.
                let models = try await load()
                let manager = DiarizerManager(config: managerConfig)
                if let models { manager.initialize(models: models) }
                outcome = .success(manager)
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
    /// actor already gave up on is dropped, never installed. It ALSO closes the circuit breaker
    /// for that generation, which is the only way `outstandingAbandonedLoads` ever comes back
    /// down: a load that never returns keeps the breaker open, which is the intended behaviour.
    private func finishLoad(id: UUID, _ outcome: Result<DiarizerManager, Error>) {
        guard activeLoadID == id else {
            outstandingAbandonedLoads = max(outstandingAbandonedLoads - 1, 0)
            return
        }
        activeLoadID = nil
        loadTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        switch outcome {
        case .success(let manager):
            loadedManager = manager
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
    /// burning CPU, nothing more. Because it may be ignored, the generation is counted as
    /// outstanding until it actually reports back -- that count is the circuit breaker.
    private func expireLoad(id: UUID) {
        guard activeLoadID == id else { return }
        activeLoadID = nil
        outstandingAbandonedLoads += 1
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

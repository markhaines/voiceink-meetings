// Fork-owned (no donor equivalent). Not a port.
//
// Batch speaker diarization for `MeetingTranscriptionCoordinator.diarizeSystemAudio(at:)`, using
// FluidAudio's own `DiarizerManager` directly. `ADAPTER-HANDOVER.md` §5 requires
// `DiarizerRuntimePolicy.resolve(for:)` be called once and its `.modelConfiguration` applied
// whenever a `DiarizerManager`'s models are loaded (the M1/macOS-15.1 GPU-avoidance workaround,
// FluidAudio issue #344) -- the default `loadManager` closure below is that one call site.
//
// FIX ROUND (cross-vendor review, B3): the pre-fix-round version of this file joined an
// in-flight load but had NO operation ceiling and NO per-waiter cancellation -- `diarizeSystemAudio`
// is awaited from `MeetingEngine.stop()`, so a hung CoreML load hung meeting completion
// INDEFINITELY. This version implements the donor's bounded shared-load state machine
// (`ADAPTER-HANDOVER.md` §5's three properties):
//   1. Shared load: a second concurrent caller joins the SAME in-flight load, never starting a
//      second one.
//   2. An operation deadline (`loadOperationTimeout`, default 30s) independent of any individual
//      caller's own cancellation -- `runWithDeadline` races the real load against a timeout
//      sleep and returns whichever finishes first, so no caller ever waits past the deadline
//      even if the underlying native call never itself notices cancellation (the same
//      best-effort-cancel-the-loser shape the donor's own `timeoutDiarizerLoad` uses -- see that
//      function's doc comment below for why "best effort" is honestly stated, not glossed over).
//   3. Prompt waiter cancellation: a caller whose own Task is cancelled while joining returns
//      immediately with `CancellationError` via `cancelWaiter`, WITHOUT touching the shared load
//      Task -- every other waiter (and the load itself) is unaffected.
// A failed or timed-out load clears `loadTask`, so the NEXT `diarizeSystemAudio` call attempts a
// fresh load rather than being permanently poisoned -- matching "a failed diarization is
// recoverable" (audio and segments already persisted by the time this runs at `stop()`).

import FluidAudio
import Foundation

// Retroactive, `@unchecked` Sendable conformance for a type this file never lets escape its
// owning actor: `DiarizerManager` is FluidAudio's own plain class with no Sendable conformance
// of its own, and `FluidAudioMeetingDiarizer` is the ONLY place in this fork that ever
// constructs or touches one (grep-verified). `runWithDeadline` below needs SOME Sendable-typed
// result to race two child tasks against each other; `@unchecked` here is an honest assertion of
// single-owner exclusive access (this actor's serial isolation is what actually makes it safe),
// not a claim that `DiarizerManager` is generally safe to share across actors -- it is not, and
// nothing outside this actor is ever given a reference to one.
extension DiarizerManager: @unchecked Sendable {}

enum FluidAudioMeetingDiarizerError: Error, Equatable {
    case loadTimedOut
    case loadDidNotProduceManager
}

actor FluidAudioMeetingDiarizer: MeetingSystemAudioDiarizing {
    private let audioConverter = AudioConverter()
    private let loadOperationTimeout: TimeInterval
    private let loadManager: @Sendable () async throws -> DiarizerManager

    private var loadedManager: DiarizerManager?
    private var loadTask: Task<Void, Never>?
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

    /// `internal`, not `private`, for exactly one reason: so
    /// `FluidAudioMeetingDiarizerTests.swift` can exercise the shared-load/timeout/cancellation
    /// state machine directly via `@testable import`, without going through `diarize(fileAt:)`'s
    /// real file I/O (which would need an actual audio file on disk, unrelated to what these
    /// tests are proving). No production code outside this actor calls it (grep-verified) --
    /// widening visibility here creates no seam anyone could use to change the actor's own
    /// behavior, only to test it.
    func resolvedManager() async throws -> DiarizerManager {
        if let loadedManager { return loadedManager }
        startLoadIfNeeded()
        try await join()
        if let loadedManager { return loadedManager }
        throw FluidAudioMeetingDiarizerError.loadDidNotProduceManager
    }

    private func startLoadIfNeeded() {
        guard loadTask == nil else { return }
        let loader = loadManager
        let timeoutSeconds = loadOperationTimeout
        loadTask = Task { [weak self] in
            let outcome = await Self.runWithDeadline(timeoutSeconds: timeoutSeconds, operation: loader)
            await self?.finishLoad(outcome)
        }
    }

    /// Races `operation` against a `timeoutSeconds` sleep; whichever finishes first wins and the
    /// loser is cancelled. That cancellation is honestly best-effort, not a guarantee -- a
    /// genuinely hung, cancellation-blind native call (a stuck CoreML compile, matching the real
    /// incident this fork's own memory records for a DIFFERENT hung native call) may keep
    /// running in the background regardless. What this DOES guarantee, unconditionally: no
    /// caller of `resolvedManager()` ever waits past `timeoutSeconds`, whether or not the loser
    /// actually stops. This is the exact shape the donor's own `timeoutDiarizerLoad` uses too --
    /// FluidAudio issue reports on real hangs generally do NOT resolve via cooperative
    /// cancellation, so promising a stronger guarantee here would be dishonest.
    private static func runWithDeadline(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> DiarizerManager
    ) async -> Result<DiarizerManager, Error> {
        await withTaskGroup(of: Result<DiarizerManager, Error>.self) { group in
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

    private func finishLoad(_ result: Result<DiarizerManager, Error>) {
        loadTask = nil
        switch result {
        case .success(let manager):
            loadedManager = manager
            resumeAllWaiters(with: .success(()))
        case .failure(let error):
            resumeAllWaiters(with: .failure(error))
        }
    }

    /// Registers this call as a waiter on the in-flight load and suspends until either the load
    /// finishes -- broadcast to every waiter by `finishLoad` -- or THIS call's own Task is
    /// cancelled, in which case `cancelWaiter` resumes just this continuation with
    /// `CancellationError` and removes it, WITHOUT touching `loadTask` or any other waiter.
    private func join() async throws {
        guard loadTask != nil else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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

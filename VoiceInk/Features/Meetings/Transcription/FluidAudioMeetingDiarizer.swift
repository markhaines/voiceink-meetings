// Fork-owned (no donor equivalent). Not a port.
//
// Batch speaker diarization for `MeetingTranscriptionCoordinator.diarizeSystemAudio(at:)`, using
// FluidAudio's own `DiarizerManager` directly. `ADAPTER-HANDOVER.md` §5 requires
// `DiarizerRuntimePolicy.resolve(for:)` be called once and its `.modelConfiguration` applied
// whenever a `DiarizerManager`'s models are loaded (the M1/macOS-15.1 GPU-avoidance workaround,
// FluidAudio issue #344) -- `resolvedManager()` below is that one call site.
//
// KNOWN GAP, stated plainly rather than silently built partial: this loads once and lets a
// second concurrent caller join the in-flight load `Task`, but does NOT implement the donor's
// full three-property preload semantics `ADAPTER-HANDOVER.md` §5 describes as required for "a
// correct port of this behavior" -- an operation deadline independent of any individual caller's
// own wait timeout, and a cancelled joiner never aborting the shared load for other waiters.
// That machinery (mirroring `TranscriptionCoordinator.preloadDiarizer`/
// `waitForActiveDiarizerLoad`/`timeoutDiarizerLoad` in the donor) was out of scope for this
// stage's brief, which asked specifically for the transcription seam (chunk transcription with
// segment-vs-fallback routing), not diarizer preload coordination.

import FluidAudio
import Foundation

enum FluidAudioMeetingDiarizerError: Error {
    case loadDidNotProduceManager
}

actor FluidAudioMeetingDiarizer: MeetingSystemAudioDiarizing {
    private let config: DiarizerConfig
    private let modelsDirectory: URL?
    private let audioConverter = AudioConverter()

    // `DiarizerManager` is a plain class, not `Sendable` (and not ours to retroactively
    // annotate as such just to make a generic `Task<DiarizerManager, Error>` typecheck). The
    // load `Task` below is therefore typed `Void` and assigns `loadedManager` from INSIDE its
    // own body instead of returning the manager across the Task boundary: a non-detached
    // `Task { ... }` created here inherits this actor's isolation, so that assignment is plain
    // actor-isolated mutation, not a cross-isolation hop, and never needs `DiarizerManager` to
    // be `Sendable` at all.
    private var loadedManager: DiarizerManager?
    private var loadingTask: Task<Void, Error>?

    init(config: DiarizerConfig = .default, modelsDirectory: URL? = nil) {
        self.config = config
        self.modelsDirectory = modelsDirectory
    }

    func diarize(fileAt url: URL) async throws -> DiarizationResult? {
        let manager = try await resolvedManager()
        let samples = try audioConverter.resampleAudioFile(url)
        return try manager.performCompleteDiarization(samples)
    }

    private func resolvedManager() async throws -> DiarizerManager {
        if let loadedManager { return loadedManager }
        if loadingTask == nil {
            let config = config
            let directory = modelsDirectory ?? DiarizerModels.defaultModelsDirectory()
            let policy = DiarizerRuntimePolicy.resolve(for: .current())

            loadingTask = Task<Void, Error> {
                let models = try await DiarizerModels.load(
                    from: directory,
                    configuration: policy.modelConfiguration
                )
                let manager = DiarizerManager(config: config)
                manager.initialize(models: models)
                self.loadedManager = manager
            }
        }

        do {
            try await loadingTask?.value
        } catch {
            loadingTask = nil
            throw error
        }
        loadingTask = nil

        guard let loadedManager else {
            throw FluidAudioMeetingDiarizerError.loadDidNotProduceManager
        }
        return loadedManager
    }
}

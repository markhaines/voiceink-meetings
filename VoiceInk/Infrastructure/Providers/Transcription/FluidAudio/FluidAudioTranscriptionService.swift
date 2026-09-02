import FluidAudio
import Foundation
import os.log

class FluidAudioTranscriptionService: TranscriptionService {
    private var asrManager: AsrManager?
    private var unifiedAsrManager: UnifiedAsrManager?
    private var nemotronAsrManager: StreamingNemotronMultilingualAsrManager?
    private var activeVersion: AsrModelVersion?
    private var activeNemotronModelName: String?
    private var cachedModels: AsrModels?
    private var loadingTask: (version: AsrModelVersion, task: Task<AsrModels, Error>)?
    private let audioConverter = AudioConverter()
    private let logger = Logger(subsystem: "com.hainesy.voiceinkmeetings", category: "FluidAudioTranscriptionService")

    private func version(for model: any TranscriptionModel) -> AsrModelVersion {
        FluidAudioModelManager.asrVersion(for: model.name)
    }

    static func languageHint(from selectedLanguage: String?, model: any TranscriptionModel) -> Language? {
        guard model.provider == .fluidAudio else {
            return nil
        }
        return FluidAudioModelManager.languageHint(from: selectedLanguage, for: model.name)
    }

    private func cleanupLoadedManagers() async {
        await unifiedAsrManager?.cleanup()
        await nemotronAsrManager?.cleanup()
        await asrManager?.cleanup()

        unifiedAsrManager = nil
        nemotronAsrManager = nil
        asrManager = nil
        activeVersion = nil
        activeNemotronModelName = nil
    }

    private func ensureModelsLoaded(for version: AsrModelVersion) async throws {
        if asrManager != nil, activeVersion == version {
            return
        }

        // Clean up existing manager but preserve cachedModels for reuse
        await cleanupLoadedManagers()

        let models = try await getOrLoadModels(for: version)

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        self.activeVersion = version
    }

    private func ensureUnifiedModelsLoaded() async throws {
        if unifiedAsrManager != nil {
            return
        }

        await cleanupLoadedManagers()

        let manager = UnifiedAsrManager(encoderPrecision: FluidAudioModelManager.parakeetUnifiedPrecision)
        try await manager.loadModels(from: FluidAudioModelManager.parakeetUnifiedCacheDirectory())
        self.unifiedAsrManager = manager
    }

    private func ensureNemotronModelsLoaded(named modelName: String) async throws {
        if nemotronAsrManager != nil, activeNemotronModelName == modelName {
            return
        }

        await cleanupLoadedManagers()

        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: FluidAudioModelManager.nemotronCacheDirectory(for: modelName))
        self.nemotronAsrManager = manager
        self.activeNemotronModelName = modelName
    }

    // Returns cached models or loads from disk; deduplicates concurrent loads
    func getOrLoadModels(for version: AsrModelVersion) async throws -> AsrModels {
        if let cached = cachedModels, cached.version == version {
            return cached
        }

        // Deduplicate concurrent loads for the same version
        if let (existingVersion, existingTask) = loadingTask, existingVersion == version {
            return try await existingTask.value
        }

        let task = Task {
            let cacheDirectory = AsrModels.defaultCacheDirectory(for: version)
            guard AsrModels.modelsExist(at: cacheDirectory, version: version) else {
                throw AsrModelsError.loadingFailed(
                    "Parakeet model files are incomplete. Download the model from AI Models."
                )
            }
            return try await AsrModels.load(
                from: cacheDirectory,
                configuration: nil,
                version: version,
                encoderPrecision: .int8
            )
        }
        loadingTask = (version, task)

        do {
            let models = try await task.value
            self.cachedModels = models
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            return models
        } catch {
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            throw error
        }
    }

    // Fork-owned accessor (FORK-PATCHES.md touchpoint 4, "meeting-transcription-coordinator
    // fix round 3"): lets the meeting transcription seam reuse the SAME loaded `AsrManager`
    // dictation uses, instead of loading an independent second copy of the Parakeet models.
    // Authorised specifically to avoid that duplication on Mark's 16GB M2 Pro.
    //
    // SAFETY -- what this accessor guarantees, and how, stated as what the code cannot do
    // rather than as a convention:
    //
    // This class has no actor isolation of its own. `ensureModelsLoaded(for:)`,
    // `cleanupLoadedManagers()` and `transcribe(audioURL:model:context:)` all suspend, so
    // initiating a call on `@MainActor` does NOT serialize the operations against each other --
    // a second call can and does interleave at any `await` inside a first. Round 2 of this
    // accessor took `version` and called `ensureModelsLoaded(for:)`, so a meeting asking for a
    // version dictation did not have loaded ran `cleanupLoadedManagers()` -- including
    // `asrManager.cleanup()`, which nils out the CoreML models -- underneath a dictation that
    // was suspended inside `AsrManager.transcribe`. That is a live-dictation failure, and
    // "callers initiate on `@MainActor`" does not prevent it.
    //
    // This version removes the ability rather than documenting the hazard:
    //   * It is NOT `async` and NOT `throws`. Its whole body is two stored-property reads and a
    //     tuple construction, so it contains no suspension point at which anything can
    //     interleave. It runs to completion between two of the caller's own instructions.
    //   * It takes NO parameter. There is no argument by which a caller could name a model
    //     version other than the one already loaded, so "the meeting requested a version
    //     switch" is not an expressible call.
    //   * It calls nothing. Not `ensureModelsLoaded`, not `getOrLoadModels`, not
    //     `cleanupLoadedManagers`, not `cleanup()`. Those remain `private` to this file
    //     (`cleanup()` is internal, but is dictation's own lifecycle API and is called from no
    //     meeting file). `scripts/negative-controls/FluidAudioSharedModelAttacks.swift` is
    //     compiled into the app target on every CI run and MUST NOT COMPILE, which is what
    //     keeps that true rather than conventional.
    //
    // Consequence, deliberately accepted: the meeting seam is PINNED to whatever version
    // dictation already has loaded, and returns nil when nothing is loaded (the caller then
    // degrades to the coordinator's flat-fallback path). Getting a model loaded stays entirely
    // dictation's job, through the existing `loadModel(for:)` API that `VoiceInkEngine` already
    // calls at recording start. See FOLLOWUPS.md for what a composition root must therefore do.
    //
    // The reverse direction is NOT closed and is not claimed to be: dictation switching models
    // still evicts a manager a meeting is mid-way through using. That asymmetry is the point --
    // protecting the daily dictation flow outranks a meeting chunk, and a failed meeting chunk
    // degrades to the flat-fallback transcript rather than losing the recording.
    func borrowedAsrManager() -> (manager: AsrManager, version: AsrModelVersion)? {
        guard let asrManager, let activeVersion else { return nil }
        return (asrManager, activeVersion)
    }

    func loadModel(for model: FluidAudioModel) async throws {
        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            // Realtime Nemotron uses a dedicated streaming manager; batch loads lazily in transcribe().
            return
        }

        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            try await ensureUnifiedModelsLoaded()
            return
        }

        try await ensureModelsLoaded(for: version(for: model))
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
    {
        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            try await ensureUnifiedModelsLoaded()
            guard let unifiedAsrManager else {
                throw ASRError.notInitialized
            }

            let speechAudio = try loadAudioSamples(from: audioURL)
            let text = try await unifiedAsrManager.transcribe(speechAudio)
            return TextNormalizer.shared.normalizeSentence(text)
        }

        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            try await ensureNemotronModelsLoaded(named: model.name)
            guard let nemotronAsrManager else {
                throw ASRError.notInitialized
            }

            let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(
                context.language,
                for: model
            )
            let languageHint = FluidAudioModelManager.nemotronLanguageHint(from: compatibleLanguage)
            await nemotronAsrManager.setLanguage(languageHint)
            await nemotronAsrManager.reset()

            var speechAudio = try loadAudioSamples(from: audioURL)
            let trailingSilenceSamples = 16_000
            let maxSingleChunkSamples = 240_000
            if speechAudio.count + trailingSilenceSamples <= maxSingleChunkSamples {
                speechAudio += [Float](repeating: 0, count: trailingSilenceSamples)
            }

            _ = try await nemotronAsrManager.process(samples: speechAudio)
            let text = try await nemotronAsrManager.finish()
            return TextNormalizer.shared.normalizeSentence(text)
        }

        let targetVersion = version(for: model)
        try await ensureModelsLoaded(for: targetVersion)

        guard let asrManager = asrManager else {
            throw ASRError.notInitialized
        }

        let languageHint = Self.languageHint(
            from: context.language,
            model: model
        )
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(
            audioURL,
            decoderState: &decoderState,
            language: languageHint
        )

        return TextNormalizer.shared.normalizeSentence(result.text)
    }

    private func loadAudioSamples(from audioURL: URL) throws -> [Float] {
        try audioConverter.resampleAudioFile(audioURL)
    }

    // Releases ASR resources but preserves cached models for reuse
    func cleanup() async {
        await cleanupLoadedManagers()
    }

}

// Fork-owned (no donor equivalent). Not a port.
//
// Direct FluidAudio integration for the meeting transcription seam (`DECISION-transcription-seam.md`,
// Option (ii)). Deliberately independent of `FluidAudioTranscriptionService.swift`: this stage's
// brief forbids editing that file (it is the dictation path's FluidAudio backend, touched daily),
// and its `asrManager` is `private` with no seam to reach a segment-bearing call through it
// without an edit. This type owns its own `AsrManager` and its own model load instead. The cost,
// stated plainly: the meeting pipeline keeps a second copy of the Parakeet models resident in
// memory alongside dictation's own copy if both are active at once. That is the accepted price
// of not touching the upstream file, not an oversight.
//
// Segment mapping matches the donor's own `transcribeWithFluidAudio`
// (`segment-timing-design.md` §A/§C exactly): one `SpeechSegment` per FluidAudio `TokenTiming`
// (sub-word, not sentence- or word-merged), falling back to a single full-span segment only when
// the backend returns no token timings at all -- never a fabricated per-utterance boundary.
// `MicTurnNormalizer` (ported verbatim, unmodified) is what decides whether those raw per-token
// segments are usable or fragmented enough to fall through to sentence-split; that tiering logic
// is not duplicated here.

import FluidAudio
import Foundation

actor FluidAudioMeetingSegmentTranscriber: MeetingSegmentTranscribing {
    private let version: AsrModelVersion
    private let encoderPrecision: ParakeetEncoderPrecision
    private let modelsDirectory: URL?

    private var loadedManager: AsrManager?
    private var loadingTask: Task<AsrManager, Error>?

    init(
        version: AsrModelVersion = .v3,
        encoderPrecision: ParakeetEncoderPrecision = .int8,
        modelsDirectory: URL? = nil
    ) {
        self.version = version
        self.encoderPrecision = encoderPrecision
        self.modelsDirectory = modelsDirectory
    }

    func transcribe(chunkAt url: URL) async throws -> SpeechTranscriptionResult {
        let manager = try await resolvedManager()
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        // `AsrManager.transcribe(_:decoderState:language:)` reads and (for large files)
        // disk-backs the URL itself -- never routes through `AudioFileProcessor`, which would
        // load the whole chunk into a `[Float]` up front.
        let result = try await manager.transcribe(url, decoderState: &decoderState)
        return SpeechTranscriptionResult(
            text: result.text,
            segments: Self.speechSegments(
                fromTokenTimings: result.tokenTimings,
                duration: result.duration,
                text: result.text
            )
        )
    }

    /// Pure and independently testable (see `FluidAudioMeetingSegmentTranscriberTests.swift`,
    /// which constructs real `ASRResult`/`TokenTiming` values -- both have public memberwise
    /// initializers -- rather than faking this at a higher level).
    static func speechSegments(
        fromTokenTimings tokenTimings: [TokenTiming]?,
        duration: TimeInterval,
        text: String
    ) -> [SpeechSegment] {
        guard let tokenTimings, !tokenTimings.isEmpty else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            // Donor's own fallback for empty tokenTimings: one full-span segment, not a
            // zero-duration one -- `duration` is real, so this still carries meaningful timing
            // into MicTurnNormalizer rather than forcing sentence-split.
            return [SpeechSegment(start: 0, end: max(duration, 0), text: text)]
        }
        return tokenTimings.map { timing in
            SpeechSegment(
                start: max(timing.startTime, 0),
                end: max(timing.endTime, timing.startTime),
                text: timing.token
            )
        }
    }

    private func resolvedManager() async throws -> AsrManager {
        if let loadedManager { return loadedManager }
        if let loadingTask { return try await loadingTask.value }

        let version = version
        let encoderPrecision = encoderPrecision
        let directory = modelsDirectory ?? AsrModels.defaultCacheDirectory(for: version)

        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.load(
                from: directory,
                version: version,
                encoderPrecision: encoderPrecision
            )
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loadingTask = task
        do {
            let manager = try await task.value
            loadedManager = manager
            loadingTask = nil
            return manager
        } catch {
            loadingTask = nil
            throw error
        }
    }
}

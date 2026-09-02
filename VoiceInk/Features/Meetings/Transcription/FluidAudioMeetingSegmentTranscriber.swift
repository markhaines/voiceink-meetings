// Fork-owned (no donor equivalent). Not a port.
//
// Direct FluidAudio integration for the meeting transcription seam (`DECISION-transcription-seam.md`,
// Option (ii)). FIX ROUND (cross-vendor review, B1/B2): the first version of this file loaded
// its own independent `AsrManager` + Parakeet models, permanently duplicating whatever dictation
// already has loaded via `FluidAudioTranscriptionService`. On Mark's 16GB M2 Pro, where he
// dictates with local Parakeet every day, that is unacceptable -- Mark explicitly authorised an
// upstream touchpoint to fix it rather than ship it. This version instead SHARES dictation's
// already-loaded `AsrManager` through `FluidAudioTranscriptionService.sharedAsrManager(for:)`
// (a new, narrow, additive accessor on that file -- see FORK-PATCHES.md touchpoint 4). No model
// duplication, no independent lifecycle to manage here: eviction/lifecycle is delegated wholesale
// to the existing service's own (version-switch and `cleanup()`) behavior.
//
// SAFETY / actor isolation: `FluidAudioTranscriptionService` carries no actor isolation of its
// own (see that file) -- its existing safety today comes entirely from every caller initiating
// calls from `@MainActor` (via `TranscriptionServiceRegistry`), not from any compiler-enforced
// mutual exclusion. `resolveSharedManager()` below is THIS actor's own method, annotated
// `@MainActor` so calling it hops onto the main actor before touching the shared service --
// putting the meeting seam's access pattern in the SAME shape dictation's own existing calls
// already have (MainActor-initiated), not a new, less-disciplined bypass of it. This is a real,
// disclosed limit, not a stronger guarantee: like dictation's own existing calls, it does not
// itself prove no two overlapping calls can ever race past an internal `await` inside
// `ensureModelsLoaded`; it proves the meeting seam is exactly as disciplined as dictation
// already is, no more, no less. See FORK-PATCHES.md for the full reasoning and what remains
// unproven without real hardware/model measurement.
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
    private let sharedService: FluidAudioTranscriptionService
    private let version: AsrModelVersion

    init(sharedService: FluidAudioTranscriptionService, version: AsrModelVersion = .v3) {
        self.sharedService = sharedService
        self.version = version
    }

    func transcribe(chunkAt url: URL) async throws -> SpeechTranscriptionResult {
        let manager = try await resolveSharedManager()
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

    @MainActor
    private func resolveSharedManager() async throws -> AsrManager {
        try await sharedService.sharedAsrManager(for: version)
    }
}

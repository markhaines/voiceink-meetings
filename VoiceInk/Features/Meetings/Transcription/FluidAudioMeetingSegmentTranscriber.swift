// Fork-owned (no donor equivalent). Not a port.
//
// Direct FluidAudio integration for the meeting transcription seam (`DECISION-transcription-seam.md`,
// Option (ii)). It does NOT load models. It BORROWS the `AsrManager` dictation already has
// loaded, through `FluidAudioTranscriptionService.borrowedAsrManager()` (FORK-PATCHES.md
// touchpoint 4).
//
// FIX ROUND 3 (cross-vendor review, B1). Two earlier designs were defeated here:
//   * Round 1 loaded its own independent `AsrManager` + Parakeet models, permanently doubling
//     model memory on Mark's 16GB M2 Pro.
//   * Round 2 fixed the duplication by calling `sharedAsrManager(for: version)`, which called
//     `ensureModelsLoaded(for:)`. Review found the real defect that hid behind: a meeting asking
//     for a version dictation did not have loaded ran `cleanupLoadedManagers()` -- including
//     `asrManager.cleanup()`, which nils the CoreML models -- underneath a dictation suspended
//     inside `AsrManager.transcribe`. `@MainActor` initiation does not prevent that: every one
//     of those methods suspends, so actor reentrancy lets the two flows interleave. The comment
//     that claimed the calls were "serialized on the same executor" and that this was "not new
//     eviction behavior" was materially wrong on both counts and has been removed.
//
// Round 3 removes the capability instead of documenting the hazard. This type holds no version,
// requests no version, and cannot trigger a load: `borrowedAsrManager()` is a synchronous,
// non-throwing, argument-less getter over two stored properties (see its own doc comment for
// the full argument, and `scripts/negative-controls/FluidAudioSharedModelAttacks.swift` for the
// compile-time proof that the eviction-capable methods are unreachable from here).
//
// What that costs, stated plainly: if nothing is loaded, this transcriber throws
// `MeetingSegmentTranscriberError.sharedModelNotLoaded` and `MeetingTranscriptionCoordinator`
// degrades that ONE chunk to its flat-fallback path. It never loads a model to rescue itself.
// Ensuring a model is loaded is dictation's job, via the existing `loadModel(for:)` that
// `VoiceInkEngine` already calls at recording start; see FOLLOWUPS.md for the composition-root
// requirement that follows from this.
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

/// Errors a `MeetingSegmentTranscribing` conformer raises that the coordinator routes on rather
/// than propagates. Deliberately narrow: `sharedModelNotLoaded` is the ONLY case, so the
/// coordinator's catch cannot silently swallow a real transcription failure.
enum MeetingSegmentTranscriberError: Error, Equatable {
    /// Dictation has no model loaded, so there is nothing to borrow. Never means "loading
    /// failed" -- the meeting seam does not load.
    case sharedModelNotLoaded
}

actor FluidAudioMeetingSegmentTranscriber: MeetingSegmentTranscribing {
    private let sharedService: FluidAudioTranscriptionService

    init(sharedService: FluidAudioTranscriptionService) {
        self.sharedService = sharedService
    }

    func transcribe(chunkAt url: URL) async throws -> SpeechTranscriptionResult {
        guard let manager = await borrowLoadedManager() else {
            throw MeetingSegmentTranscriberError.sharedModelNotLoaded
        }
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

    /// The ONE line of this file that touches dictation's service. `@MainActor` here is not the
    /// safety argument (round 2's comment wrongly claimed it was); it just keeps the read on the
    /// executor every other caller of that class uses. The safety argument is that
    /// `borrowedAsrManager()` is synchronous and argument-less, so this hop reads whatever is
    /// loaded and returns, with no suspension point in between and no way to ask for anything
    /// else. `AsrManager` is a `public actor`, so the borrowed instance serializes a meeting's
    /// `transcribe` against dictation's own by itself.
    @MainActor
    private func borrowLoadedManager() -> AsrManager? {
        sharedService.borrowedAsrManager()?.manager
    }
}

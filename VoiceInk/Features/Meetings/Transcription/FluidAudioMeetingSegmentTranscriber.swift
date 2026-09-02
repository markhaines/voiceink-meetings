// Fork-owned (no donor equivalent). Not a port.
//
// Direct FluidAudio integration for the meeting transcription seam (`DECISION-transcription-seam.md`,
// Option (ii)). It does not load models and it does not hold the concrete transcription service.
// It holds one capability, `MeetingAsrManagerBorrowing` (see `MeetingAsrSharing.swift`), plus a
// dictation-priority check.
//
// FOUR ROUNDS OF REVIEW GOT IT HERE, and the history is kept because each round's mistake is a
// live hazard for whoever edits this next:
//   * Round 1 loaded its own independent `AsrManager` + Parakeet models, permanently doubling
//     model memory on Mark's 16GB M2 Pro.
//   * Round 2 fixed the duplication with `sharedAsrManager(for: version)`, which called
//     `ensureModelsLoaded(for:)`. That let a meeting run `cleanupLoadedManagers()` -- including
//     `asrManager.cleanup()`, which nils the CoreML models -- underneath a dictation suspended
//     inside `AsrManager.transcribe`. Round 2's comment claimed `@MainActor` initiation made the
//     calls "serialized on the same executor"; it does not, because all of those methods suspend.
//   * Round 3 removed the version argument and the suspension point, which held. Its third
//     claimed reason ("it calls nothing ... those remain private") was FALSE: `cleanup()` is
//     internal, so this file could have compiled `service.cleanup()`. Fixed in round 4 by holding
//     a capability instead of the class.
//   * Round 4 also closed what sharing the actor had opened: `AsrManager` is a `public actor`, so
//     a meeting chunk already inside `transcribe` makes a dictation started a moment later QUEUE
//     BEHIND it. Not memory this time, latency, against the same thing memory was protecting.
//
// DICTATION-PRIORITY ADMISSION -- what it guarantees, and what it does NOT:
//   * GUARANTEED: a meeting chunk never STARTS inference while dictation is active or pending.
//     `admitAndBorrow()` reads the priority check and takes the manager in ONE synchronous
//     `@MainActor` step, with no `await` between them. `VoiceInkEngine` starts a dictation on
//     `@MainActor`, so dictation cannot flip from idle to active inside that step. This is not a
//     narrowed race; there is no window.
//   * NOT GUARANTEED, and this is the honest limit: it cannot PREEMPT. If dictation starts after
//     a chunk's `manager.transcribe` is already running, that dictation still queues behind it.
//     The exposure is one chunk's inference, and its real duration has never been measured on
//     real hardware with real models -- FOLLOWUPS.md carries that as a smoke-test prerequisite,
//     not as a number I am guessing at here.
//   * NOT GUARANTEED: the check is only as good as the closure a composition root supplies. There
//     is no default, so that is a decision someone has to make, not one this file makes quietly.
//
// Refusal is cheap on purpose. Both refusal cases raise a `MeetingSegmentTranscriberError` that
// `MeetingTranscriptionCoordinator` routes to its flat-fallback path, so the cost is losing
// per-token segment timings for one chunk (which `MicTurnNormalizer` then sentence-splits, the
// donor's own behaviour for every backend except FluidAudio). Losing that is an acceptable price.
// Making Mark wait on his own dictation is not.
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

/// The errors `MeetingTranscriptionCoordinator` ROUTES on rather than propagates. Both mean "this
/// chunk deliberately did not run", never "transcription failed" -- keeping them a closed,
/// two-case enum is what lets the coordinator's catch stay narrow enough that a real backend
/// fault still propagates.
enum MeetingSegmentTranscriberError: Error, Equatable {
    /// Dictation has no model loaded, so there was nothing to borrow. The meeting seam does not
    /// load: being able to load is what let round 2 evict dictation's model.
    case sharedModelNotLoaded
    /// Dictation is active or pending. Yielded rather than queueing dictation behind this chunk.
    case dictationHasPriority
}

actor FluidAudioMeetingSegmentTranscriber: MeetingSegmentTranscribing {
    private nonisolated let borrow: MeetingAsrManagerBorrow
    private nonisolated let isDictationActiveOrPending: MeetingDictationPriorityCheck

    /// `@MainActor` because both stored capabilities are `@MainActor` closures and this is where
    /// the borrow one is formed -- and because the composition root that builds this lives on
    /// `@MainActor` anyway (`TranscriptionServiceRegistry` is `@MainActor`).
    ///
    /// The parameter is `any MeetingAsrManagerBorrowing`, so inside this initializer the only
    /// member of the transcription service that can be NAMED is `borrowedAsrManager()`. That is
    /// where B4.1 is enforced: `cleanup()` is not a member of this type.
    ///
    /// No default for `isDictationActiveOrPending`, deliberately: a composition root must decide
    /// what "dictation is busy" means rather than inherit a permissive default that silently
    /// disables B4.2's admission control.
    @MainActor
    init(
        borrowing: any MeetingAsrManagerBorrowing,
        isDictationActiveOrPending: @escaping MeetingDictationPriorityCheck
    ) {
        self.borrow = { borrowing.borrowedAsrManager() }
        self.isDictationActiveOrPending = isDictationActiveOrPending
    }

    func transcribe(chunkAt url: URL) async throws -> SpeechTranscriptionResult {
        let manager: AsrManager
        switch await admitAndBorrow() {
        case .dictationHasPriority:
            throw MeetingSegmentTranscriberError.dictationHasPriority
        case .noModelLoaded:
            throw MeetingSegmentTranscriberError.sharedModelNotLoaded
        case .granted(let borrowed):
            manager = borrowed
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

    private enum Admission {
        case granted(AsrManager)
        case dictationHasPriority
        case noModelLoaded
    }

    /// The whole of this file's contact with dictation's runtime, and the reason the admission
    /// decision has no race: the priority read and the borrow are two synchronous statements in
    /// one `@MainActor` step, with no `await` between them, so no dictation can begin in between.
    /// `borrowedAsrManager()` is itself non-`async` and argument-less, so this step cannot load,
    /// evict, or switch anything -- and `borrow` is a closed-over capability, not the concrete
    /// service, so `cleanup()` and friends are not nameable here at all. A closure has no members.
    @MainActor
    private func admitAndBorrow() -> Admission {
        if isDictationActiveOrPending() { return .dictationHasPriority }
        guard let borrowed = borrow() else { return .noModelLoaded }
        return .granted(borrowed.manager)
    }
}

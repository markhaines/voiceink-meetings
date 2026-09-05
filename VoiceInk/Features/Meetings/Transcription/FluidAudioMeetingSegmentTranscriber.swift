// Fork-owned (no donor equivalent). Not a port.
//
// Direct FluidAudio integration for the meeting transcription seam (`DECISION-transcription-seam.md`,
// Option (ii)). It does not load models and it cannot name the concrete transcription service. It
// holds one value, `MeetingAsrRuntimeAccess` (see `MeetingAsrSharing.swift`): two closures, and
// nothing else.
//
// FIVE ROUNDS OF REVIEW GOT IT HERE, and the history is kept because each round's mistake is a
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
//     internal, so this file could have compiled `service.cleanup()`.
//   * Round 4 replaced the concrete service with `any MeetingAsrManagerBorrowing`. ALSO FALSE:
//     an existential downcasts back, so `borrowing as? FluidAudioTranscriptionService` followed
//     by `cleanup()` compiled with zero diagnostics. Round 5 replaced it with a struct of
//     closures, which has no concrete type to recover and no members to call.
//   * Round 4 also opened, and round 5 tightened, the latency exposure below.
//
// DICTATION-PRIORITY ADMISSION -- what it guarantees, and what it does NOT:
//   * WHY IT EXISTS: `AsrManager` is a `public actor`, so meeting and dictation inference are
//     mutually serialized. A meeting chunk already inside `transcribe` makes a dictation started
//     a moment later QUEUE BEHIND it. Not memory this time, latency, against the same daily flow
//     memory was protecting.
//   * GUARANTEED: the priority check is the LAST thing this file does before entering inference.
//     Round 4 checked, then read `await manager.decoderLayerCount` -- a hop into the `AsrManager`
//     actor and back -- and only then called `transcribe`, so a dictation starting inside that
//     round trip still lost. Round 5 hoists that read to BEFORE the final check
//     (`reconfirmDictationIsIdle()`), so exactly one `await` remains between deciding and
//     starting: the hop into `transcribe` itself.
//   * NOT GUARANTEED, stated plainly rather than argued away: that remaining hop is a real
//     window. A dictation that enqueues on the `AsrManager` actor between our check returning
//     and our `transcribe` call landing still queues behind this chunk. It CANNOT be closed from
//     this side: closing it means deciding admission inside the actor that serializes both
//     flows, which is shared admission with the dictation path -- a change to upstream code this
//     fork merges from daily, and Mark's call, not this file's. FOLLOWUPS.md carries it as a
//     HARD PREREQUISITE to wiring, not a nice-to-have.
//   * NOT GUARANTEED: it cannot PREEMPT. A dictation starting after `transcribe` is already
//     running waits for that chunk. The exposure is one chunk's inference, whose real duration
//     has never been measured on real hardware with real models.
//   * NOT GUARANTEED: the check is only as good as the closure a composition root supplies.
//     There is no default, so that is a decision someone has to make, not one this file makes.
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
    private nonisolated let access: MeetingAsrRuntimeAccess

    /// `@MainActor` because both of the capability's closures are `@MainActor`, and because the
    /// composition root that will build this lives there anyway (`TranscriptionServiceRegistry`
    /// is `@MainActor`).
    ///
    /// The parameter is a `MeetingAsrRuntimeAccess` VALUE, not a protocol existential over the
    /// transcription service. That is where B1 is enforced in round 5: no concrete type is
    /// carried in, so there is nothing here for `as?` to recover. Stated exactly, because the
    /// looser version of this sentence is what round 4 shipped and review defeated:
    /// `as? FluidAudioTranscriptionService` against this value still COMPILES, as a cast the
    /// compiler proves "always fails"; it returns nil rather than a service. `cleanup()` is not
    /// nameable in this file by any route the attack suite has found, and the suite now contains
    /// the downcast it was missing.
    @MainActor
    init(access: MeetingAsrRuntimeAccess) {
        self.access = access
    }

    func transcribe(chunkAt url: URL) async throws -> SpeechTranscriptionResult {
        // (1) Cheap early refusal: if dictation is already busy, do not touch the actor at all.
        let manager: AsrManager
        switch await admitAndBorrow() {
        case .dictationHasPriority:
            throw MeetingSegmentTranscriberError.dictationHasPriority
        case .noModelLoaded:
            throw MeetingSegmentTranscriberError.sharedModelNotLoaded
        case .granted(let borrowed):
            manager = borrowed
        }

        // (2) Every suspension this method needs BEFORE its final admission decision. Reading
        //     `decoderLayerCount` is a hop into the `AsrManager` actor and back; round 4 did it
        //     AFTER the check, which is exactly the window the reviewer found. Nothing below
        //     this line and above `transcribe` suspends: `TdtDecoderState.make` is a synchronous
        //     static function on a `Sendable` struct.
        let decoderLayers = await manager.decoderLayerCount

        // (3) The decision, as late as it can possibly be made from outside the actor.
        guard await reconfirmDictationIsIdle() else {
            throw MeetingSegmentTranscriberError.dictationHasPriority
        }

        // Synchronous: `TdtDecoderState.make` is a static function on a `Sendable` struct, so
        // this adds no suspension between the decision above and the call below.
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)

        // (4) The ONE remaining `await` between deciding and starting inference -- this line.
        //     It is a real window, not a closed one: a dictation that enqueues on the
        //     `AsrManager` actor after step (3) returned but before this call lands runs second.
        //     Disclosed, not argued away; see this file's header and FOLLOWUPS.md gate item 2.
        //
        //     `AsrManager.transcribe(_:decoderState:language:)` reads and (for large files)
        //     disk-backs the URL itself -- never routes through `AudioFileProcessor`, which
        //     would load the whole chunk into a `[Float]` up front.
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

    /// This file's only contact with dictation's runtime, and the reason the EARLY decision has
    /// no race: the priority read and the borrow are two synchronous statements in one
    /// `@MainActor` step with no `await` between them, so no dictation can begin in between.
    /// `borrowLoadedManager` cannot load, evict or switch anything -- it is argument-less and
    /// non-suspending -- and it is a closure, so there is no concrete service to recover from it.
    @MainActor
    private func admitAndBorrow() -> Admission {
        if access.isDictationActiveOrPending() { return .dictationHasPriority }
        guard let borrowed = access.borrowLoadedManager() else { return .noModelLoaded }
        return .granted(borrowed.manager)
    }

    /// The final admission decision, taken after every other suspension this method needs, so
    /// that only the hop into `transcribe` separates it from inference starting.
    ///
    /// It re-reads rather than trusting the earlier one because a dictation may have started
    /// during step (2)'s round trip into the `AsrManager` actor -- which is precisely the
    /// interleaving round 4 lost. It does NOT make the sequence atomic; see the header.
    @MainActor
    private func reconfirmDictationIsIdle() -> Bool {
        !access.isDictationActiveOrPending()
    }
}

// Fork-owned (no donor equivalent). Not a port.
//
// Segment-timing adapter for the meeting transcription seam (`DECISION-transcription-seam.md`,
// Option (ii)). As of round 6 this file contains NO FluidAudio runtime object at all: it asks the
// capability to transcribe a chunk and maps the receipt it gets back into `SpeechSegment`s.
//
// SIX ROUNDS OF REVIEW GOT IT HERE. Each round's mistake is kept because it is a live hazard for
// whoever edits this next, and because the pattern in them matters more than any single fix:
//   * Round 1 loaded its own independent `AsrManager` + Parakeet models, permanently doubling
//     model memory on Mark's 16GB M2 Pro.
//   * Round 2 fixed the duplication with `sharedAsrManager(for: version)`, which called
//     `ensureModelsLoaded(for:)`. That let a meeting run `cleanupLoadedManagers()` -- including
//     `asrManager.cleanup()` -- underneath a dictation suspended inside `AsrManager.transcribe`.
//     Its comment claimed `@MainActor` initiation made the calls "serialized on the same
//     executor"; it does not, because all of those methods suspend.
//   * Round 3 removed the version argument and the suspension point, which held. Its third
//     claimed reason ("it calls nothing ... those remain private") was FALSE: `cleanup()` is
//     internal, so this file could have compiled `service.cleanup()`.
//   * Round 4 replaced the service with `any MeetingAsrManagerBorrowing`. ALSO FALSE: an
//     existential downcasts back, so `borrowing as? FluidAudioTranscriptionService` then
//     `cleanup()` compiled with zero diagnostics.
//   * Round 5 replaced the existential with a struct of closures. Every recover-the-service
//     attack then failed -- and the capability was still handing this file the live shared
//     `AsrManager`, on which `cleanup()` is ordinary public API. Four rounds of attacks, none of
//     which followed the capability's own return value.
//   * Round 6 removed the object instead of defending it. There is no manager here to call
//     anything on.
//
// WHAT THIS FILE CAN DO TO DICTATION'S RUNTIME: ask for one chunk to be transcribed, and read the
// result. That is the complete list, and it is complete because `MeetingAsrRuntimeAccess` has one
// member whose return type is a value receipt (see `MeetingAsrSharing.swift`).
//
// ADMISSION lives on the owning side now, inside the capability, because that is where the
// `AsrManager` is. This file does not check, and could not usefully check: by the time it saw a
// result the decision would be long made. What it does is honour the refusal -- both refusal
// outcomes become errors that `MeetingTranscriptionCoordinator` routes to its flat-fallback path,
// so the cost is losing per-token segment timings for one chunk (which `MicTurnNormalizer` then
// sentence-splits, the donor's own behaviour for every backend except FluidAudio). Losing that is
// an acceptable price. Making Mark wait on his own dictation is not.
//
// Segment mapping matches the donor's own `transcribeWithFluidAudio`
// (`segment-timing-design.md` §A/§C exactly): one `SpeechSegment` per token span (sub-word, not
// sentence- or word-merged), falling back to a single full-span segment only when the backend
// returns no token timings at all -- never a fabricated per-utterance boundary.
// `MicTurnNormalizer` (ported verbatim, unmodified) is what decides whether those raw per-token
// segments are usable or fragmented enough to fall through to sentence-split; that tiering logic
// is not duplicated here.

import Foundation

/// The errors `MeetingTranscriptionCoordinator` ROUTES on rather than propagates. Both mean "this
/// chunk deliberately did not run", never "transcription failed" -- keeping them a closed,
/// two-case enum is what lets the coordinator's catch stay narrow enough that a real backend
/// fault still propagates.
enum MeetingSegmentTranscriberError: Error, Equatable {
    /// Dictation has no model loaded, so there was nothing to transcribe with.
    case sharedModelNotLoaded
    /// Dictation is active or pending. Yielded rather than queueing dictation behind this chunk.
    case dictationHasPriority
}

actor FluidAudioMeetingSegmentTranscriber: MeetingSegmentTranscribing {
    private nonisolated let access: MeetingAsrRuntimeAccess

    /// `@MainActor` because the capability's operation is `@MainActor`, and because the
    /// composition root that will build this lives there anyway (`TranscriptionServiceRegistry`
    /// is `@MainActor`).
    @MainActor
    init(access: MeetingAsrRuntimeAccess) {
        self.access = access
    }

    func transcribe(chunkAt url: URL) async throws -> SpeechTranscriptionResult {
        switch try await access.transcribeChunk(url) {
        case .dictationHasPriority:
            throw MeetingSegmentTranscriberError.dictationHasPriority
        case .sharedModelNotLoaded:
            throw MeetingSegmentTranscriberError.sharedModelNotLoaded
        case .transcribed(let transcription):
            return SpeechTranscriptionResult(
                text: transcription.text,
                segments: Self.speechSegments(
                    fromTokenSpans: transcription.tokenSpans,
                    duration: transcription.duration,
                    text: transcription.text
                )
            )
        }
    }

    /// Pure and independently testable (see `FluidAudioMeetingSegmentTranscriberTests.swift`).
    /// Unchanged in behaviour by round 6; only the input element type moved from FluidAudio's
    /// `TokenTiming` to the fork-owned `MeetingTokenSpan`, because the seam no longer carries a
    /// package type across it.
    static func speechSegments(
        fromTokenSpans tokenSpans: [MeetingTokenSpan]?,
        duration: TimeInterval,
        text: String
    ) -> [SpeechSegment] {
        guard let tokenSpans, !tokenSpans.isEmpty else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            // Donor's own fallback for empty token timings: one full-span segment, not a
            // zero-duration one -- `duration` is real, so this still carries meaningful timing
            // into MicTurnNormalizer rather than forcing sentence-split.
            return [SpeechSegment(start: 0, end: max(duration, 0), text: text)]
        }
        return tokenSpans.map { span in
            SpeechSegment(
                start: max(span.start, 0),
                end: max(span.end, span.start),
                text: span.token
            )
        }
    }
}

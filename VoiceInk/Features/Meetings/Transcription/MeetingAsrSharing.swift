// Fork-owned (no donor equivalent). Not a port.
//
// What the meeting transcription seam is allowed to ASK dictation's Parakeet runtime to DO --
// which, as of round 6, is the right framing. Every earlier version of this file handed the seam
// a THING and then tried to make that thing safe. That failed four times.
//
// FIX ROUND 6 (cross-vendor review, B1). Round 5's capability returned the live shared
// `AsrManager`, and this compiled from any meeting-side file, with zero diagnostics:
//
//     if let manager = access.borrowLoadedManager()?.manager { await manager.cleanup() }
//
// No cast. No reflection. No `unsafeBitCast`. No recovery of `FluidAudioTranscriptionService` at
// all. `AsrManager.cleanup()` is ordinary public FluidAudio API that nils every loaded model, so
// this is a direct eviction of the models Mark's daily dictation is using, through the
// capability's own front door.
//
// WHY THE ATTACK SUITE MISSED IT, recorded because the lesson is worth more than the patch:
// every control -- conditional downcast, forced downcast, closure downcast, coercion, member
// lookup, generic erased cast, extension-added initializer, retroactive conformance, `Mirror`,
// `@testable` -- was aimed at RECOVERING THE SERVICE. All of them correctly failed. Not one
// followed the capability's own RETURN VALUE. The suite tested the routes its author imagined,
// and the object being protected was being handed out the front door the whole time.
// `scripts/negative-controls/MeetingCapabilityReturnValue*.swift` exist so that class of miss
// cannot recur silently: they follow what the capability returns and try to reach mutating API
// on it.
//
// THE FIX -- inversion, not defence. The meeting side no longer receives an `AsrManager`,
// because there is no longer any way to ask for one. It receives a closure that PERFORMS one
// narrowly-defined operation on the owning side and returns a RECEIPT: `MeetingChunkTranscription`,
// a fork-owned value type of `String`, `TimeInterval` and arrays of the same. There is no
// `cleanup()` to call because there is no object to call it on.
//
// This is deliberately not "wrap the manager", not "document that callers must not call
// cleanup()", and not a convention. Three designs on this project were each defeated in one line
// because they defended a hazard instead of removing it.
//
// WHAT IS ENFORCED, AND WHAT IS NOT. Stated to the standard the last two rounds established:
// distinguish compile errors from warnings from runtime properties from convention, and never
// write the guarantee wider than the code.
//
//   * ENFORCED, by the type system, and checked on every CI run: nothing the meeting seam can
//     name has an eviction-capable or state-mutating member. The capability's ONLY member is
//     `transcribeChunk`, a closure (which has no members of its own); its return type is
//     `MeetingChunkTranscriptionOutcome`, an enum whose one payload is
//     `MeetingChunkTranscription`, whose entire transitive surface is exactly `String`,
//     `TimeInterval`, and `[MeetingTokenSpan]?` -- and `MeetingTokenSpan` is one `String` and two
//     `TimeInterval`s. That is the complete enumeration, not a sample of it, which is what lets
//     the return-value controls be exhaustive rather than a list of imagined routes.
//   * ENFORCED: THIS FILE is the only one in `Features/Meetings/Transcription/` that names
//     `AsrManager` in code at all -- verified by grep, and the reason the adapter no longer even
//     imports FluidAudio. Scoped deliberately: the claim is NOT "no `AsrManager` exists in the
//     seam", because one plainly does, in the factory below. It is that no OTHER file in the seam
//     can name, hold, store, return or pass one.
//   * NOT ENFORCED, and NOT claimed: this file names `FluidAudioTranscriptionService` and does
//     touch an `AsrManager`, inside `sharingDictationRuntime(of:isDictationActiveOrPending:)`.
//     That is the one place authority is delegated, and it is on the OWNING side of the seam by
//     construction. Code that already holds the concrete service can still call `cleanup()`;
//     that is dictation's own lifecycle API and is not this seam's to remove.
//   * NOT ENFORCED: raw memory. `unsafeBitCast` and friends defeat any Swift-level boundary and
//     are out of scope for the same reason FOLLOWUPS.md already records for `MeetingStore`. The
//     closure captures the service in its context. That is a cost, not a defence.

import FluidAudio
import Foundation

/// One token's text and its timing, as a fork-owned value.
///
/// Fork-owned rather than FluidAudio's `TokenTiming` on purpose, and the reason is the whole of
/// round 6: the question "what can a caller do with what this returns?" must have an answer that
/// stays closed. Every field here is a `String` or a `TimeInterval`, so the answer is "read it".
/// A package type could grow a reference-typed field or a mutating method in any version bump,
/// and the answer would change without anything in this fork being edited.
struct MeetingTokenSpan: Sendable, Equatable {
    let token: String
    let start: TimeInterval
    let end: TimeInterval
}

/// The receipt the meeting seam gets back instead of a manager.
///
/// Transitively: `String`, `TimeInterval`, and `[MeetingTokenSpan]?`, which is an array of the
/// value type above. No reference types, no actors, no methods, nothing that mutates any shared
/// state. That is the property that makes the return-value controls able to state a complete
/// answer rather than a list of routes someone happened to think of.
struct MeetingChunkTranscription: Sendable, Equatable {
    let text: String
    let duration: TimeInterval
    let tokenSpans: [MeetingTokenSpan]?
}

extension MeetingChunkTranscription {
    /// Converts FluidAudio's result into the fork-owned receipt. `internal` rather than folded
    /// inline into the operation closure so it stays independently testable: `ASRResult` has a
    /// public memberwise initializer, so a test can round-trip a real one through this and prove
    /// the fields the segment mapper reads are the fields that actually cross the seam. That test
    /// existed before round 6 and would otherwise have been lost when the manager stopped
    /// crossing it.
    init(_ result: ASRResult) {
        self.init(
            text: result.text,
            duration: result.duration,
            tokenSpans: result.tokenTimings.map { timings in
                timings.map { MeetingTokenSpan(token: $0.token, start: $0.startTime, end: $0.endTime) }
            }
        )
    }
}

/// Why a chunk did or did not run. The two refusal cases are the ones
/// `MeetingTranscriptionCoordinator` routes to its flat-fallback path; a real inference failure
/// is a thrown error, not a case here, so the coordinator's narrow catch still cannot swallow one.
enum MeetingChunkTranscriptionOutcome: Sendable, Equatable {
    case transcribed(MeetingChunkTranscription)
    /// Dictation is active or pending, so the chunk yielded rather than making it queue behind.
    case dictationHasPriority
    /// Dictation has no model loaded, so there was nothing to transcribe with. The meeting seam
    /// does not load: being able to load is what let round 2 evict dictation's model.
    case sharedModelNotLoaded
}

/// Transcribe one already-rotated chunk file using whatever model dictation already has loaded,
/// performing the dictation-priority admission check on the owning side.
///
/// `@MainActor` because that is where the admission decision has to be made -- `VoiceInkEngine`
/// starts a dictation on `@MainActor`, so a check read there cannot be raced by a dictation
/// starting. `throws` because a genuine inference failure must propagate rather than be folded
/// into an outcome case and silently degraded.
typealias MeetingChunkTranscriptionOperation =
    @MainActor @Sendable (URL) async throws -> MeetingChunkTranscriptionOutcome

/// Whether dictation currently owns, or is waiting for, the shared `AsrManager`.
///
/// Supplied by whoever mints the capability. There is deliberately NO default: a composition root
/// has to decide what "dictation is busy" means for this app rather than inherit a permissive one
/// silently. A negative control asserts that omitting it does not compile.
typealias MeetingDictationPriorityCheck = @MainActor @Sendable () -> Bool

/// Everything the meeting transcription seam can do to dictation's Parakeet runtime.
///
/// One closure. Round 5's version had two members and this same sentence above it, and the
/// sentence was false, because one of those members returned the live `AsrManager`. The claim is
/// only true now because the single member's return type is a value receipt with no reachable
/// mutating API -- see `MeetingChunkTranscription`.
struct MeetingAsrRuntimeAccess: Sendable {
    let transcribeChunk: MeetingChunkTranscriptionOperation
}

extension MeetingAsrRuntimeAccess {
    /// The ONE place authority is delegated from dictation's service to the meeting seam, and the
    /// only code in the seam's file tree that ever holds an `AsrManager`. It is on the owning
    /// side: it performs the operation and hands back a receipt.
    ///
    /// ADMISSION ORDERING (round 5's B2 property, preserved and slightly improved -- see the
    /// numbered comments in the body). The requirement is that exactly one `await` separates the
    /// final dictation-idle check from the inference call. Round 5 satisfied it across an actor
    /// boundary; here the whole sequence runs on `@MainActor`, so the final check is a plain
    /// synchronous statement immediately before the call, and one suspension on the path
    /// (round 5's hop back to `@MainActor` to re-check) is gone entirely.
    @MainActor
    static func sharingDictationRuntime(
        of service: FluidAudioTranscriptionService,
        isDictationActiveOrPending: @escaping MeetingDictationPriorityCheck
    ) -> MeetingAsrRuntimeAccess {
        MeetingAsrRuntimeAccess(
            transcribeChunk: { url in
                // (1) Cheap early refusal: do not touch the actor at all if dictation is busy.
                //     Synchronous with the borrow below -- no `await` between them, so no
                //     dictation can start in between.
                if isDictationActiveOrPending() { return .dictationHasPriority }
                guard let borrowed = service.borrowedAsrManager() else { return .sharedModelNotLoaded }
                let manager = borrowed.manager

                // (2) Every suspension this operation needs BEFORE its final admission decision.
                //     Reading `decoderLayerCount` is a hop into the `AsrManager` actor and back;
                //     round 4 did it AFTER the check, which was the window review found then.
                let decoderLayers = await manager.decoderLayerCount

                // (3) The final decision. Synchronous, on `@MainActor`, immediately before the
                //     call. Round 5 needed an `await` here to hop back to `@MainActor`; that
                //     suspension no longer exists.
                if isDictationActiveOrPending() { return .dictationHasPriority }

                // Synchronous: `TdtDecoderState.make` is a static function on a `Sendable`
                // struct, so it adds no suspension between (3) and (4).
                var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)

                // (4) The ONE remaining `await` between deciding and starting inference. Still a
                //     real window -- a dictation that enqueues on the `AsrManager` actor after
                //     (3) but before this call lands runs second. Disclosed, not closed; see
                //     FOLLOWUPS.md gate item 2.
                //
                //     `AsrManager.transcribe(_:decoderState:language:)` reads and (for large
                //     files) disk-backs the URL itself -- never routes through
                //     `AudioFileProcessor`, which would load the whole chunk into a `[Float]`.
                let result = try await manager.transcribe(url, decoderState: &decoderState)

                // The manager does not leave this closure. Only the receipt does.
                return .transcribed(MeetingChunkTranscription(result))
            }
        )
    }
}

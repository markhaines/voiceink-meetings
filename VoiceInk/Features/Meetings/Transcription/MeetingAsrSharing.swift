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
// Three negative controls exist so that class of miss cannot recur silently, and they are named
// individually rather than behind a glob because the glob this comment used to cite
// (`MeetingCapabilityReturnValue*.swift`) matched only the first of them:
// `MeetingCapabilityReturnValueEvictionAttack.swift` (the exact round-5 defeat),
// `MeetingReceiptMutatingApiAttack.swift` (reaching mutating API transitively through the
// receipt), and `MeetingSeamCannotNameAsrManagerAttack.swift` (can any returned value BE or
// CONTAIN a manager, down to the leaf fields).
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
//   * TODAY'S DECLARED SURFACE, which is an observation about the source and NOT a guarantee the
//     compiler maintains: the capability's only member is `transcribeChunk`, a closure (which has
//     no members of its own). A COMPUTED member could be added in an extension and nothing here
//     would fire -- see the FAILS OPEN list below, which this bullet used to contradict by
//     calling itself "enforced ... on every CI run".
//
//     What IS enforced, by nominal typing, is what any member can hand back: the return type is
//     `MeetingChunkTranscriptionOutcome`, an enum whose one payload is
//     `MeetingChunkTranscription`, whose entire transitive surface is exactly `String`,
//     `TimeInterval`, and `[MeetingTokenSpan]?` -- and `MeetingTokenSpan` is one `String` and two
//     `TimeInterval`s. That is the complete enumeration, not a sample of it, which is what lets
//     the return-value controls be exhaustive rather than a list of imagined routes. It is also
//     why the return-type boundary is the load-bearing claim in this file: it holds however many
//     members exist, because every member would still have to return one of those types.
//   * ENFORCED, stated exactly, because round 6 stated it too broadly: **safe Swift cannot
//     recover the LIVE SHARED `AsrManager` -- the one dictation is using -- through this
//     capability's declared return types.** The mechanism is nominal typing of the stored
//     property and of every return type on the path, plus closure-capture opacity: the factory's
//     closure captures the manager, and a Swift closure's captured context is not addressable
//     through the type system. Nothing about WHERE the code lives contributes to that guarantee.
//
//     What it does NOT say, and what round 6 wrongly implied: it is NOT a claim that other
//     meeting files cannot have an `AsrManager`. Any file in this target can
//     `import FluidAudio` and construct its own -- Swift has no mechanism to prevent that, and no
//     control here attempts to. Constructing a fresh manager is not the hazard; obtaining the one
//     dictation has loaded is, because that is the instance whose `cleanup()` would evict Mark's
//     models mid-dictation.
//
//   * CONVENTION, not enforcement, and labelled as such: this file is currently the only one in
//     `Features/Meetings/Transcription/` that names `AsrManager` in code at all. That is an
//     observation about the source as it stands today, verified by grep and re-checked by a text
//     tripwire in `SharedModelDuplicationTests`. A tripwire is not the type system: it catches
//     the shape it greps for, and nothing else.
//
//     WHAT WOULD BREAK IT, and -- stated exactly, because round 7 wrote this list too broadly --
//     which of those routes a guard would actually catch. "A new member fails closed" was FALSE:
//     it is true of STORED properties and of nothing else.
//
//       FAILS CLOSED (the build or the test run fails, so the change cannot land unnoticed).
//       WHICH of the two matters, because they fail at different times and one of them is
//       skippable: a COMPILE-TIME guard breaks the build itself, whereas a RUNTIME guard is an
//       assertion that only fires when the test suite is actually executed.
//         - COMPILE-TIME. A new STORED property on `MeetingAsrRuntimeAccess` that is NOT
//           defaulted: the synthesised memberwise initializer gains a required parameter and
//           `MeetingCapabilitySurfaceGuardTests` stops compiling.
//         - COMPILE-TIME. A new case on `MeetingChunkTranscriptionOutcome`, including one
//           carrying a manager: the default-free exhaustive switches in that test file and in
//           `MeetingSeamCannotNameAsrManagerAttack.swift` stop compiling.
//         - RUNTIME ONLY. A new stored property that IS defaulted, on any of the three types
//           (`let leak: LeakBox? = nil`). It is not a required initializer parameter, so nothing
//           stops compiling; it is caught by the stored-property COUNT assertions over `Mirror`,
//           one per type, when the tests RUN. Verified in round 8 by planting exactly that shape:
//           the negative control passed and only the count assertion failed.
//
//       FAILS OPEN (compiles, and NO guard here catches it):
//         - a new COMPUTED member or method, added to any of these types in an extension:
//           `extension MeetingAsrRuntimeAccess { var liveManager: AsrManager { ... } }` compiles
//           and no guard fires. `Mirror` does not see computed properties, the memberwise
//           initializer gains no parameter, and Swift has no exhaustiveness rule over a type's
//           method list. An AST/source-signature guard could close it; Mark ruled that out for
//           this PR as bespoke test infrastructure whose own correctness would need verifying and
//           which rots when the source layout changes, on a coordinator nothing constructs yet.
//           It is WIRING GATE item 7 in FOLLOWUPS.md, OPEN, to be re-checked before wiring.
//         - a second accessor on `FluidAudioTranscriptionService` reached some other way, or a
//           composition root passing the manager in alongside the capability. Neither is
//           reachable from anything this file declares.
//   * NOT ENFORCED, and NOT claimed: this file names `FluidAudioTranscriptionService` and does
//     touch an `AsrManager`, inside `sharingDictationRuntime(of:isDictationActiveOrPending:)`.
//     That is the one place authority is delegated, and it is on the OWNING side of the seam by
//     construction. Code that already holds the concrete service can still call `cleanup()`;
//     that is dictation's own lifecycle API and is not this seam's to remove.
//   * NOT CONSTRAINED BY TYPE, safe today only by inspection: the operation is `throws`, and a
//     thrown error is `any Error`, so the error channel is not restricted to fork-owned types the
//     way the success channel is. Nothing on the factory's path currently throws an error that
//     carries an `AsrManager` or the service -- `AsrManager.transcribe` throws FluidAudio's own
//     `ASRError`/decoding errors, none of which embed the manager, but that is an inspection of
//     today's code, not a guarantee the compiler maintains. Recorded rather than restructured:
//     constraining it would mean a typed-throws boundary and error mapping across the seam, which
//     is a larger change than the residual justifies.
//
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

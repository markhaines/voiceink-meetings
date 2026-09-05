// Fork-owned (no donor equivalent). Not a port.
//
// The capability the meeting transcription seam has over dictation's shared Parakeet runtime,
// and nothing else.
//
// FIX ROUND 5 (cross-vendor review, B1). Round 4 handed the seam `any MeetingAsrManagerBorrowing`
// and claimed the eviction-capable methods were therefore unreachable. That was FALSE, and the
// attack suite missed it because it never tried a downcast. An existential can always be
// conditionally downcast back to a conforming concrete type, so this compiled, with zero
// diagnostics, against the round-4 code:
//
//     if let concrete = borrowing as? FluidAudioTranscriptionService {
//         await concrete.cleanup()          // evicts the model out from under a live dictation
//     }
//
// Verified by building it into the app target, not by reading. That is the third time on this
// branch that a boundary held only as far as the attack list went, so the fix is the shape that
// has actually survived: the unsafe call is not expressible, and the attack that would catch a
// regression is compiled on every CI run.
//
// THE FIX: the seam is handed a VALUE, not an existential over a type it can name.
// `MeetingAsrRuntimeAccess` is a struct whose only stored properties are two closures. There is
// no protocol existential to downcast, no class reference to recover, and no member to call but
// the capability itself.
//
// Precisely, because "compile error" would be the same kind of overclaim this round is fixing:
// `access as? FluidAudioTranscriptionService` still COMPILES. A cast between two unrelated
// concrete types is not an error in Swift -- it is a statically-proven-impossible cast, and the
// compiler says exactly that: `cast from 'MeetingAsrRuntimeAccess' to unrelated type
// 'FluidAudioTranscriptionService' always fails`. So the attack builds, and cannot succeed:
// `as?` yields nil, `as!` traps, and neither ever produces a service. What the negative control
// asserts is that this diagnostic is PRESENT, because a regression back to an existential is
// exactly what would make it disappear.
//
// WHAT IS ENFORCED, AND WHAT IS NOT -- both stated, because round 3 and round 4 each got a
// version of this wrong by writing the guarantee more broadly than the code supported:
//
//   * ENFORCED, by the compiler, checked on every CI run by
//     `scripts/negative-controls/`: holding a `MeetingAsrRuntimeAccess` gives no way to reach
//     `FluidAudioTranscriptionService`, and therefore no way to name `cleanup()`,
//     `loadModel(for:)`, `ensureModelsLoaded(for:)` or any other eviction-capable method.
//     Downcast (`as?`/`as!`), extensions, retroactive conformances, generic constraints and
//     `Mirror` are each a separate committed attack; each fails, with its verbatim diagnostic
//     recorded next to it.
//
//   * NOT ENFORCED, and NOT claimed: this file itself names `FluidAudioTranscriptionService`,
//     because minting a capability from a service is exactly what an adapter does. Authority is
//     delegated at ONE place, `MeetingAsrRuntimeAccess.sharingDictationRuntime(of:...)`, and
//     that is deliberate and singular rather than absent. Code that already holds the concrete
//     service -- a composition root, `TranscriptionServiceRegistry` -- can still call
//     `cleanup()`; that is dictation's own lifecycle API and is not this seam's to remove.
//     What changed in round 5 is that the seam is no longer such code and can no longer become
//     such code by writing `as?`.
//
//   * NOT ENFORCED: raw-memory attacks. `unsafeBitCast` and friends defeat any Swift-level
//     boundary, and are out of scope here for the same reason `FOLLOWUPS.md` already records
//     them as out of scope for `MeetingStore`. The closures below do capture the service in
//     their context, so a determined caller who reconstructs an undocumented closure-context
//     layout can reach it. That is a cost, not a defence, and is not claimed as one.

import FluidAudio
import Foundation

/// Reads whatever `AsrManager` dictation already has loaded, or reports that none is.
///
/// Deliberately argument-less: there is no parameter by which a caller could name a different
/// model version, so a meeting-requested version switch -- the original B1 defect, which could
/// evict dictation's models mid-`transcribe` -- is not an expressible call. Deliberately neither
/// `async` nor `throws`: the implementation behind it is two stored-property reads, so it
/// contains no suspension point at which a dictation could interleave.
typealias MeetingAsrManagerBorrow = @MainActor @Sendable () -> (manager: AsrManager, version: AsrModelVersion)?

/// Whether dictation currently owns, or is waiting for, the shared `AsrManager`.
///
/// Supplied by whoever builds the meeting seam. There is deliberately NO default: a composition
/// root has to decide what "dictation is busy" means for this app rather than inherit a
/// permissive one silently. A negative control asserts that omitting it does not compile.
typealias MeetingDictationPriorityCheck = @MainActor @Sendable () -> Bool

/// Everything the meeting transcription seam is allowed to do to dictation's Parakeet runtime.
///
/// A struct of closures rather than a protocol existential, and that choice is the whole of
/// round 5's B1 fix. An existential carries its concrete type with it and hands it back to
/// anyone who writes `as?`; a closure carries no type to recover and has no members to call.
/// Both fields are `@MainActor @Sendable` closures, so this value is `Sendable` honestly --
/// without asserting anything about `FluidAudioTranscriptionService`, which is not `Sendable`
/// and which this fork will not retroactively claim is (see `FluidAudioMeetingDiarizer.swift`
/// for why a module-wide promise about somebody else's type was removed in B3).
struct MeetingAsrRuntimeAccess: Sendable {
    let borrowLoadedManager: MeetingAsrManagerBorrow
    let isDictationActiveOrPending: MeetingDictationPriorityCheck
}

extension MeetingAsrRuntimeAccess {
    /// The ONE place authority is delegated from dictation's service to the meeting seam.
    ///
    /// It names `FluidAudioTranscriptionService` because adapting a service is what it is for;
    /// every other file in the seam is then written against the capability and cannot name the
    /// service at all. Note what it does NOT do: it never stores or returns the service, and it
    /// never calls anything on it but `borrowedAsrManager()`, which is the fork-owned,
    /// argument-less, non-suspending accessor added at the authorised upstream touchpoint
    /// (`FORK-PATCHES.md`, touchpoint 4).
    @MainActor
    static func sharingDictationRuntime(
        of service: FluidAudioTranscriptionService,
        isDictationActiveOrPending: @escaping MeetingDictationPriorityCheck
    ) -> MeetingAsrRuntimeAccess {
        MeetingAsrRuntimeAccess(
            borrowLoadedManager: { service.borrowedAsrManager() },
            isDictationActiveOrPending: isDictationActiveOrPending
        )
    }
}

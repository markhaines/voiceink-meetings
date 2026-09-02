// Fork-owned (no donor equivalent). Not a port.
//
// The capability the meeting transcription seam is allowed to have over dictation's shared
// Parakeet runtime, and nothing else.
//
// FIX ROUND 4 (cross-vendor review, B4.1). Round 3 claimed three reasons a meeting could not
// evict dictation's loaded `AsrManager`. Reasons (i) and (ii) held. Reason (iii) -- "it calls
// nothing ... those remain private" -- was FALSE: `FluidAudioTranscriptionService.cleanup()` is
// `internal`, so any file in the app target, meeting files included, could compile
// `await service.cleanup()` and tear down the active dictation manager. Round 3's own comment
// noticed `cleanup()` and then substituted "is called from no meeting file", which is a
// convention sitting inside a paragraph claiming enforcement. That is the exact move this
// project's design philosophy exists to reject, and the negative-control suite did not carry the
// attack that would have caught it.
//
// The fix is capability narrowing. The meeting seam is no longer handed the concrete service at
// all; it is handed `any MeetingAsrManagerBorrowing`, whose entire surface is one argument-less
// getter. `cleanup()`, `loadModel(for:)`, `transcribe(audioURL:model:context:)` and every other
// member of the concrete class are not on this protocol, so they are not members of what the
// seam holds -- a compile error, not a rule.
// `scripts/negative-controls/FluidAudioSharedModelAttacks.swift` carries those attacks now.
//
// WHAT THIS ENFORCES, AND WHAT REMAINS CONVENTIONAL -- both stated, because the difference is
// what round 3 got wrong:
//   * ENFORCED: nothing reachable through the capability the meeting seam is given can evict,
//     load, or switch a model. `FluidAudioMeetingSegmentTranscriber`'s initializer takes this
//     protocol, so `borrowedAsrManager()` is the only member of the transcription service that
//     can be NAMED in that file; it then stores the result closed over as a
//     `MeetingAsrManagerBorrow`, which is narrower still, because a closure has no members.
//   * CONVENTIONAL: `cleanup()` is still `internal` on `FluidAudioTranscriptionService`, because
//     it is dictation's own lifecycle API with existing upstream callers and making it `private`
//     is not an accessor-sized change. Any app-target code that obtains the CONCRETE service --
//     from `TranscriptionServiceRegistry`, say -- can still call it. What is now enforced is that
//     the meeting seam never obtains that concrete type; what is conventional is that a future
//     meeting file does not go around this protocol to fetch the concrete service itself. That
//     residual is named in FOLLOWUPS.md rather than described as a guarantee.

import FluidAudio
import Foundation

/// The ONLY capability the meeting transcription seam has over dictation's shared Parakeet
/// runtime: read whatever `AsrManager` is already loaded, or find out that none is.
///
/// Deliberately not `borrowedAsrManager(for:)`: there is no argument by which a caller could name
/// a different model version, so a meeting-requested version switch -- the B1 defect -- is not an
/// expressible call. Deliberately not `async` and not `throws`: the implementation is two stored
/// property reads, so there is no suspension point at which a dictation could interleave.
protocol MeetingAsrManagerBorrowing {
    func borrowedAsrManager() -> (manager: AsrManager, version: AsrModelVersion)?
}

/// The capability once it has been closed over, which is what the meeting seam actually stores.
///
/// A closure rather than the protocol existential, for a reason that is about correctness and not
/// taste: `any MeetingAsrManagerBorrowing` is not `Sendable` (its conformer,
/// `FluidAudioTranscriptionService`, is not, and asserting otherwise would be the module-wide
/// promise about somebody else's type that B3 removed). Storing a non-`Sendable` existential on
/// an actor and reading it from a `@MainActor` method is an isolation violation that this
/// target's Swift 5 language mode only WARNS about -- the first draft of round 4 did exactly
/// that. A `@MainActor @Sendable` closure is `Sendable`, so the property is honestly
/// `nonisolated` and the whole seam type-checks clean under `-strict-concurrency=complete`,
/// which was verified directly rather than assumed from a quiet build.
///
/// It is also narrower than the protocol: a closure has no members at all, so there is nothing to
/// call on it but the capability itself.
typealias MeetingAsrManagerBorrow = @MainActor @Sendable () -> (manager: AsrManager, version: AsrModelVersion)?

/// Fork-owned retroactive conformance on a type in THIS module (not on a package type -- see
/// `FluidAudioMeetingDiarizer.swift`'s header for why that distinction is load-bearing).
/// It adds no member and changes no behaviour: `borrowedAsrManager()` is already declared on the
/// service, so this extension is the empty statement that makes the capability nameable.
/// Declared here rather than in `FluidAudioTranscriptionService.swift` so that the authorised
/// upstream touchpoint stays at exactly the lines review has already accepted.
extension FluidAudioTranscriptionService: MeetingAsrManagerBorrowing {}

/// Whether dictation currently owns, or is waiting for, the shared `AsrManager`.
///
/// FIX ROUND 4 (cross-vendor review, B4.2). Sharing the actor fixed model DUPLICATION and
/// created a latency exposure one layer down: `AsrManager` is a `public actor`, so meeting and
/// dictation inference are mutually serialized, and a dictation Mark starts a moment after a
/// meeting chunk entered `transcribe` QUEUES BEHIND that inference. Round 3's comment presented
/// that serialization purely as safety. It is both.
///
/// Read on `@MainActor` in the same synchronous step as the borrow itself (see
/// `FluidAudioMeetingSegmentTranscriber.admitAndBorrow`), which is what makes the check atomic
/// against dictation STARTING: `VoiceInkEngine` begins a dictation on `@MainActor`, so it cannot
/// flip this from false to true between the check and the borrow.
///
/// Supplied by whoever builds the meeting seam. There is deliberately NO default: a composition
/// root has to decide what "dictation is busy" means for this app rather than inherit a
/// permissive one silently. `scripts/negative-controls/FluidAudioSharedModelAttacks.swift`
/// asserts that omitting it does not compile.
typealias MeetingDictationPriorityCheck = @MainActor @Sendable () -> Bool

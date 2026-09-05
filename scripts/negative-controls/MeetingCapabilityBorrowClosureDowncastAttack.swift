// NEGATIVE CONTROL — this file MUST NOT COMPILE CLEAN. `// expect-warning:` markers; see
// MeetingCapabilityConditionalDowncastAttack.swift for why the "always fails" diagnostic is the
// proof rather than a complaint.
//
// MECHANISM UNDER TEST: downcasting the CLOSURE rather than the struct that holds it.
//
// The capability's closure is the thing that actually captures the service, so the sharper
// version of the round-4 attack targets the closure directly instead of the value wrapping it.
// Retargeted in round 6 from the removed `borrowLoadedManager` to `transcribeChunk`, which is
// now the capability's only member.
// It fails for the same structural reason: a function value's type is a function type, unrelated
// to any class, and the capture context is not addressable through the type system. (It IS
// addressable through `unsafeBitCast` and raw memory -- that is disclosed in
// `MeetingAsrSharing.swift` and in FOLLOWUPS.md as out of scope, not defended against.)
//
// Its own file because its diagnostic names `MeetingAsrManagerBorrow`, a different type from the
// two struct-downcast controls, and because keeping every downcast variant apart is what stops
// one silently covering for another.

import FluidAudio
import Foundation

@MainActor
private func downcastingTheClosureCannotRecoverTheService(access: MeetingAsrRuntimeAccess) async {
    // expect-warning: cast from 'MeetingChunkTranscriptionOperation' (aka '@MainActor @Sendable (URL) async throws -> MeetingChunkTranscriptionOutcome') to unrelated type 'FluidAudioTranscriptionService' always fails
    if let concrete = access.transcribeChunk as? FluidAudioTranscriptionService {
        await concrete.cleanup()
    }
}

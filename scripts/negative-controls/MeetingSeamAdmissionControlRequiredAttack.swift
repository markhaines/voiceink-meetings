// NEGATIVE CONTROL — this file MUST NOT COMPILE. Marker convention: see
// MeetingStoreIsolationAttacks.swift.
//
// MECHANISM UNDER TEST: whether B2's dictation-priority admission can be omitted.
//
// The admission check is what stops a meeting chunk making Mark's dictation queue behind its
// inference. Round 6 moved admission ONTO THE OWNING SIDE -- it now runs inside the capability's
// operation, next to the `AsrManager`, because that is where the decision has to be made once the
// meeting side no longer holds a manager. So the property to defend moved too: the check is a
// required parameter of the minting factory, with no default, and a capability cannot be minted
// from a service without one.
//
// What this does NOT prevent, said plainly: a composition root can still construct
// `MeetingAsrRuntimeAccess` directly with any closure it likes, including one that never checks.
// That is unchanged from round 5 and is FOLLOWUPS.md wiring-gate item 3, not a claim made here.

import FluidAudio
import Foundation

@MainActor
private func admissionControlCannotBeOmitted(service: FluidAudioTranscriptionService) {
    // expect-error: missing argument for parameter 'isDictationActiveOrPending' in call
    _ = MeetingAsrRuntimeAccess.sharingDictationRuntime(of: service)
}

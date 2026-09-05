// NEGATIVE CONTROL — this file MUST NOT COMPILE CLEAN. `// expect-warning:` markers; see
// MeetingCapabilityConditionalDowncastAttack.swift for why a warning is the load-bearing
// diagnostic for a downcast and not a weaker result than an error.
//
// MECHANISM UNDER TEST: the forced downcast, `as!`.
//
// Separate file from the conditional downcast on purpose. They are different expressions with
// different runtime behaviour -- `as?` yields nil, `as!` traps -- and sharing a file would let
// one supply the other's expected diagnostic text if one ever started compiling clean, which is
// precisely the false-all-clear the verifier's "no two controls share a diagnostic" rule exists
// to prevent. The two diagnostics here are textually identical, so they MUST live apart.

import FluidAudio
import Foundation

@MainActor
private func forcedDowncastCannotRecoverTheService(access: MeetingAsrRuntimeAccess) async {
    // expect-warning: cast from 'MeetingAsrRuntimeAccess' to unrelated type 'FluidAudioTranscriptionService' always fails
    let concrete = access as! FluidAudioTranscriptionService
    await concrete.cleanup()
}

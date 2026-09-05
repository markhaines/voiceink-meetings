// NEGATIVE CONTROL — this file MUST NOT COMPILE. Marker convention: see
// MeetingStoreIsolationAttacks.swift.
//
// MECHANISM UNDER TEST: implicit coercion by type annotation.
//
// This is the attack round 4 DID carry, and passing it is what created the false confidence:
// coercion errors, so the suite was green, while the `as?` form in the sibling file compiled
// fine and defeated the boundary. Kept because it is still a real route and must stay closed,
// and kept in its own file so it can never again stand in for the downcast it does not cover.

import FluidAudio
import Foundation

@MainActor
private func coercionCannotRecoverTheService(access: MeetingAsrRuntimeAccess) {
    // expect-error: cannot convert value of type 'MeetingAsrRuntimeAccess' to specified type 'FluidAudioTranscriptionService'
    let _: FluidAudioTranscriptionService = access
}

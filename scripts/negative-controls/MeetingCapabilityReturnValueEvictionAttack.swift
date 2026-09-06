// NEGATIVE CONTROL — this file MUST NOT COMPILE. Marker convention: see
// MeetingStoreIsolationAttacks.swift.
//
// MECHANISM UNDER TEST: FOLLOWING THE CAPABILITY'S OWN RETURN VALUE.
//
// THIS IS THE ATTACK THAT DEFEATED ROUND 5, and the reason it is worth its own file forever.
// Round 5's capability exposed `borrowLoadedManager()`, which returned the live shared
// `AsrManager`. `AsrManager.cleanup()` is ordinary public FluidAudio API that nils every loaded
// model. So this compiled, from any meeting-side file, with ZERO diagnostics:
//
//     if let manager = access.borrowLoadedManager()?.manager { await manager.cleanup() }
//
// No cast, no reflection, no `unsafeBitCast`, no recovery of `FluidAudioTranscriptionService`.
// The capability handed over the object the service existed to protect, through its front door.
//
// WHY THE SUITE MISSED IT: all ten round-5 controls attacked ROUTES TO THE SERVICE, and every one
// of them correctly failed. Not one followed what the capability RETURNED. The suite tested the
// routes its author imagined. That is the fourth defeat of this property on this project and the
// shape has been identical every time.
//
// Round 6's fix is inversion: the capability performs the operation on the owning side and
// returns a value receipt, so the meeting side never holds an `AsrManager`. Both halves of the
// old expression are therefore now unsayable, and BOTH are asserted here -- the accessor is gone,
// and so is the type it returned.

import FluidAudio
import Foundation

@MainActor
private func followingTheReturnValueReachesNoEvictionAPI(access: MeetingAsrRuntimeAccess) async throws {
    // The accessor that handed over the manager no longer exists on the capability.
    // expect-error: value of type 'MeetingAsrRuntimeAccess' has no member 'borrowLoadedManager'
    let borrowed = access.borrowLoadedManager()

    // And nothing the capability CAN return carries one, so the second half of the round-5
    // expression is a type error before it is ever a live call.
    // expect-error: value of type 'MeetingChunkTranscriptionOutcome' has no member 'manager'
    let manager = try await access.transcribeChunk(URL(fileURLWithPath: "/tmp/x.wav")).manager

    _ = borrowed
    _ = manager
}

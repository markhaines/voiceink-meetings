// NEGATIVE CONTROL — this file MUST NOT COMPILE CLEAN. Marker convention: see
// MeetingStoreIsolationAttacks.swift. This file uses `// expect-warning:` rather than
// `// expect-error:` — read the note below, it is the whole point of the control.
//
// MECHANISM UNDER TEST: the conditional downcast, `as?`.
//
// THIS IS THE ATTACK THAT DEFEATED ROUND 4, and it was missing from the suite, which is why it
// survived. Round 4 handed the meeting seam `any MeetingAsrManagerBorrowing` and claimed the
// eviction-capable methods were unreachable. An existential carries its concrete type, so this
// compiled with ZERO diagnostics against round-4 code, and `cleanup()` evicted the model out from
// under a live dictation:
//
//     if let concrete = borrowing as? FluidAudioTranscriptionService { await concrete.cleanup() }
//
// Round 5 replaced the existential with `MeetingAsrRuntimeAccess`, a struct of two closures.
//
// WHY A WARNING AND NOT AN ERROR, and why that is the stronger signal here: casting between two
// unrelated concrete types is not an error in Swift, it is a statically-proven-impossible cast,
// and the compiler says so in as many words. That diagnostic is a PROOF, not a complaint: it can
// only be emitted because the compiler can see the cast can never succeed. The control therefore
// asserts the diagnostic is PRESENT. If a future edit reverted the parameter to a protocol
// existential, the cast would become possible, the "always fails" line would DISAPPEAR, and this
// control fails on a missing expected diagnostic -- the verifier's rule (2). That absence is
// exactly the regression this file exists to catch.

import FluidAudio
import Foundation

@MainActor
private func conditionalDowncastCannotRecoverTheService(access: MeetingAsrRuntimeAccess) async {
    // expect-warning: cast from 'MeetingAsrRuntimeAccess' to unrelated type 'FluidAudioTranscriptionService' always fails
    if let concrete = access as? FluidAudioTranscriptionService {
        await concrete.cleanup()
    }
}

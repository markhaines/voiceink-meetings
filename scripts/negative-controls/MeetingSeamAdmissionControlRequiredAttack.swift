// NEGATIVE CONTROL — this file MUST NOT COMPILE. Marker convention: see
// MeetingStoreIsolationAttacks.swift.
//
// MECHANISM UNDER TEST: whether B2's dictation-priority admission can be omitted.
//
// The admission check is what stops a meeting chunk making Mark's dictation queue behind its
// inference. It is a stored property of `MeetingAsrRuntimeAccess` with no default, so a
// capability cannot be minted without one: there is no "admission off" state to construct, by
// accident or otherwise. Round 4 enforced the same property through a defaulted initializer
// parameter; making it a field is stricter, because a field cannot be forgotten at any call site.

import FluidAudio
import Foundation

@MainActor
private func admissionControlCannotBeOmitted() {
    // expect-error: missing argument for parameter 'isDictationActiveOrPending' in call
    _ = MeetingAsrRuntimeAccess(borrowLoadedManager: { nil })
}

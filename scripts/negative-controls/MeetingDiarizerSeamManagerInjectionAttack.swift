// NEGATIVE CONTROL — this file MUST NOT COMPILE. Marker convention: see
// MeetingStoreIsolationAttacks.swift.
//
// MECHANISM UNDER TEST: the diarizer's injectable load seam (round 4, B4.4).
//
// Round 3's initializer took `() async throws -> DiarizerManager`, so same-module production code
// -- not only a test -- could construct a `DiarizerManager`, RETAIN it, hand it in, and hold a
// second reference to something the actor then treated as exclusively its own. The seam now takes
// `() async throws -> Void` and the actor constructs every manager itself from `DiarizerModels`,
// whose memberwise initializer is not public. If the manager-returning signature ever returns,
// this stops being an error.

import FluidAudio
import Foundation

private func diarizerSeamCannotAcceptACallerSuppliedManager() {
    // expect-error: extra argument 'loadManager' in call
    _ = FluidAudioMeetingDiarizer(loadOperationTimeout: 1, loadManager: { DiarizerManager(config: .default) })
}

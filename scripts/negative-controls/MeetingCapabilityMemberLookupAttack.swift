// NEGATIVE CONTROL — this file MUST NOT COMPILE. Marker convention: see
// MeetingStoreIsolationAttacks.swift.
//
// MECHANISM UNDER TEST: member lookup on the capability value.
//
// The direct form: call the eviction-capable methods straight off what the meeting seam actually
// holds. `cleanup()` tears down the loaded `AsrManager` (four nil assignments to the CoreML
// models, FluidAudio `AsrManager.swift:215`); `loadModel(for:)` reaches `ensureModelsLoaded`,
// which calls `cleanupLoadedManagers()`. Neither is a member of a struct of two closures.
//
// ISOLATION: two attacks, one mechanism (member lookup), no extension/protocol/conformance in
// this file, and the two expected diagnostics differ in the member they name, so neither can
// supply the other's text.

import FluidAudio
import Foundation

@MainActor
private func evictionMembersAreNotOnTheCapability(access: MeetingAsrRuntimeAccess) async {
    // expect-error: value of type 'MeetingAsrRuntimeAccess' has no member 'cleanup'
    await access.cleanup()

    // expect-error: value of type 'MeetingAsrRuntimeAccess' has no member 'loadModel'
    try? await access.loadModel(for: FluidAudioModel.self as! FluidAudioModel)
}

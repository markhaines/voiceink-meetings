// NEGATIVE CONTROL — this file MUST NOT COMPILE. See MeetingStoreIsolationAttacks.swift for the
// `// expect-error:` marker convention the verifier reads.
//
// MECHANISM UNDER TEST: access control on `FluidAudioTranscriptionService` itself.
//
// These attacks assume the attacker has somehow obtained the CONCRETE service (a composition
// root, `TranscriptionServiceRegistry`). They assert that even then, the model-eviction path is
// not reachable, because `ensureModelsLoaded(for:)`, `cleanupLoadedManagers()`,
// `ensureUnifiedModelsLoaded()` and `ensureNemotronModelsLoaded(named:)` are `private` to that
// file. Round 2's defect was a meeting requesting a different model version, which ran
// `cleanupLoadedManagers()` -- nilling the CoreML models -- underneath a live dictation.
//
// NOT covered here, and deliberately so: `cleanup()` is `internal`, not `private`, so a holder of
// the concrete service CAN still call it. That is dictation's own lifecycle API with existing
// upstream callers, and making it `private` is a change to upstream code beyond this PR's
// authorised touchpoints. The round-5 defence is that the meeting seam never holds the concrete
// type -- see the MeetingCapability*Attack.swift files.
//
// ISOLATION: five attacks in one file, all the SAME mechanism (access control on a member).
// The file declares no extension, no protocol and no conformance, so there is nothing here that
// could grant one attack the capability another is probing for -- which is the contamination that
// made MeetingStoreRetroactiveConformanceAttack.swift its own file. The verifier's line-anchored
// matching plus its no-unattributed-diagnostics rule catches any one of them individually.

import FluidAudio
import Foundation

@MainActor
private func privateEvictionPathsAreUnreachable(service: FluidAudioTranscriptionService) async throws {
    // The round-2 API: name a model version, and eviction follows. It must not exist.
    // expect-error: argument passed to call that takes no arguments
    _ = service.borrowedAsrManager(for: AsrModelVersion.v3)

    // The loader that calls `cleanupLoadedManagers()`.
    // expect-error: 'ensureModelsLoaded' is inaccessible due to 'private' protection level
    try await service.ensureModelsLoaded(for: AsrModelVersion.v3)

    // The eviction itself.
    // expect-error: 'cleanupLoadedManagers' is inaccessible due to 'private' protection level
    await service.cleanupLoadedManagers()

    // Takes no version, but still evicts unconditionally.
    // expect-error: 'ensureUnifiedModelsLoaded' is inaccessible due to 'private' protection level
    try await service.ensureUnifiedModelsLoaded()

    // Same for the Nemotron loader.
    // expect-error: 'ensureNemotronModelsLoaded' is inaccessible due to 'private' protection level
    try await service.ensureNemotronModelsLoaded(named: "anything")
}

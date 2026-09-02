// NEGATIVE CONTROL — this file MUST NOT COMPILE. See MeetingStoreIsolationAttacks.swift for the
// `// expect-error:` marker convention the verifier reads.
//
// WHAT THIS DEFENDS. Cross-vendor review found (B1) that the round-2 meeting accessor,
// `sharedAsrManager(for version: AsrModelVersion)`, called `ensureModelsLoaded(for:)`, so a
// meeting asking for a version dictation did not have loaded ran `cleanupLoadedManagers()` --
// including `asrManager.cleanup()`, which nils out the CoreML models -- underneath a dictation
// suspended inside `AsrManager.transcribe`. `@MainActor` initiation does not prevent that: all
// of those methods suspend, so the two flows interleave.
//
// The round-3 fix is not a comment and not a convention. `borrowedAsrManager()` is synchronous,
// argument-less, and calls nothing; every method that can evict is `private` to
// `FluidAudioTranscriptionService.swift`. This file is the proof that this is true of the
// COMPILER and not just of the current call sites: it is compiled into the app target -- the
// same module every meeting file lives in, which is the realistic attacker for `private` -- and
// each attack below is an eviction route that must be rejected.
//
// Mark's daily dictation on a 16GB M2 Pro is what is being protected. Three separate guarantees
// on this project were each defeated in one line after being merely documented; the ones that
// held were the ones where the unsafe call did not exist. This is that shape.

import FluidAudio
import Foundation

@MainActor
private func meetingSeamAttacks(service: FluidAudioTranscriptionService) async throws {
    // E1. The round-2 API itself: ask for a specific version. This is the exact call that could
    // evict dictation's manager. It must not exist.
    // expect-error: argument passed to call that takes no arguments
    _ = service.borrowedAsrManager(for: AsrModelVersion.v3)

    // E2. Reach the loader directly. `ensureModelsLoaded` is the method that calls
    // `cleanupLoadedManagers()`, so if meeting-module code can call it, the accessor's shape is
    // irrelevant.
    // expect-error: 'ensureModelsLoaded' is inaccessible due to 'private' protection level
    try await service.ensureModelsLoaded(for: AsrModelVersion.v3)

    // E3. Reach the eviction directly.
    // expect-error: 'cleanupLoadedManagers' is inaccessible due to 'private' protection level
    await service.cleanupLoadedManagers()

    // E4. The unified-manager loader takes no version, but still evicts unconditionally.
    // expect-error: 'ensureUnifiedModelsLoaded' is inaccessible due to 'private' protection level
    try await service.ensureUnifiedModelsLoaded()

    // E5. Same for the Nemotron loader.
    // expect-error: 'ensureNemotronModelsLoaded' is inaccessible due to 'private' protection level
    try await service.ensureNemotronModelsLoaded(named: "anything")
}

// E7 IS DELIBERATELY ABSENT. The obvious companion attack -- "assert `DiarizerManager` is not
// `Sendable` in this target", to stop B3's retroactive `extension DiarizerManager: @unchecked
// Sendable {}` coming back -- cannot live here. This target builds in the Swift 5 language mode
// (`SWIFT_VERSION = 5.0`, no `SWIFT_STRICT_CONCURRENCY`), where a missing `Sendable` conformance
// is a WARNING, not an error; it was tried and produced no diagnostic at all, which this
// verifier correctly reported as a missing expectation rather than passing quietly. The tripwire
// for that property is therefore a text scan
// (`SharedModelDuplicationTests.diarizerDoesNotRetroactivelyConformAPackageType`), and it is
// labelled there as the weaker thing it is.

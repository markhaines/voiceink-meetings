// NEGATIVE CONTROL — this file MUST NOT COMPILE. Marker convention: see
// MeetingStoreIsolationAttacks.swift.
//
// MECHANISM UNDER TEST: can the meeting seam obtain an `AsrManager` by ANY route the capability
// offers, rather than by the one route an author happened to list?
//
// Round 5's controls each named a specific technique. This one inverts the question and asks the
// compiler to find any conversion at all: it declares a variable of type `AsrManager` and tries
// to fill it from the capability and from everything the capability returns. If any future edit
// re-exposes a manager -- as a field, a tuple member, an associated value, or a differently named
// accessor -- one of these starts compiling and the control fires.
//
// This is the control that would have caught the round-5 defeat without anyone having to imagine
// `borrowLoadedManager()?.manager` in advance.

import FluidAudio
import Foundation

@MainActor
private func noRouteFromTheCapabilityYieldsAManager(access: MeetingAsrRuntimeAccess) async throws {
    // Straight from the capability value.
    // expect-error: cannot convert value of type 'MeetingAsrRuntimeAccess' to specified type 'AsrManager'
    let fromCapability: AsrManager = access

    // From its single member's return value.
    // expect-error: cannot convert value of type 'MeetingChunkTranscriptionOutcome' to specified type 'AsrManager'
    let fromOutcome: AsrManager = try await access.transcribeChunk(URL(fileURLWithPath: "/tmp/x.wav"))

    _ = fromCapability
    _ = fromOutcome
}

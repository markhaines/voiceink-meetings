// New for this fork (Stage 2c fix round 7, cross-vendor review B2). Not a port.
//
// WHY THIS FILE EXISTS. The negative controls each attack a route someone thought of. Round 5 was
// defeated by a route nobody had listed, and round 6's replacement control had the same weakness
// one level down: it would have kept passing if an outcome case had started carrying an
// `AsrManager`, because it only ever converted the whole enum.
//
// So this file is not an attack. It is a set of FAILS-CLOSED guards: they do not test that a
// specific bad thing is impossible, they stop COMPILING when the shape they depend on grows. That
// is the only mechanism here that catches a hazard added later by someone who never read any of
// this.
//
// Each guard below is a compile-time assertion. If it breaks, the test target fails to build and
// CI goes red before a single test runs -- which is the point: a guard that can be skipped is not
// a guard.

import FluidAudio
import Foundation
import Testing

@testable import VoiceInk

@Suite("Meeting capability: fails-closed surface guards")
@MainActor
struct MeetingCapabilitySurfaceGuardTests {

    /// GUARD 1 -- the capability's STORED-PROPERTY surface.
    ///
    /// This calls the memberwise initializer with exactly one argument. Swift synthesises that
    /// initializer from the stored properties, so adding a second stored property to
    /// `MeetingAsrRuntimeAccess` -- for instance one holding or vending an `AsrManager` -- makes
    /// this call fail with "missing argument for parameter", and the test target stops compiling.
    ///
    /// The runtime `Mirror` assertion is a second, independent expression of the same property:
    /// `Mirror` sees stored properties, so a new one changes the count. Belt and braces on
    /// purpose, because this is the guard that has to survive an editor who is not reading
    /// comments.
    @Test("the capability has exactly one stored member, and it is the operation")
    func capabilityStoredSurfaceIsExactlyTheOperation() {
        let capability = MeetingAsrRuntimeAccess(
            transcribeChunk: { _ in .sharedModelNotLoaded }
        )

        let children = Array(Mirror(reflecting: capability).children)
        #expect(children.count == 1)
        #expect(children.first?.label == "transcribeChunk")
    }

    /// GUARD 2 -- the outcome's CASE surface.
    ///
    /// An exhaustive switch with no `default:`. Adding a case to
    /// `MeetingChunkTranscriptionOutcome` -- including one carrying an `AsrManager` -- makes this
    /// non-exhaustive and the test target stops compiling.
    ///
    /// `MeetingSeamCannotNameAsrManagerAttack.swift` carries the same structure for the same
    /// reason. Two independent files failing closed on the same change is deliberate: the
    /// negative-control suite and the test suite are run by different CI steps, so neither one
    /// being skipped or misconfigured silently drops the guarantee.
    @Test("the outcome has exactly three cases, and only one carries a payload")
    func outcomeCaseSurfaceIsExactlyThreeCases() {
        let receipt = MeetingChunkTranscription(
            text: "hi",
            duration: 1.0,
            tokenSpans: [MeetingTokenSpan(token: "hi", start: 0, end: 1)]
        )

        for outcome: MeetingChunkTranscriptionOutcome in [
            .transcribed(receipt), .dictationHasPriority, .sharedModelNotLoaded,
        ] {
            switch outcome {
            case .transcribed(let payload):
                // The payload's own stored surface, guarded the same way as the capability's:
                // a new field on the receipt changes this count.
                #expect(Mirror(reflecting: payload).children.count == 3)
            case .dictationHasPriority:
                #expect(outcome == .dictationHasPriority)
            case .sharedModelNotLoaded:
                #expect(outcome == .sharedModelNotLoaded)
            }
        }
    }

    /// GUARD 3 -- the receipt's transitive value-ness.
    ///
    /// `MeetingChunkTranscription` and `MeetingTokenSpan` are declared `Equatable`. That is not
    /// decoration: `AsrManager` is an actor and cannot be `Equatable`, so a field holding one
    /// would break the synthesised conformance and stop this compiling. It is a weak guard on its
    /// own (a manager could be smuggled behind a hand-written `==`), which is why it is listed
    /// third rather than relied on.
    @Test("the receipt is a value type all the way down")
    func receiptIsAValueTypeAllTheWayDown() {
        let a = MeetingChunkTranscription(text: "x", duration: 1, tokenSpans: nil)
        let b = MeetingChunkTranscription(text: "x", duration: 1, tokenSpans: nil)
        #expect(a == b)

        let span = MeetingTokenSpan(token: "t", start: 0, end: 1)
        #expect(span == MeetingTokenSpan(token: "t", start: 0, end: 1))
    }

    /// WHAT NONE OF THESE CATCH, recorded here rather than left to be discovered.
    ///
    /// A COMPUTED member or method added to `MeetingAsrRuntimeAccess` in an extension --
    /// `var liveManager: AsrManager { ... }` -- is caught by none of the guards above. `Mirror`
    /// does not see computed properties, the memberwise initializer does not gain a parameter,
    /// and no exhaustiveness rule applies to a type's method list. Swift offers no cheap
    /// structural way to assert "this type has no other members".
    ///
    /// This is why the claim in `MeetingAsrSharing.swift` is scoped to what the capability's
    /// declared RETURN TYPES can yield, rather than to the whole member surface. That claim stays
    /// true regardless of what members exist, because every member would still have to return
    /// something, and a manager-returning member is the thing a reviewer would have to catch.
    /// Stated plainly rather than papered over: this is a real gap in automated coverage.
    @Test("documented gap: a computed manager-returning member would not be caught structurally")
    func documentedGapComputedMembersAreNotStructurallyGuarded() {
        // Nothing to assert; the value of this case is that the gap is named in the suite rather
        // than only in a comment, so it shows up when someone reads the test list.
        #expect(Bool(true))
    }
}

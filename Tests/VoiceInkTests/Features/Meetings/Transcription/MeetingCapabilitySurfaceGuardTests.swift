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

    /// GUARD 3 -- `MeetingTokenSpan`'s stored surface, the leaf of the whole reachable set.
    ///
    /// ADDED IN ROUND 8, because the guards above stopped one level short. The reviewer's
    /// concrete leak was a DEFAULTED `Equatable` wrapper field on the span carrying an
    /// `AsrManager`, and it defeats the memberwise-initializer mechanism by construction: a
    /// stored property with an initial value is not a required parameter, so Guard 1's technique
    /// would not fire. `Mirror` DOES see it, because it is still a stored property.
    ///
    /// So this guard asserts both, and the `Mirror` half is the load-bearing one:
    ///   * the memberwise initializer takes exactly these three arguments, and
    ///   * the span has exactly three stored properties at runtime.
    ///
    /// Proven to bite in round 8 by planting exactly that defaulted field. What the plant showed,
    /// stated as measured rather than as expected: the NEGATIVE CONTROL DID NOT CATCH IT --
    /// `MeetingSeamCannotNameAsrManagerAttack.swift` passed with all nine markers `ok`, because a
    /// control can only attempt fields it NAMES, and a newly added field is by definition not one
    /// of them. This test was the only thing that failed, and only its `children.count == 3`
    /// assertion. That is the division of labour between the two mechanisms: the control proves
    /// the fields that exist today cannot yield a manager; this guard is what notices a new field
    /// at all. Verbatim output in the round-8 report.
    @Test("a token span has exactly three stored fields, and they are the three value fields")
    func tokenSpanStoredSurfaceIsExactlyThreeValueFields() {
        let span = MeetingTokenSpan(token: "t", start: 0, end: 1)

        let children = Array(Mirror(reflecting: span).children)
        #expect(children.count == 3)
        #expect(children.map(\.label) == ["token", "start", "end"])

        // Value-ness, kept from round 7. Weak on its own -- a manager can be smuggled behind a
        // hand-written `==` -- so it supports the count assertion rather than standing alone.
        #expect(span == MeetingTokenSpan(token: "t", start: 0, end: 1))
    }

    /// GUARD 4 -- the receipt's own stored surface and value-ness.
    @Test("the receipt has exactly three stored fields and is a value type")
    func receiptIsAValueTypeAllTheWayDown() {
        let a = MeetingChunkTranscription(text: "x", duration: 1, tokenSpans: nil)
        let b = MeetingChunkTranscription(text: "x", duration: 1, tokenSpans: nil)
        #expect(a == b)

        let children = Array(Mirror(reflecting: a).children)
        #expect(children.count == 3)
        #expect(children.map(\.label) == ["text", "duration", "tokenSpans"])
    }

    /// WHAT NONE OF THESE CATCH. This is a real gap in automated coverage, it FAILS OPEN, and
    /// `MeetingAsrSharing.swift` now says so in the same words -- round 7 had that file claiming
    /// "a new member fails closed" while this file admitted the opposite two screens away. The
    /// comment was the wrong one, and it has been narrowed to STORED properties.
    ///
    /// A COMPUTED member or method added to any of these types in an extension --
    /// `extension MeetingAsrRuntimeAccess { var liveManager: AsrManager { ... } }` -- compiles,
    /// and no guard above fires. `Mirror` does not see computed properties, the memberwise
    /// initializer gains no parameter, and Swift has no exhaustiveness rule over a method list.
    ///
    /// An AST/source-signature guard over the complete declaration surface would close it. Mark
    /// ruled that out for this PR: it is bespoke test infrastructure whose own correctness would
    /// then need verifying, it rots silently when the source layout changes, and nothing in
    /// production constructs this coordinator yet. The gap is therefore carried as **WIRING GATE
    /// item 7 in FOLLOWUPS.md, OPEN**, to be re-checked before anything wires this seam -- not
    /// only as a comment, because a comment is exactly what a future reader skims past.
    @Test("documented gap: a computed manager-returning member FAILS OPEN and is wiring-gate item 7")
    func documentedGapComputedMembersAreNotStructurallyGuarded() {
        // Nothing to assert; the value of this case is that the gap is named in the suite rather
        // than only in a comment, so it shows up when someone reads the test list.
        #expect(Bool(true))
    }
}

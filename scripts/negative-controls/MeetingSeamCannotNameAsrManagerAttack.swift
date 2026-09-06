// NEGATIVE CONTROL — this file MUST NOT COMPILE. Marker convention: see
// MeetingStoreIsolationAttacks.swift.
//
// MECHANISM UNDER TEST: can any value the capability hands back BE, or CONTAIN, the live shared
// `AsrManager`?
//
// ROUND 7 REWRITE, because the round-6 version did not prove its own claim. It said the outcome
// type cannot yield an `AsrManager`, but it only attempted to convert the WHOLE
// `MeetingChunkTranscriptionOutcome`. That fails for a trivial reason -- Swift never implicitly
// unwraps an enum's associated values -- so the control would have kept passing even if a case
// DID carry a manager. A control that cannot fail is not a control.
//
// This version DESTRUCTURES. It switches over every case, binds every payload, and attempts to
// type each bound value, and every value transitively reachable from it DOWN TO THE LEAF FIELDS,
// as `AsrManager`. Round 8 extended it to the leaves: round 7 stopped at `MeetingTokenSpan?` and
// still claimed to cover everything reachable, which was the same defect one level deeper. If any payload ever
// carried one, the corresponding line would stop erroring and the verifier would report a MISSING
// diagnostic.
//
// The switch is deliberately EXHAUSTIVE WITH NO `default:`. That is load-bearing, not style: if a
// new case is added to `MeetingChunkTranscriptionOutcome` -- including one carrying a manager --
// this switch stops compiling with a non-exhaustive error on an UNMARKED line, and the verifier's
// stray-diagnostic rule fails the control. That is how this file fails CLOSED against a payload
// route nobody has thought of yet. Proven by temporarily adding such a case in round 7: the
// control failed, exactly as intended, and the verbatim output is quoted in the round-7 report.
//
// WHAT THIS FILE DOES NOT COVER, stated so the claim stays narrow enough to be true:
//   * It does not prove another meeting file cannot construct its OWN `AsrManager`. It can; any
//     file may `import FluidAudio`. That is not the hazard. Obtaining the LIVE SHARED instance is.
//   * It does not catch a new COMPUTED member or method added to the capability in an extension.
//     Stored properties and enum cases fail closed (here and in `MeetingCapabilitySurfaceGuardTests`);
//     computed members do not, and no cheap structural guard for them exists. See that test file.

import FluidAudio
import Foundation

@MainActor
private func noValueTheCapabilityReturnsIsOrContainsAManager(
    access: MeetingAsrRuntimeAccess
) async throws {
    // The capability value itself.
    // expect-error: cannot convert value of type 'MeetingAsrRuntimeAccess' to specified type 'AsrManager'
    let fromCapability: AsrManager = access

    let outcome = try await access.transcribeChunk(URL(fileURLWithPath: "/tmp/x.wav"))

    // Exhaustive, no `default:` -- see the header. A new case breaks this switch.
    switch outcome {
    case .transcribed(let receipt):
        // The payload itself...
        // expect-error: cannot convert value of type 'MeetingChunkTranscription' to specified type 'AsrManager'
        let fromReceipt: AsrManager = receipt

        // ...and every field reachable from it, one level down.
        // expect-error: cannot convert value of type 'String' to specified type 'AsrManager'
        let fromText: AsrManager = receipt.text

        // expect-error: cannot convert value of type 'TimeInterval' (aka 'Double') to specified type 'AsrManager'
        let fromDuration: AsrManager = receipt.duration

        // expect-error: cannot convert value of type '[MeetingTokenSpan]?' to specified type 'AsrManager'
        let fromSpans: AsrManager = receipt.tokenSpans

        // ...and two levels down, the array element itself...
        // expect-error: cannot convert value of type 'MeetingTokenSpan?' to specified type 'AsrManager'
        let fromSpan: AsrManager = receipt.tokenSpans?.first

        // ...and three levels down, EVERY LEAF FIELD of that element individually. Round 7
        // stopped at the element and claimed to have tested everything transitively reachable,
        // which was not true: a span field carrying a manager would have gone untested. The
        // reviewer's concrete leak was a defaulted `Equatable` wrapper field on the span, which
        // is invisible to the memberwise-initializer guard precisely because it is defaulted.
        // expect-error: cannot convert value of type 'String?' to specified type 'AsrManager'
        let fromToken: AsrManager = receipt.tokenSpans?.first?.token

        // expect-error: cannot convert value of type 'TimeInterval?' (aka 'Optional<Double>') to specified type 'AsrManager'
        let fromStart: AsrManager = receipt.tokenSpans?.first?.start

        // expect-error: cannot convert value of type 'TimeInterval?' (aka 'Optional<Double>') to specified type 'AsrManager'
        let fromEnd: AsrManager = receipt.tokenSpans?.first?.end

        _ = fromReceipt
        _ = fromText
        _ = fromDuration
        _ = fromSpans
        _ = fromSpan
        _ = fromToken
        _ = fromStart
        _ = fromEnd

    case .dictationHasPriority:
        break

    case .sharedModelNotLoaded:
        break
    }

    _ = fromCapability
}

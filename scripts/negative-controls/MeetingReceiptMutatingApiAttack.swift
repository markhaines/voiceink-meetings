// NEGATIVE CONTROL — this file MUST NOT COMPILE. Marker convention: see
// MeetingStoreIsolationAttacks.swift.
//
// MECHANISM UNDER TEST: reaching mutating API TRANSITIVELY through the returned receipt.
//
// The round-5 lesson generalised. It is not enough that the capability stops returning an
// `AsrManager`; what it DOES return must have no reachable API that mutates shared state, or the
// same defeat reappears one field deeper. So this file walks the receipt's entire surface and
// tries the three state-mutating members `AsrManager` actually has -- `cleanup()`,
// `loadModels(_:)` and `reset()` -- against the receipt and against what its fields yield.
//
// `MeetingChunkTranscription` is transitively `String`, `TimeInterval` and
// `[MeetingTokenSpan]?`, where `MeetingTokenSpan` is itself three value fields. That is the whole
// surface, which is why this control can be exhaustive rather than a list of guesses.
//
// ISOLATION: several attacks, one mechanism (member lookup on a returned value). No extension,
// protocol or conformance is declared in this file, so nothing here can grant another attack the
// capability it is probing for. Each expected diagnostic names a different member or type, so
// none can supply another's text.

import FluidAudio
import Foundation

@MainActor
private func theReceiptExposesNoMutatingApi(receipt: MeetingChunkTranscription) async {
    // expect-error: value of type 'MeetingChunkTranscription' has no member 'cleanup'
    await receipt.cleanup()

    // expect-error: value of type 'MeetingChunkTranscription' has no member 'reset'
    receipt.reset()

    // expect-error: value of type 'MeetingChunkTranscription' has no member 'loadModels'
    try? await receipt.loadModels()

    // The receipt must not carry the manager under another name either.
    // expect-error: value of type 'MeetingChunkTranscription' has no member 'manager'
    _ = receipt.manager

    // One field deeper: a token span is three value fields and nothing else.
    // expect-error: value of type 'MeetingTokenSpan' has no member 'cleanup'
    receipt.tokenSpans?.first?.cleanup()
}

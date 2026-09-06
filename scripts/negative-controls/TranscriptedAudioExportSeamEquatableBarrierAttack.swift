// Structural negative control: the STRUCTURAL half of `FaultInjection`'s data-only guarantee.
//
// `TranscriptedAudioExportSeamAttacks.swift` next door pins six exact expressions. Review pointed
// out that this is not the same as pinning the invariant: someone adding a differently-named
// closure-bearing field (`operationOverride`, say) would leave all six of those diagnostics intact
// and the runner would pass, so CI would be guarding today's SPELLING rather than the property.
//
// It turns out the property is already enforced, for free, by the type system. `FaultInjection`
// declares `Equatable`, and Swift only SYNTHESISES `Equatable` when every stored property is itself
// `Equatable`. A closure is not. Verified empirically rather than reasoned about: planting
// `var operationOverride: (() -> Void)?` on the type and running a full `xcodebuild` produces
//
//     error: type 'TranscriptedAudioExporter.FaultInjection' does not conform to protocol 'Equatable'
//
// So ANY closure-bearing stored field fails to build today, under any name -- which is a stronger
// guarantee than the six expressions next door, and one nobody had to build.
//
// That makes the conformance load-bearing rather than decorative, and this file exists so it cannot
// be quietly dropped. A stored property cannot be added to a type from another file, but a
// conformance CAN be asserted from one: the attack below is a redundant conformance, which is an
// error only while `FaultInjection` still declares `Equatable` itself. Remove that conformance and
// this diagnostic disappears, the runner reports a missing expectation, and CI fails. See
// `TranscriptedAudioExportSeamSendableBarrierAttack.swift` for the same guard on `Sendable`, the
// barrier that becomes a hard error under the Swift 6 language mode.
//
// WHAT THIS DOES NOT PIN, stated so it is a known gap rather than an implied guarantee: someone
// hand-writing a `static func ==` suppresses synthesis, after which a closure field would compile
// again with the conformance still declared and this attack still firing. A negative control in
// another file cannot detect that, because a user-defined `==` simply replaces synthesis without
// any diagnostic of its own. Recorded in FOLLOWUPS.md rather than left implied.

import Foundation

// expect-error: redundant conformance of 'TranscriptedAudioExporter.FaultInjection' to protocol 'Equatable'
extension TranscriptedAudioExporter.FaultInjection: Equatable {}

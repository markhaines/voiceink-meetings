// Structural negative control: the STRUCTURAL half of `FaultInjection`'s data-only guarantee.
//
// `TranscriptedAudioExportSeamAttacks.swift` next door pins six exact expressions. Review pointed
// out that this is not the same as pinning the invariant: someone adding a differently-named
// closure-bearing field (`operationOverride`, say) would leave all six of those diagnostics intact
// and the runner would pass, so CI would be guarding today's SPELLING rather than the property.
//
// PART of that property is enforced for free by the type system. `FaultInjection` declares
// `Equatable`, and Swift only SYNTHESISES `Equatable` when every stored property is itself
// `Equatable`. A closure is not. Verified empirically rather than reasoned about: planting
// `var operationOverride: (() -> Void)?` on the type and running a full `xcodebuild` produces
//
//     error: type 'TranscriptedAudioExporter.FaultInjection' does not conform to protocol 'Equatable'
//
// So a DIRECTLY STORED closure-typed property fails to build today, under any name. That is worth
// having and nobody had to build it -- but it is one SHAPE of re-introduction, not the class, and
// an earlier version of this header wrongly claimed the latter.
//
// WHAT IS NOT COVERED, so a reader meets the whole gap rather than one instance of it. All four of
// these leave synthesis intact and leave this control green:
//   1. a stored field whose type is an `Equatable`, `@unchecked Sendable` WRAPPER containing a
//      closure -- the stored property is `Equatable`, so synthesis is untroubled;
//   2. a property wrapper whose stored backing type is `Equatable` while its `wrappedValue` is a
//      closure -- the same, one level of indirection further;
//   3. a COMPUTED closure property or a method, including one added in an extension -- no stored
//      property is involved, so synthesis never looks at it;
//   4. a hand-written `static func ==`, which suppresses synthesis outright.
// The first two restore a fully executable `operationOverride`-equivalent seam. Detecting any of
// them needs source-signature or AST machinery whose own correctness would then need verifying and
// which rots silently when the source layout changes; that is deliberately not built here, the same
// ruling this project made on the summary parser's computed-member gap. Recorded as its own item in
// FOLLOWUPS.md.
//
// WHAT THIS FILE DOES PIN, exactly: that `FaultInjection` still DECLARES `Equatable`, so the one
// shape that is covered stays covered. A stored property cannot be added to a type from another
// file, but a conformance CAN be asserted from one: the attack below is a redundant conformance,
// which is an error only while the type still declares `Equatable` itself. Remove that conformance
// and this diagnostic disappears, the runner reports a missing expectation, and CI fails.
//
// See `TranscriptedAudioExportSeamSendableBarrierAttack.swift` for the matching guard on
// `Sendable`. Note that `Sendable` is NOT a second barrier today -- this project builds at
// `SWIFT_VERSION 5.0` with no strict concurrency, so a non-`Sendable` stored closure only warns.
// That control pins a FUTURE barrier, real under the Swift 6 language mode.

import Foundation

// expect-error: redundant conformance of 'TranscriptedAudioExporter.FaultInjection' to protocol 'Equatable'
extension TranscriptedAudioExporter.FaultInjection: Equatable {}

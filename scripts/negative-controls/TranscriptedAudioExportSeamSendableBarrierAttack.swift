// Structural negative control: a FUTURE barrier on `FaultInjection`, which enforces nothing today.
//
// Read that first line literally. This project builds at `SWIFT_VERSION 5.0` with no strict
// concurrency, so a non-`Sendable` stored closure on a `Sendable`-conforming struct is only a
// WARNING here -- `Sendable` prevents nothing in the current language mode, and an earlier version
// of this header wrongly called it a second present barrier. Under the Swift 6 language mode the
// same diagnostic becomes an error, and at that point it does bite:
//
//     warning: stored property 'operationOverride' of 'Sendable'-conforming struct 'FaultInjection'
//              contains non-Sendable type '() -> ()'; this is an error in the Swift 6 language mode
//
// The barrier that is real TODAY is synthesised `Equatable`, and only for a directly stored
// closure-typed property; see `TranscriptedAudioExportSeamEquatableBarrierAttack.swift` for what
// that does and does not cover.
//
// This is a MUST-WARN case, and deliberately so. A redundant `Sendable` conformance is a warning
// rather than an error, so unlike its sibling this file COMPILES; what it asserts is that the
// conformance is still declared on the type. Drop `Sendable` from `FaultInjection` and this warning
// disappears, the runner reports a missing expectation, and CI fails. Same shape as the three
// `must-warn` downcast controls in this directory: the build succeeding is not the result, the
// diagnostic is.

import Foundation

// expect-warning: redundant conformance of 'TranscriptedAudioExporter.FaultInjection' to protocol 'Sendable'
extension TranscriptedAudioExporter.FaultInjection: Sendable {}

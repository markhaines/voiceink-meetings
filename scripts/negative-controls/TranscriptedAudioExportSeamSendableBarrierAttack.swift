// Structural negative control: the SECOND barrier keeping `FaultInjection` free of closures.
//
// Companion to `TranscriptedAudioExportSeamEquatableBarrierAttack.swift`, which carries the full
// reasoning. Short version: a closure-bearing stored property on `FaultInjection` already fails to
// build, because synthesised `Equatable` requires every stored property to be `Equatable`. The same
// field independently trips `Sendable`, which today is a warning and under the Swift 6 language
// mode is an error:
//
//     warning: stored property 'operationOverride' of 'Sendable'-conforming struct 'FaultInjection'
//              contains non-Sendable type '() -> ()'; this is an error in the Swift 6 language mode
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

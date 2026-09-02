// Ported verbatim from Muesli-HQ/muesli
// (native/MuesliNative/Tests/MuesliTests/TranscriptReconcilerTests.swift).
// Import lines changed: `import MuesliCore` dropped (SpeechSegment is in this fork's VoiceInk
// target already, same as the production file) and `@testable import MuesliNativeApp` ->
// `@testable import VoiceInk` (this fork's module name). No other change.
//
// MIT License
//
// Copyright (c) 2026 Pranav Hari
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// See NOTICE for full attribution.

import FluidAudio
import Testing
@testable import VoiceInk

@Suite("TranscriptReconciler")
struct TranscriptReconcilerTests {

    @Test("keeps overlapping mic turns when preserving local speech is safer")
    func keepsOverlappingMicTurn() {
        let mic = [
            SpeechSegment(start: 0.0, end: 0.8, text: "barking first")
        ]
        let system = [
            SpeechSegment(start: 0.0, end: 1.2, text: "barking first, but")
        ]

        let reconciled = TranscriptReconciler.reconcile(
            micTurns: mic,
            systemSegments: system,
            diarizationSegments: nil
        )

        #expect(reconciled.micSegments.count == 1)
        #expect(reconciled.micSegments[0].text == "barking first")
        #expect(reconciled.systemSegments.count == 1)
    }

    @Test("keeps substantive mic interruptions over system audio")
    func keepsSubstantiveMicInterruption() {
        let mic = [
            SpeechSegment(start: 1.0, end: 2.0, text: "wait hold on a second")
        ]
        let system = [
            SpeechSegment(start: 0.8, end: 2.2, text: "can you hear me okay"),
            SpeechSegment(start: 1.05, end: 1.15, text: "can")
        ]

        let reconciled = TranscriptReconciler.reconcile(
            micTurns: mic,
            systemSegments: system,
            diarizationSegments: [makeDiarSeg(speakerId: "spk_0", start: 0.5, end: 2.5)]
        )

        #expect(reconciled.micSegments.count == 1)
        #expect(reconciled.micSegments[0].text == "wait hold on a second")
        #expect(reconciled.systemSegments.count == 1)
        #expect(reconciled.systemSegments[0].text == "can you hear me okay")
    }

    @Test("keeps ambiguous long mic turns when overlap cannot be resolved confidently")
    func keepsAmbiguousLongMicTurn() {
        let mic = [
            SpeechSegment(
                start: 10.0,
                end: 14.0,
                text: "Nice to meet you everyone and thanks for joining the creative team"
            )
        ]
        let system = [
            SpeechSegment(start: 10.1, end: 11.0, text: "Nice to meet you Timothy"),
            SpeechSegment(start: 11.1, end: 12.2, text: "I am the digital content executive director"),
            SpeechSegment(start: 12.3, end: 13.7, text: "Happy to be here and thanks for having me")
        ]

        let reconciled = TranscriptReconciler.reconcile(
            micTurns: mic,
            systemSegments: system,
            diarizationSegments: nil
        )

        #expect(reconciled.micSegments.count == 1)
        #expect(reconciled.micSegments[0].text.contains("Nice to meet you everyone"))
        #expect(reconciled.systemSegments.count == 3)
    }

    @Test("keeps Devanagari system turns")
    func keepsDevanagariSystemTurns() {
        let system = [
            SpeechSegment(start: 2.0, end: 4.0, text: "रिश्ते में संवाद जरूरी है")
        ]

        let reconciled = TranscriptReconciler.reconcile(
            micTurns: [],
            systemSegments: system,
            diarizationSegments: nil
        )

        #expect(reconciled.systemSegments.count == 1)
        #expect(reconciled.systemSegments[0].text == "रिश्ते में संवाद जरूरी है")
    }

    @Test("preserves Indic combining marks while deduplicating short overlaps")
    func preservesIndicCombiningMarksDuringDeduplication() {
        let system = [
            SpeechSegment(start: 0.0, end: 0.8, text: "कि"),
            SpeechSegment(start: 0.1, end: 0.7, text: "क")
        ]

        let reconciled = TranscriptReconciler.reconcile(
            micTurns: [],
            systemSegments: system,
            diarizationSegments: nil
        )

        #expect(reconciled.systemSegments.map(\.text) == ["कि", "क"])
    }

    private func makeDiarSeg(speakerId: String, start: Float, end: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerId,
            embedding: [],
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: 1.0
        )
    }
}

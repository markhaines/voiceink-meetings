// Ported verbatim from Muesli-HQ/muesli
// (native/MuesliNative/Tests/MuesliTests/SystemTurnNormalizerTests.swift).
// Import lines changed: `@testable import MuesliNativeApp` -> `@testable import VoiceInk`
// (this fork's module name). No other change.
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

@Suite("SystemTurnNormalizer")
struct SystemTurnNormalizerTests {

    @Test("uses chunk text as the primary readable system transcript")
    func usesChunkText() {
        let result = SpeechTranscriptionResult(
            text: "This is a private limited entity. There would be three entities.",
            segments: [
                SpeechSegment(start: 0.0, end: 0.1, text: "This"),
                SpeechSegment(start: 0.1, end: 0.2, text: "is"),
                SpeechSegment(start: 0.2, end: 0.3, text: "a"),
                SpeechSegment(start: 0.3, end: 0.4, text: "private"),
            ]
        )

        let normalized = SystemTurnNormalizer.normalize(
            result: result,
            startTime: 10.0,
            endTime: 14.0
        )

        #expect(normalized.count == 2)
        #expect(normalized[0].text == "This is a private limited entity.")
        #expect(normalized[1].text == "There would be three entities.")
    }

    @Test("falls back to one chunk when no sentence boundaries exist")
    func fallsBackToChunkText() {
        let result = SpeechTranscriptionResult(
            text: "There would be one LLP in India right",
            segments: [
                SpeechSegment(start: 0.0, end: 0.1, text: "There"),
                SpeechSegment(start: 0.1, end: 0.2, text: "would"),
            ]
        )

        let normalized = SystemTurnNormalizer.normalize(
            result: result,
            startTime: 0,
            endTime: 3
        )

        #expect(normalized.count == 1)
        #expect(normalized[0].text == "There would be one LLP in India right")
        #expect(normalized[0].start == 0)
        #expect(normalized[0].end == 3)
    }
}

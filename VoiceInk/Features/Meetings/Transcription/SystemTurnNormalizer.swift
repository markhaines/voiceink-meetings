// Ported verbatim from Muesli-HQ/muesli
// (native/MuesliNative/Sources/MuesliNativeApp/SystemTurnNormalizer.swift). No changes.
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
import Foundation
import NaturalLanguage

enum SystemTurnNormalizer {
    static func normalize(
        result: SpeechTranscriptionResult,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> [SpeechSegment] {
        let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return [] }

        let clampedEndTime = max(endTime, startTime + 0.1)
        let units = sentenceUnits(from: trimmedText)
        guard units.count > 1 else {
            return [SpeechSegment(start: startTime, end: clampedEndTime, text: trimmedText)]
        }

        let weights = units.map(visibleLength)
        let totalWeight = max(weights.reduce(0, +), 1)
        let totalDuration = max(clampedEndTime - startTime, 0.1)

        var cursor = startTime
        var normalized: [SpeechSegment] = []

        for (index, unit) in units.enumerated() {
            let remainingDuration = clampedEndTime - cursor
            let duration: TimeInterval
            if index == units.count - 1 {
                duration = max(remainingDuration, 0.05)
            } else {
                duration = max(totalDuration * (Double(weights[index]) / Double(totalWeight)), 0.05)
            }
            let segmentEnd = min(clampedEndTime, cursor + duration)
            normalized.append(SpeechSegment(start: cursor, end: max(segmentEnd, cursor), text: unit))
            cursor = segmentEnd
        }

        return normalized
    }

    private static func sentenceUnits(from text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var units: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                units.append(String(sentence))
            }
            return true
        }

        if units.isEmpty {
            let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? [] : [fallback]
        }

        return units
    }

    private static func visibleLength(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + (CharacterSet.whitespacesAndNewlines.contains(scalar) ? 0 : 1)
        }
    }
}

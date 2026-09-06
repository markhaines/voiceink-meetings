// New fork-authored test file — NOT a port from Muesli-HQ/muesli's own test suite.
//
// Added in a fix round after independent review of PR #10 approved the port of
// MicTurnNormalizer.swift/SystemTurnNormalizer.swift as byte-identical to the donor, but noted
// that MicTurnNormalizer's private `mergeAdjacentSegments` was the one path in the ported
// cluster unconstrained by any donor test: none of the ported donor tests exercise it actually
// merging two segments into one (see the "Known test-coverage gap" note this file closes, in
// FORK-PATCHES.md's `turn-normalizers` section and .tandem/.../turn-normalizers.md). Every
// expected value below was hand-derived from `mergeAdjacentSegments`, `isFragmented` and
// `joinText` as ported (VoiceInk/Features/Meetings/Transcription/MicTurnNormalizer.swift,
// lines 85-121 and 192-208) — not by running the code first and asserting whatever it printed.
//
// Carries the same MIT header as every ported file in this cluster because it directly targets
// and pins constants owned by the MIT-licensed donor code it tests (see NOTICE).
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

import Testing
@testable import VoiceInk

@Suite("MicTurnNormalizer.mergeAdjacentSegments")
struct MicTurnNormalizerMergeTests {

    // MARK: - The 0.35s general merge gap (`maxMergeGapSeconds`)

    @Test("gap just under 0.35s merges into one segment")
    func gapJustUnderThresholdMerges() {
        // Neither segment is short (visibleLength >= 8 for both), so only the plain
        // gap <= 0.35s rule (branch 1 of `shouldMerge`) can cause a merge here — the
        // short-side 1.5s cap cannot rescue it either way. gap = 1.34 - 1.0 = 0.34 <= 0.35.
        let result = SpeechTranscriptionResult(
            text: "we should ship this feature before the end of the week",
            segments: [
                SpeechSegment(start: 0.0, end: 1.0, text: "we should ship this feature"),
                SpeechSegment(start: 1.34, end: 2.34, text: "before the end of the week"),
            ]
        )

        let segments = MicTurnNormalizer.normalize(result: result, startTime: 0.0, endTime: 100.0)

        // merged.start = previous.start; merged.end = max(previous.end, segment.end);
        // merged.text = joinText(...) -> neither side ends/starts on whitespace or punctuation,
        // so joinText falls through to its final "lhs + \" \" + rhs" branch.
        #expect(segments.count == 1)
        #expect(segments[0].start == 0.0)
        #expect(segments[0].end == 2.34)
        #expect(segments[0].text == "we should ship this feature before the end of the week")
    }

    @Test("gap just over 0.35s keeps segments separate")
    func gapJustOverThresholdStaysSeparate() {
        // Same segments as above, gap widened by 0.02s: 1.36 - 1.0 = 0.36 > 0.35, and neither
        // segment is short, so none of the three `shouldMerge` branches fire.
        let result = SpeechTranscriptionResult(
            text: "we should ship this feature before the end of the week",
            segments: [
                SpeechSegment(start: 0.0, end: 1.0, text: "we should ship this feature"),
                SpeechSegment(start: 1.36, end: 2.36, text: "before the end of the week"),
            ]
        )

        let segments = MicTurnNormalizer.normalize(result: result, startTime: 0.0, endTime: 100.0)

        #expect(segments.count == 2)
        #expect(segments[0].start == 0.0)
        #expect(segments[0].end == 1.0)
        #expect(segments[0].text == "we should ship this feature")
        #expect(segments[1].start == 1.36)
        #expect(segments[1].end == 2.36)
        #expect(segments[1].text == "before the end of the week")
    }

    // MARK: - The short-side 1.5s gap cap (`shortSegmentGapCap` / `shortSegmentVisibleLength`)

    @Test("short trailing segment merges under the 1.5s gap cap (segment-short branch)")
    func shortTrailingSegmentMergesJustUnder1_5sCap() {
        // "yes" has visibleLength 3 (< 8, short). gap = 2.49 - 1.0 = 1.49 <= 1.5, so branch 3
        // of `shouldMerge` fires even though 1.49 > the plain 0.35s cap.
        let result = SpeechTranscriptionResult(
            text: "we should ship this feature yes",
            segments: [
                SpeechSegment(start: 0.0, end: 1.0, text: "we should ship this feature"),
                SpeechSegment(start: 2.49, end: 2.99, text: "yes"),
            ]
        )

        let segments = MicTurnNormalizer.normalize(result: result, startTime: 0.0, endTime: 100.0)

        #expect(segments.count == 1)
        #expect(segments[0].start == 0.0)
        #expect(segments[0].end == 2.99)
        #expect(segments[0].text == "we should ship this feature yes")
    }

    @Test("short trailing segment does NOT merge just over the 1.5s gap cap")
    func shortTrailingSegmentDoesNotMergeJustOver1_5sCap() {
        // Same short "yes" segment, gap widened by 0.02s: 2.51 - 1.0 = 1.51 > 1.5. The
        // short-side rule is capped, not unlimited — none of the three branches fire.
        let result = SpeechTranscriptionResult(
            text: "we should ship this feature yes",
            segments: [
                SpeechSegment(start: 0.0, end: 1.0, text: "we should ship this feature"),
                SpeechSegment(start: 2.51, end: 3.01, text: "yes"),
            ]
        )

        let segments = MicTurnNormalizer.normalize(result: result, startTime: 0.0, endTime: 100.0)

        #expect(segments.count == 2)
        #expect(segments[0].start == 0.0)
        #expect(segments[0].end == 1.0)
        #expect(segments[0].text == "we should ship this feature")
        #expect(segments[1].start == 2.51)
        #expect(segments[1].end == 3.01)
        #expect(segments[1].text == "yes")
    }

    @Test("short leading segment also triggers the gap cap rule (previous-short branch)")
    func shortLeadingSegmentTriggersGapCapRule() {
        // `shouldMerge`'s branches 2 and 3 test the previous segment and the next segment
        // independently (`visibleLength(of: previous.text)` vs `visibleLength(of: segment.text)`).
        // The tests above only exercise branch 3 (short trailing segment); this one puts the
        // short segment first to prove branch 2 independently. "yes" is short (3 < 8);
        // gap = 1.7 - 0.3 = 1.4 <= 1.5.
        let result = SpeechTranscriptionResult(
            text: "yes we should ship this feature",
            segments: [
                SpeechSegment(start: 0.0, end: 0.3, text: "yes"),
                SpeechSegment(start: 1.7, end: 2.7, text: "we should ship this feature"),
            ]
        )

        let segments = MicTurnNormalizer.normalize(result: result, startTime: 0.0, endTime: 100.0)

        #expect(segments.count == 1)
        #expect(segments[0].start == 0.0)
        #expect(segments[0].end == 2.7)
        #expect(segments[0].text == "yes we should ship this feature")
    }

    // MARK: - Merging for the right reason, not a sentence-split stub in disguise
    //
    // The two tests below share the same outer chunk window (startTime 0, endTime 100) and the
    // same underlying utterance, split only by HOW the backend chunked it: two well-formed
    // timed segments below, versus many short shards in the paired test after it. A
    // reimplementation that always fell back to sentence-splitting the full chunk text
    // (ignoring segment structure entirely) would pass the fragmented-input test below but
    // fail this one — it would report end == 100.0, not the segments' own real 2.0s span.

    @Test("merge tier preserves real segment timing, not the full chunk span")
    func mergeTierUsesRealSegmentTimingNotFullChunkSpan() {
        // Two segments, gap 0.2s (<= 0.35s, unconditional merge via branch 1), spanning only
        // 0.0-2.0s of a much larger 0-100 chunk window. `mergedSegments` is not fragmented
        // (count == 1, guard count > 3 short-circuits `isFragmented` to false), so this returns
        // directly from the merge tier — it must NOT fall through to `sentenceSplit`, which
        // would ignore the segments' own timing and span the full clampedEndTime (100.0)
        // instead, since the joined text below has no sentence-ending punctuation and so
        // `sentenceUnits` yields a single unit (same mechanism the donor's own
        // `fallbackChunkLevelTurn` test on "hello world" already establishes).
        let joinedText = "the quick brown fox jumps over the lazy dog and keeps running through the entire field"
        let result = SpeechTranscriptionResult(
            text: joinedText,
            segments: [
                SpeechSegment(start: 0.0, end: 1.0, text: "the quick brown fox jumps over the lazy dog and keeps running"),
                SpeechSegment(start: 1.2, end: 2.0, text: "through the entire field"),
            ]
        )

        let segments = MicTurnNormalizer.normalize(result: result, startTime: 0.0, endTime: 100.0)

        #expect(segments.count == 1)
        #expect(segments[0].start == 0.0)
        #expect(segments[0].end == 2.0)
        #expect(segments[0].end != 100.0)
        #expect(segments[0].text == joinedText)
    }

    @Test("fragmented input falls through to a full-chunk sentence split, not a merge")
    func fragmentedInputFallsThroughToFullChunkSentenceSplit() {
        // Paired with the test above: same 0-100 outer window, but the backend reports 6 tiny
        // shards (each visibleLength <= 4, all <= fragmentationVisibleLength) covering only
        // 0.0-1.0s. `isFragmented` trips on the very first check in `normalize` (count 6 > 3,
        // shortSegmentCount/count == 6/6 == 1.0 >= 0.5, and averageVisibleLength ~2.33 < 8 —
        // both disjuncts true), so this returns straight from `sentenceSplit`, never reaching
        // `mergeAdjacentSegments` at all. `result.text` has no sentence-ending punctuation, so
        // `sentenceUnits` yields one unit and `sentenceSplit` takes its `guard units.count > 1`
        // early return: a single segment spanning the FULL given chunk (startTime...clampedEndTime),
        // not the segments' own 0.0-1.0s span. This is the exact "always sentence-split the
        // whole chunk" behavior the paired test above proves the merge tier does NOT fall into
        // when the input isn't actually fragmented.
        let result = SpeechTranscriptionResult(
            text: "we should ship this feature soon",
            segments: [
                SpeechSegment(start: 0.0, end: 0.1, text: "ab"),
                SpeechSegment(start: 0.15, end: 0.2, text: "cd"),
                SpeechSegment(start: 0.3, end: 0.33, text: "ef"),
                SpeechSegment(start: 0.4, end: 0.44, text: "gh"),
                SpeechSegment(start: 0.5, end: 0.55, text: "ijkl"),
                SpeechSegment(start: 0.7, end: 0.74, text: "mn"),
            ]
        )

        let segments = MicTurnNormalizer.normalize(result: result, startTime: 0.0, endTime: 100.0)

        #expect(segments.count == 1)
        #expect(segments[0].start == 0.0)
        #expect(segments[0].end == 100.0)
        #expect(segments[0].text == "we should ship this feature soon")
    }
}

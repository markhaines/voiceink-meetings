// New for this fork (Stage 2c fix round, cross-vendor review "Gap (i)"). Not a port.
//
// The reviewer said "untestable" (the original claim for this adapter's Transcript -> SpeechSegment
// mapping) was overstated: `Transcript`/`Segment` genuinely have no public initializer outside the
// `TranscribeCpp` package and are not `Codable`, so no real value of THOSE types can be built from
// this module -- but the actual mapping arithmetic (ms -> seconds, clamping) does not need them.
// `TranscribeCppMeetingSegmentTranscriber.swift` now splits that arithmetic into
// `speechSegments(segments:fallbackText:)`, a pure function over primitive `(Int64, Int64, String)`
// tuples. These land in Mark's `**MM:SS**` export where nothing downstream catches a wrong value,
// so this suite is deliberately adversarial about malformed backend timestamps: empty, negative,
// reversed (end before start), and overflowed (near Int64.max).

import Testing
@testable import VoiceInk

@Suite("TranscribeCppMeetingSegmentTranscriber.speechSegments")
struct TranscribeCppMeetingSegmentTranscriberTests {

    @Test("maps ms to seconds for well-formed segments")
    func mapsMillisecondsToSeconds() {
        let segments = TranscribeCppMeetingSegmentTranscriber.speechSegments(
            segments: [(t0Ms: 200, t1Ms: 600, text: "Hi"), (t0Ms: 600, t1Ms: 1_000, text: "there")],
            fallbackText: "Hi there"
        )

        #expect(segments.count == 2)
        #expect(segments[0].start == 0.2)
        #expect(segments[0].end == 0.6)
        #expect(segments[0].text == "Hi")
        #expect(segments[1].start == 0.6)
        #expect(segments[1].end == 1.0)
        #expect(segments[1].text == "there")
    }

    @Test("empty segments array falls back to fallbackText as one zero-duration segment")
    func emptySegmentsFallsBackToFlatText() {
        let segments = TranscribeCppMeetingSegmentTranscriber.speechSegments(
            segments: [],
            fallbackText: "no segments returned"
        )

        #expect(segments.count == 1)
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 0)
        #expect(segments[0].text == "no segments returned")
    }

    @Test("empty segments array AND blank fallback text produces zero segments")
    func emptySegmentsAndBlankTextProducesNoSegments() {
        let segments = TranscribeCppMeetingSegmentTranscriber.speechSegments(
            segments: [],
            fallbackText: "   "
        )

        #expect(segments.isEmpty)
    }

    @Test("negative t0Ms is clamped to zero, not propagated as a negative start time")
    func negativeStartIsClampedToZero() {
        let segments = TranscribeCppMeetingSegmentTranscriber.speechSegments(
            segments: [(t0Ms: -500, t1Ms: 300, text: "oops")],
            fallbackText: "oops"
        )

        #expect(segments.count == 1)
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 0.3)
    }

    @Test("negative t1Ms (end before zero) is clamped to the clamped start, never negative")
    func negativeEndIsClampedToStart() {
        let segments = TranscribeCppMeetingSegmentTranscriber.speechSegments(
            segments: [(t0Ms: -500, t1Ms: -900, text: "oops")],
            fallbackText: "oops"
        )

        #expect(segments.count == 1)
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 0)
        #expect(segments[0].end >= segments[0].start)
    }

    @Test("reversed timestamps (end before start, both positive) clamp end up to start, never negative-duration")
    func reversedTimestampsClampToNonNegativeDuration() {
        let segments = TranscribeCppMeetingSegmentTranscriber.speechSegments(
            segments: [(t0Ms: 5_000, t1Ms: 1_000, text: "reversed")],
            fallbackText: "reversed"
        )

        #expect(segments.count == 1)
        #expect(segments[0].start == 5.0)
        #expect(segments[0].end == 5.0)
        #expect(segments[0].end >= segments[0].start)
    }

    @Test("overflowed timestamps (near Int64.max) convert without crashing or wrapping negative")
    func overflowedTimestampsDoNotCrashOrWrapNegative() {
        let segments = TranscribeCppMeetingSegmentTranscriber.speechSegments(
            segments: [(t0Ms: Int64.max - 1, t1Ms: Int64.max, text: "huge")],
            fallbackText: "huge"
        )

        #expect(segments.count == 1)
        #expect(segments[0].start > 0)
        #expect(segments[0].end >= segments[0].start)
        #expect(segments[0].start.isFinite)
        #expect(segments[0].end.isFinite)
    }

    @Test("multiple malformed segments in one transcript are each independently clamped, in order")
    func multipleMalformedSegmentsEachClampedIndependently() {
        let segments = TranscribeCppMeetingSegmentTranscriber.speechSegments(
            segments: [
                (t0Ms: 0, t1Ms: 1_000, text: "fine"),
                (t0Ms: 2_000, t1Ms: 1_500, text: "reversed"),
                (t0Ms: -100, t1Ms: 500, text: "negative-start"),
            ],
            fallbackText: "fine reversed negative-start"
        )

        #expect(segments.count == 3)
        #expect(segments[0].start == 0 && segments[0].end == 1.0)
        #expect(segments[1].start == 2.0 && segments[1].end == 2.0)
        #expect(segments[2].start == 0 && segments[2].end == 0.5)
    }
}

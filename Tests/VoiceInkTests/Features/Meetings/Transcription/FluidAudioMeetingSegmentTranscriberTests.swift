// New for this fork (Stage 2c, `MeetingTranscriptionCoordinator`). Not a port.
//
// Unit-tests `FluidAudioMeetingSegmentTranscriber.speechSegments(fromTokenSpans:duration:text:)`
// -- the pure mapping from a token span to this fork's `SpeechSegment`.
//
// ROUND 6 changed the input element type from FluidAudio's `TokenTiming` to the fork-owned
// `MeetingTokenSpan`, because the seam no longer carries a package type (or any FluidAudio
// object) across it. The mapping BEHAVIOUR is unchanged and every assertion below is the same
// one it was before.
//
// The real-`ASRResult` round trip is kept and still uses REAL FluidAudio values, now aimed one
// step earlier in the pipeline: `MeetingChunkTranscription.init(_ result: ASRResult)`, the
// conversion that actually crosses the seam. Without that, round 6 would have quietly dropped
// the only test proving the fields the mapper reads are the fields the backend fills.

import FluidAudio
import Testing
@testable import VoiceInk

@Suite("FluidAudioMeetingSegmentTranscriber.speechSegments")
struct FluidAudioMeetingSegmentTranscriberTests {

    @Test("maps one SpeechSegment per token span, verbatim times and text")
    func mapsOneSegmentPerToken() {
        let tokenSpans = [
            MeetingTokenSpan(token: "Hi", start: 0.2, end: 0.6),
            MeetingTokenSpan(token: "there", start: 0.6, end: 1.0),
        ]

        let segments = FluidAudioMeetingSegmentTranscriber.speechSegments(
            fromTokenSpans: tokenSpans,
            duration: 1.0,
            text: "Hi there"
        )

        #expect(segments.count == 2)
        #expect(segments[0].start == 0.2)
        #expect(segments[0].end == 0.6)
        #expect(segments[0].text == "Hi")
        #expect(segments[1].start == 0.6)
        #expect(segments[1].end == 1.0)
        #expect(segments[1].text == "there")
    }

    @Test("clamps a malformed token (end before start) rather than producing a negative-duration segment")
    func clampsMalformedTokenSpan() {
        let tokenSpans = [
            MeetingTokenSpan(token: "oops", start: 1.0, end: 0.9)
        ]

        let segments = FluidAudioMeetingSegmentTranscriber.speechSegments(
            fromTokenSpans: tokenSpans,
            duration: 1.0,
            text: "oops"
        )

        #expect(segments.count == 1)
        #expect(segments[0].start == 1.0)
        #expect(segments[0].end == 1.0)
    }

    @Test("falls back to one full-span segment (real duration, not zero) when tokenTimings is nil")
    func fallsBackToFullSpanWhenNil() {
        let segments = FluidAudioMeetingSegmentTranscriber.speechSegments(
            fromTokenSpans: nil,
            duration: 3.5,
            text: "no token timings available"
        )

        #expect(segments.count == 1)
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 3.5)
        #expect(segments[0].text == "no token timings available")
    }

    @Test("falls back to one full-span segment when tokenTimings is an empty array")
    func fallsBackToFullSpanWhenEmpty() {
        let segments = FluidAudioMeetingSegmentTranscriber.speechSegments(
            fromTokenSpans: [],
            duration: 2.0,
            text: "empty timings array"
        )

        #expect(segments.count == 1)
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 2.0)
    }

    @Test("no tokenTimings and blank text produces zero segments, not a degenerate empty-text one")
    func blankTextWithNoTimingsProducesNoSegments() {
        let segments = FluidAudioMeetingSegmentTranscriber.speechSegments(
            fromTokenSpans: nil,
            duration: 1.0,
            text: "   "
        )

        #expect(segments.isEmpty)
    }

    @Test("end-to-end: a real ASRResult crosses the seam and still maps to the right segments")
    func realASRResultFieldsSurviveMapping() {
        // Round-trips a REAL `ASRResult` through the conversion that actually crosses the seam
        // (`MeetingChunkTranscription.init(_:)`) and then through the mapper, proving the fields
        // the backend fills are the fields the mapper reads. Passing the pieces in directly would
        // not catch a conversion that dropped or transposed one.
        let result = ASRResult(
            text: "Hi there",
            confidence: 0.95,
            duration: 1.0,
            processingTime: 0.1,
            tokenTimings: [
                TokenTiming(token: "Hi", tokenId: 1, startTime: 0.2, endTime: 0.6, confidence: 0.9),
                TokenTiming(token: "there", tokenId: 2, startTime: 0.6, endTime: 1.0, confidence: 0.85),
            ]
        )

        let receipt = MeetingChunkTranscription(result)
        #expect(receipt.text == "Hi there")
        #expect(receipt.duration == 1.0)
        #expect(receipt.tokenSpans?.count == 2)

        let segments = FluidAudioMeetingSegmentTranscriber.speechSegments(
            fromTokenSpans: receipt.tokenSpans,
            duration: receipt.duration,
            text: receipt.text
        )

        #expect(segments.count == 2)
        #expect(segments[0].text == "Hi")
        #expect(segments[0].start == 0.2)
        #expect(segments[1].text == "there")
        #expect(segments[1].end == 1.0)
    }
}

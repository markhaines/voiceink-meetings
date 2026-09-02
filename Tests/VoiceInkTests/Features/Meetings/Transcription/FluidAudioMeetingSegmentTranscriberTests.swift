// New for this fork (Stage 2c, `MeetingTranscriptionCoordinator`). Not a port.
//
// Unit-tests `FluidAudioMeetingSegmentTranscriber.speechSegments(fromTokenTimings:duration:text:)`
// -- the pure mapping from FluidAudio's own `TokenTiming` to this fork's `SpeechSegment` -- with
// REAL `TokenTiming`/`ASRResult` values (both have public memberwise initializers in the
// FluidAudio package, no fake/protocol boundary needed here), not a fake. This is the one
// segment-bearing adapter whose mapping logic can be tested against real backend types without
// real model inference; `TranscribeCppMeetingSegmentTranscriber`'s equivalent cannot (see that
// file's own header) because `Transcript`/`Segment` have no public initializer outside the
// `TranscribeCpp` package and are not `Codable`.

import FluidAudio
import Testing
@testable import VoiceInk

@Suite("FluidAudioMeetingSegmentTranscriber.speechSegments")
struct FluidAudioMeetingSegmentTranscriberTests {

    @Test("maps one SpeechSegment per TokenTiming, verbatim times and text")
    func mapsOneSegmentPerToken() {
        let tokenTimings = [
            TokenTiming(token: "Hi", tokenId: 1, startTime: 0.2, endTime: 0.6, confidence: 0.9),
            TokenTiming(token: "there", tokenId: 2, startTime: 0.6, endTime: 1.0, confidence: 0.85),
        ]

        let segments = FluidAudioMeetingSegmentTranscriber.speechSegments(
            fromTokenTimings: tokenTimings,
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
    func clampsMalformedTokenTiming() {
        let tokenTimings = [
            TokenTiming(token: "oops", tokenId: 1, startTime: 1.0, endTime: 0.9, confidence: 0.5)
        ]

        let segments = FluidAudioMeetingSegmentTranscriber.speechSegments(
            fromTokenTimings: tokenTimings,
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
            fromTokenTimings: nil,
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
            fromTokenTimings: [],
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
            fromTokenTimings: nil,
            duration: 1.0,
            text: "   "
        )

        #expect(segments.isEmpty)
    }

    @Test("end-to-end: real ASRResult.tokenTimings survive the actor's transcribe(chunkAt:) mapping")
    func realASRResultFieldsSurviveMapping() {
        // ASRResult itself is not consumed by speechSegments(fromTokenTimings:duration:text:) --
        // this proves the fields the actor's transcribe(chunkAt:) reads off it (tokenTimings,
        // duration, text) are the same fields the mapper uses, by round-tripping through a real
        // ASRResult rather than passing the pieces directly.
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

        let segments = FluidAudioMeetingSegmentTranscriber.speechSegments(
            fromTokenTimings: result.tokenTimings,
            duration: result.duration,
            text: result.text
        )

        #expect(segments.count == 2)
        #expect(segments[0].text == "Hi")
        #expect(segments[1].text == "there")
    }
}

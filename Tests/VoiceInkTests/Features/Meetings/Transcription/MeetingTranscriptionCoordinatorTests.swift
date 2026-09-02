// New for this fork (Stage 2c, `MeetingTranscriptionCoordinator`). Not a port.
//
// Exercises the coordinator's ROUTING decision (segment-bearing transcriber vs. flat-string
// fallback) using fakes, then feeds the coordinator's own output through the REAL
// `MicTurnNormalizer` (ported verbatim, unmodified elsewhere in this fork) to prove the
// end-to-end consequence of that routing, not just the shape of `SpeechTranscriptionResult` in
// isolation.
//
// `killsNaiveAlwaysSentenceSplit` is the test this PR's brief specifically asked for: expected
// values are derived by hand against `MicTurnNormalizer`'s documented tiering (segments.count
// <= 3 never trips `isFragmented`; the 1.9s gap between the two fake segments exceeds both the
// 0.35s merge gap and the 1.5s short-segment gap cap, so they never merge) BEFORE running
// anything, then asserted against the real normalizer's output. A naive coordinator that always
// flattened to one segment + sentence-split (this file's `fallbackWhenNoTranscriberConfigured`
// case) would produce exactly ONE turn spanning the whole chunk for the same single-sentence
// text; this test's segment-bearing case must produce TWO turns with the FAKE BACKEND'S OWN
// times, not proportional-by-character-weight times, which is exactly the distinction a naive
// always-sentence-split implementation collapses.

import FluidAudio
import Testing
@testable import VoiceInk

private struct FakeSegmentTranscriber: MeetingSegmentTranscribing {
    let result: SpeechTranscriptionResult
    private let calls = CallCounter()

    init(result: SpeechTranscriptionResult) {
        self.result = result
    }

    func transcribe(chunkAt url: URL) async throws -> SpeechTranscriptionResult {
        await calls.increment()
        return result
    }

    var callCount: Int {
        get async { await calls.count }
    }
}

private struct ThrowingSegmentTranscriber: MeetingSegmentTranscribing {
    struct Failure: Error {}

    func transcribe(chunkAt url: URL) async throws -> SpeechTranscriptionResult {
        throw Failure()
    }
}

private struct FakeDiarizer: MeetingSystemAudioDiarizing {
    let result: DiarizationResult?

    func diarize(fileAt url: URL) async throws -> DiarizationResult? {
        result
    }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Suite("MeetingTranscriptionCoordinator")
struct MeetingTranscriptionCoordinatorTests {

    private static let chunkURL = URL(fileURLWithPath: "/tmp/meeting-chunk.wav")

    @Test("routes .fluidAudio to the configured FluidAudio transcriber, verbatim")
    func routesFluidAudioToItsTranscriber() async throws {
        let real = SpeechTranscriptionResult(
            text: "Hi there friend.",
            segments: [
                SpeechSegment(start: 0.2, end: 0.6, text: "Hi"),
                SpeechSegment(start: 2.5, end: 3.8, text: "there friend"),
            ]
        )
        let fluidAudio = FakeSegmentTranscriber(result: real)
        let coordinator = MeetingTranscriptionCoordinator(
            backend: .fluidAudio,
            fluidAudioTranscriber: fluidAudio,
            fallbackTranscribe: { _ in "should not be called" }
        )

        let result = try await coordinator.transcribeMeetingChunk(at: Self.chunkURL)

        #expect(result.text == "Hi there friend.")
        #expect(result.segments.count == 2)
        #expect(await fluidAudio.callCount == 1)
    }

    @Test("routes .transcribeCpp to the configured transcribe-cpp transcriber, verbatim")
    func routesTranscribeCppToItsTranscriber() async throws {
        let real = SpeechTranscriptionResult(
            text: "segmented",
            segments: [SpeechSegment(start: 0, end: 1, text: "segmented")]
        )
        let transcribeCpp = FakeSegmentTranscriber(result: real)
        let coordinator = MeetingTranscriptionCoordinator(
            backend: .transcribeCpp,
            transcribeCppTranscriber: transcribeCpp,
            fallbackTranscribe: { _ in "should not be called" }
        )

        let result = try await coordinator.transcribeMeetingChunk(at: Self.chunkURL)

        #expect(result.segments.count == 1)
        #expect(await transcribeCpp.callCount == 1)
    }

    @Test("degrades .other to the flat-string fallback, wrapped as one zero-duration segment")
    func fallbackForOtherBackend() async throws {
        let coordinator = MeetingTranscriptionCoordinator(
            backend: .other,
            fallbackTranscribe: { _ in "Hi there friend." }
        )

        let result = try await coordinator.transcribeMeetingChunk(at: Self.chunkURL)

        #expect(result.text == "Hi there friend.")
        #expect(result.segments.count == 1)
        #expect(result.segments[0].start == 0)
        #expect(result.segments[0].end == 0)
    }

    @Test("degrades .fluidAudio with no transcriber configured to the flat-string fallback")
    func fallbackWhenNoTranscriberConfigured() async throws {
        let coordinator = MeetingTranscriptionCoordinator(
            backend: .fluidAudio,
            fallbackTranscribe: { _ in "Hi there friend." }
        )

        let result = try await coordinator.transcribeMeetingChunk(at: Self.chunkURL)

        #expect(result.segments.count == 1)
        #expect(result.segments[0].start == 0)
        #expect(result.segments[0].end == 0)
    }

    @Test("empty fallback text produces zero segments, not a degenerate zero-duration one")
    func emptyFallbackTextProducesNoSegments() async throws {
        let coordinator = MeetingTranscriptionCoordinator(
            backend: .other,
            fallbackTranscribe: { _ in "" }
        )

        let result = try await coordinator.transcribeMeetingChunk(at: Self.chunkURL)

        #expect(result.text == "")
        #expect(result.segments.isEmpty)
    }

    @Test("a segment transcriber's failure propagates, it is not silently swallowed into the fallback")
    func segmentTranscriberFailurePropagates() async {
        let coordinator = MeetingTranscriptionCoordinator(
            backend: .fluidAudio,
            fluidAudioTranscriber: ThrowingSegmentTranscriber(),
            fallbackTranscribe: { _ in "fallback should never run" }
        )

        await #expect(throws: ThrowingSegmentTranscriber.Failure.self) {
            _ = try await coordinator.transcribeMeetingChunk(at: Self.chunkURL)
        }
    }

    @Test("transcribeMeeting(at:) routes the same way as transcribeMeetingChunk(at:)")
    func transcribeMeetingRoutesLikeChunk() async throws {
        let real = SpeechTranscriptionResult(
            text: "whole file",
            segments: [SpeechSegment(start: 0, end: 2, text: "whole file")]
        )
        let coordinator = MeetingTranscriptionCoordinator(
            backend: .fluidAudio,
            fluidAudioTranscriber: FakeSegmentTranscriber(result: real),
            fallbackTranscribe: { _ in "should not be called" }
        )

        let result = try await coordinator.transcribeMeeting(at: Self.chunkURL)

        #expect(result.text == "whole file")
        #expect(result.segments.count == 1)
    }

    @Test("diarizeSystemAudio delegates to the configured diarizer")
    func diarizeSystemAudioDelegates() async throws {
        let segment = TimedSpeakerSegment(
            speakerId: "1",
            embedding: [],
            startTimeSeconds: 0,
            endTimeSeconds: 1,
            qualityScore: 1
        )
        let expected = DiarizationResult(segments: [segment])
        let coordinator = MeetingTranscriptionCoordinator(
            backend: .other,
            diarizer: FakeDiarizer(result: expected),
            fallbackTranscribe: { _ in "" }
        )

        let result = try await coordinator.diarizeSystemAudio(at: Self.chunkURL)

        #expect(result?.segments.count == 1)
        #expect(result?.segments.first?.speakerId == "1")
    }

    @Test("diarizeSystemAudio returns nil when no diarizer is configured")
    func diarizeSystemAudioNilWhenUnconfigured() async throws {
        let coordinator = MeetingTranscriptionCoordinator(
            backend: .other,
            fallbackTranscribe: { _ in "" }
        )

        let result = try await coordinator.diarizeSystemAudio(at: Self.chunkURL)

        #expect(result == nil)
    }

    // Note: there is no test here for getVadManager() CACHING A SUCCESSFUL construction.
    // `VadManager` is a real, FluidAudio model-backed actor with no lightweight test double
    // anywhere in this fork (`internal init(skipModelLoading:)` exists inside FluidAudio itself
    // but is not visible outside that module) -- the same disclosed gap
    // `MeetingEngineTests.swift`'s header already documents for this exact type. Constructing a
    // real one in a unit test means downloading/loading real CoreML models, which this test
    // suite does not do. The failure-caching path below needs no real `VadManager` at all, so it
    // is covered for real.

    @Test("getVadManager caches a failed construction, it does not retry every call")
    func getVadManagerCachesFailure() async {
        struct ConstructionFailure: Error {}
        let factoryCalls = CallCounter()
        let coordinator = MeetingTranscriptionCoordinator(
            backend: .other,
            fallbackTranscribe: { _ in "" },
            vadManagerFactory: {
                await factoryCalls.increment()
                throw ConstructionFailure()
            }
        )

        let first = await coordinator.getVadManager()
        let second = await coordinator.getVadManager()

        #expect(first == nil)
        #expect(second == nil)
        #expect(await factoryCalls.count == 1)
    }

    // MARK: - The end-to-end, naive-implementation-killing case

    @Test(
        "a real segment-bearing result, run through the real MicTurnNormalizer, produces multiple turns at the BACKEND'S OWN times -- a naive always-sentence-split implementation would collapse this single-sentence text to one turn spanning the whole chunk"
    )
    func killsNaiveAlwaysSentenceSplit() async throws {
        // Deliberately one grammatical sentence (NLTokenizer's `.sentence` unit sees no
        // boundary in it), so a sentence-split fallback returns exactly ONE turn spanning the
        // whole [startTime, endTime] window -- see `fallbackCollapsesToOneTurn` below for that
        // control case, computed the same way.
        let backendResult = SpeechTranscriptionResult(
            text: "Hi there friend.",
            segments: [
                SpeechSegment(start: 0.2, end: 0.6, text: "Hi"),
                // 1.9s gap after the previous segment's end (0.6 -> 2.5): exceeds both
                // MicTurnNormalizer's 0.35s merge gap and its 1.5s short-segment gap cap, so
                // these two segments never merge into one.
                SpeechSegment(start: 2.5, end: 3.8, text: "there friend"),
            ]
        )
        let coordinator = MeetingTranscriptionCoordinator(
            backend: .fluidAudio,
            fluidAudioTranscriber: FakeSegmentTranscriber(result: backendResult),
            fallbackTranscribe: { _ in "should not be called" }
        )

        let result = try await coordinator.transcribeMeetingChunk(at: Self.chunkURL)
        let turns = MicTurnNormalizer.normalize(result: result, startTime: 100.0, endTime: 104.0)

        // Hand-derived: absoluteStart/End = clamp(startTime + segment.start/end, [startTime, endTime]).
        #expect(turns.count == 2)
        #expect(turns[0].start == 100.2)
        #expect(turns[0].end == 100.6)
        #expect(turns[0].text == "Hi")
        #expect(turns[1].start == 102.5)
        #expect(turns[1].end == 103.8)
        #expect(turns[1].text == "there friend")
    }

    @Test("control case: the flat-string fallback for the SAME text collapses to one turn")
    func fallbackCollapsesToOneTurn() async throws {
        let coordinator = MeetingTranscriptionCoordinator(
            backend: .other,
            fallbackTranscribe: { _ in "Hi there friend." }
        )

        let result = try await coordinator.transcribeMeetingChunk(at: Self.chunkURL)
        let turns = MicTurnNormalizer.normalize(result: result, startTime: 100.0, endTime: 104.0)

        #expect(turns.count == 1)
        #expect(turns[0].start == 100.0)
        #expect(turns[0].end == 104.0)
        #expect(turns[0].text == "Hi there friend.")
    }
}

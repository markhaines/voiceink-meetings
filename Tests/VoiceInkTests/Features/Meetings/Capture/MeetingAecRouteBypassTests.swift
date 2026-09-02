// Fork-authored: tests for MeetingAecRouteBypassSource, a fork addition with no donor
// equivalent (see MeetingNeuralAec.swift). Not ported, not subject to the byte-for-byte
// porting rules that apply to MeetingNeuralAecTests.swift's donor-derived cases -- kept in a
// separate file for exactly that reason, so the ported file's donor-diffability stays clean.
//
// These specifically target the timeline-corruption bug found in review: entering bypass
// with a partially queued frame left pendingMicStartSample frozen at the pre-bypass
// position, so the first frame processed after bypass ended looked up the wrong absolute
// segment of system audio -- misaligned echo cancellation, silently, only in a meeting where
// someone plugs or unplugs headphones.

import Foundation
import Testing
@testable import VoiceInk

@Suite("MeetingAecRouteBypass")
struct MeetingAecRouteBypassTests {

    @Test("entering bypass with a partially queued frame drains it instead of dropping it")
    func enteringBypassDrainsPartialFrame() {
        let processor = RecordingAecProcessor(frameSize: 256)
        let bypassSource = MutableRouteBypassSource()
        let aec = MeetingNeuralAec(preloadedProcessor: processor)
        aec.routeBypassSource = bypassSource
        aec.resetForStreaming()

        // Absolute-position-encoded system audio: system[p] == Float(p), so any reference
        // frame's first sample reveals exactly which absolute position it was read from.
        aec.feedSystemSamples(rampSamples(from: 0, count: 2_000))

        // 100 mic samples queue as a partial frame (frameSize is 256); nothing processed yet.
        let queued = aec.processStreamingMic([Float](repeating: 0.3, count: 100))
        #expect(queued.isEmpty)
        #expect(processor.referenceFramesFirstSample.isEmpty)

        // Headphones plug in on this call: the queued partial frame must drain now, using
        // the still-valid pre-bypass alignment (absolute position 0), not be left dangling.
        bypassSource.isHeadphoneLikeRoute = true
        let transitionOutput = aec.processStreamingMic([Float](repeating: 0.4, count: 50))

        #expect(processor.referenceFramesFirstSample == [0])
        // Drained fragment (100 samples, trimmed back from the zero-padded 256-frame) plus
        // this call's raw bypass passthrough (50 samples): nothing dropped, nothing gained.
        #expect(transitionOutput.count == 150)
    }

    @Test("entering bypass with an empty queue drains nothing")
    func enteringBypassWithEmptyQueueDrainsNothing() {
        let processor = RecordingAecProcessor(frameSize: 256)
        let bypassSource = MutableRouteBypassSource()
        let aec = MeetingNeuralAec(preloadedProcessor: processor)
        aec.routeBypassSource = bypassSource
        aec.resetForStreaming()

        aec.feedSystemSamples(rampSamples(from: 0, count: 2_000))
        bypassSource.isHeadphoneLikeRoute = true
        let output = aec.processStreamingMic([Float](repeating: 0.4, count: 50))

        #expect(processor.referenceFramesFirstSample.isEmpty)
        #expect(output.count == 50)
    }

    @Test("leaving bypass resumes at the correct absolute offset, not the frozen pre-bypass one")
    func leavingBypassResumesAtCorrectOffset() {
        let processor = RecordingAecProcessor(frameSize: 256)
        let bypassSource = MutableRouteBypassSource()
        let aec = MeetingNeuralAec(preloadedProcessor: processor)
        aec.routeBypassSource = bypassSource
        aec.resetForStreaming()

        aec.feedSystemSamples(rampSamples(from: 0, count: 2_000))

        // Partial frame queued (100 samples) before bypass, exactly the scenario the review
        // flagged: a transition test with an empty queue would pass without proving anything.
        _ = aec.processStreamingMic([Float](repeating: 0.3, count: 100))

        bypassSource.isHeadphoneLikeRoute = true
        // Entering call (drains the 100-sample fragment at position 0, then advances past its
        // own 50 raw samples): pendingMicStartSample 0 -> 100 -> 150.
        _ = aec.processStreamingMic([Float](repeating: 0.4, count: 50))
        // Two more bypassed calls while headphones stay in: 150 -> 300 -> 450.
        _ = aec.processStreamingMic([Float](repeating: 0.4, count: 150))
        _ = aec.processStreamingMic([Float](repeating: 0.4, count: 150))

        bypassSource.isHeadphoneLikeRoute = false
        // A full frame's worth of real mic audio resumes processing.
        _ = aec.processStreamingMic([Float](repeating: 0.5, count: 256))

        // Without the fix, pendingMicStartSample would still read 100 (frozen at the
        // drain), and this frame would have looked up system[100], not system[450].
        #expect(processor.referenceFramesFirstSample == [0, 450])
    }

    private func rampSamples(from start: Int, count: Int) -> [Float] {
        (0..<count).map { Float(start + $0) }
    }
}

private final class MutableRouteBypassSource: MeetingAecRouteBypassSource {
    var isHeadphoneLikeRoute = false
}

private final class RecordingAecProcessor: MeetingAecProcessor {
    let name = "test-recording"
    let frameSize: Int
    let sampleRate = 16_000
    private(set) var referenceFramesFirstSample: [Float] = []

    init(frameSize: Int) {
        self.frameSize = frameSize
    }

    func reset() {
        referenceFramesFirstSample.removeAll()
    }

    func processFrame(mic: [Float], reference: [Float]) throws -> [Float] {
        referenceFramesFirstSample.append(reference.first ?? .nan)
        return mic
    }
}

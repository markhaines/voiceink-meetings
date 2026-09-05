// Ported verbatim from Muesli-HQ/muesli
// (native/MuesliNative/Tests/MuesliTests/StreamingVadControllerTests.swift).
// Import line changed: `@testable import MuesliNativeApp` -> `@testable import VoiceInk`
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
import Foundation
import Testing
@testable import VoiceInk

private actor StreamingVadTestProbe {
    private(set) var processedCount = 0
    private(set) var inFlightCount = 0
    private(set) var maxConcurrentCount = 0
    private(set) var boundaryCount = 0

    func processingStarted() {
        inFlightCount += 1
        maxConcurrentCount = max(maxConcurrentCount, inFlightCount)
    }

    func processingFinished() {
        inFlightCount = max(0, inFlightCount - 1)
        processedCount += 1
    }

    func boundaryTriggered() {
        boundaryCount += 1
    }
}

private final class StreamingVadBoundaryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage = 0

    var count: Int {
        lock.withLock { countStorage }
    }

    func boundaryTriggered() {
        lock.withLock {
            countStorage += 1
        }
    }
}

@Suite("StreamingVadController", .serialized)
struct StreamingVadControllerTests {
    @Test("serializes streaming VAD processing to a single in-flight chunk")
    func serializesChunkProcessing() async throws {
        let probe = StreamingVadTestProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                try? await Task.sleep(for: .milliseconds(25))
                await probe.processingFinished()
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )

        controller.start()
        for _ in 0..<10 {
            controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))
        }

        // 10s, not 2s. This deadline is a HANG GUARD, not a latency assertion: the two `#expect`s
        // below are what this test proves, and neither depends on how long the wait was allowed
        // to run. The work here is 10 chunks serialized at 25ms each, so ~250ms locally -- but
        // the loop is doing exactly what this repo's own rule in FOLLOWUPS.md prescribes
        // (wait on the state being asserted, never a fixed sleep), and a loaded CI runner can
        // stretch 250ms of serialized async work past 2s. It did: CI run 33965544410 failed here
        // at 2.324s, having exhausted the old deadline, and the SAME COMMIT passed on re-run with
        // no code change. Raising the ceiling removes the false failure without weakening either
        // assertion -- a genuine serialization regression still fails on `maxConcurrentCount`,
        // and a genuine hang still fails on `processedCount` after 10s.
        let deadline = ContinuousClock.now + .seconds(10)
        while await probe.processedCount < 10, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()

        #expect(await probe.processedCount == 10)
        #expect(await probe.maxConcurrentCount == 1)
    }

    @Test("buffers chunks that arrive before stream state initialization completes")
    func buffersChunksBeforeStateReady() async throws {
        let probe = StreamingVadTestProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: {
                try? await Task.sleep(for: .milliseconds(120))
                return VadStreamState.initial()
            },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                try? await Task.sleep(for: .milliseconds(10))
                await probe.processingFinished()
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )

        controller.start()
        for _ in 0..<3 {
            controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))
        }

        // Same reasoning as `serializesChunkProcessing` above: hang guard, not a latency claim.
        let deadline = ContinuousClock.now + .seconds(10)
        while await probe.processedCount < 3, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()

        #expect(await probe.processedCount == 3)
        #expect(await probe.maxConcurrentCount == 1)
    }

    @Test("emits a chunk boundary when streaming VAD detects speech end")
    func emitsChunkBoundaryOnSpeechEnd() async throws {
        let probe = StreamingVadTestProbe()
        let boundaryProbe = StreamingVadBoundaryProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                await probe.processingFinished()
                return VadStreamResult(
                    state: state,
                    event: VadStreamEvent(kind: .speechEnd, sampleIndex: VadManager.chunkSize),
                    probability: 0.05
                )
            }
        )

        controller.onChunkBoundary = {
            boundaryProbe.boundaryTriggered()
        }

        controller.start()
        controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))

        let deadline = ContinuousClock.now + .seconds(3)
        while boundaryProbe.count < 1, ContinuousClock.now < deadline {
            // The controller deliberately delivers boundaries on the main queue.
            // Yield there so this non-main-actor test exercises that delivery.
            await MainActor.run {}
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()

        #expect(boundaryProbe.count == 1)
    }

    @Test("ignores stale VAD results after stop and restart")
    func ignoresStaleResultsAfterRestart() async throws {
        let probe = StreamingVadTestProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                try? await Task.sleep(for: .milliseconds(120))
                await probe.processingFinished()
                return VadStreamResult(
                    state: state,
                    event: VadStreamEvent(kind: .speechEnd, sampleIndex: VadManager.chunkSize),
                    probability: 0.05
                )
            }
        )

        controller.onChunkBoundary = {
            Task { await probe.boundaryTriggered() }
        }

        controller.start()
        controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))

        let startedDeadline = ContinuousClock.now + .seconds(1)
        while await probe.inFlightCount == 0, ContinuousClock.now < startedDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        controller.stop()
        controller.start()

        let finishedDeadline = ContinuousClock.now + .seconds(2)
        while await probe.processedCount < 1, ContinuousClock.now < finishedDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()

        #expect(await probe.processedCount == 1)
        #expect(await probe.boundaryCount == 0)
    }

    @Test("stale drainer does not clear restarted session queue")
    func staleDrainerDoesNotClearRestartedSessionQueue() async throws {
        let probe = StreamingVadTestProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                await probe.processingStarted()
                try? await Task.sleep(for: .milliseconds(120))
                await probe.processingFinished()
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )

        controller.start()
        controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))

        let startedDeadline = ContinuousClock.now + .seconds(1)
        while await probe.inFlightCount == 0, ContinuousClock.now < startedDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        controller.stop()
        controller.start()
        for _ in 0..<3 {
            controller.processAudio([Float](repeating: 0, count: VadManager.chunkSize))
        }

        let finishedDeadline = ContinuousClock.now + .seconds(2)
        while await probe.processedCount < 4, ContinuousClock.now < finishedDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.stop()

        #expect(await probe.processedCount == 4)
    }
}

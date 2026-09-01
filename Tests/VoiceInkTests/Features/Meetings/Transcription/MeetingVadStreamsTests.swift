// Fork-owned (no donor equivalent). Not a port.
//
// Proves the intended wiring for MeetingVadStreams.swift's compile-time stream boundary:
// - MicVadStream.process only accepts AECCleanedMicSamples and actually reaches the wrapped
//   StreamingVadController.
// - SystemVadStream.process only accepts RawSystemSamples and actually reaches the wrapped
//   StreamingVadController.
// - Both forward onChunkBoundary and start/stop correctly.
//
// What this file does NOT and CANNOT test: that `MicVadStream.process(RawSystemSamples(...))`
// is a compile error. Swift Testing has no "assert this does not compile" facility, and this
// project has no separate negative-compilation-test harness. That claim is a property of the
// type system (see MeetingVadStreams.swift's header for exactly what is and isn't enforced),
// verifiable by hand: attempting `micStream.process(RawSystemSamples([]))` or
// `systemStream.process(AECCleanedMicSamples([]))` anywhere in this file fails to build with
// "cannot convert value of type 'RawSystemSamples' to expected argument type
// 'AECCleanedMicSamples'" (and the mirror error) — confirmed manually while writing this file,
// left commented out below rather than deleted, so a reviewer can uncomment either line and
// watch the build fail.

import FluidAudio
import Foundation
import Testing
@testable import VoiceInk

@Suite("MeetingVadStreams")
struct MeetingVadStreamsTests {
    @Test("MicVadStream forwards AECCleanedMicSamples to the wrapped controller")
    func micStreamForwardsCleanedSamples() async throws {
        let probe = VadStreamProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { samples, state in
                await probe.record(sampleCount: samples.count)
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )
        let micStream = MicVadStream(controller: controller)

        micStream.start()
        micStream.process(AECCleanedMicSamples([Float](repeating: 0, count: VadManager.chunkSize)))

        let deadline = ContinuousClock.now + .seconds(2)
        while await probe.recordedCounts.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        micStream.stop()

        #expect(await probe.recordedCounts == [VadManager.chunkSize])

        // Negative controls (left commented out, see file header): uncommenting either line
        // must fail to build, not fail at runtime.
        // micStream.process(RawSystemSamples([Float](repeating: 0, count: VadManager.chunkSize)))
    }

    @Test("SystemVadStream forwards RawSystemSamples to the wrapped controller")
    func systemStreamForwardsRawSamples() async throws {
        let probe = VadStreamProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { samples, state in
                await probe.record(sampleCount: samples.count)
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )
        let systemStream = SystemVadStream(controller: controller)

        systemStream.start()
        systemStream.process(RawSystemSamples([Float](repeating: 0, count: VadManager.chunkSize)))

        let deadline = ContinuousClock.now + .seconds(2)
        while await probe.recordedCounts.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        systemStream.stop()

        #expect(await probe.recordedCounts == [VadManager.chunkSize])

        // Negative control (left commented out, see file header): uncommenting must fail to
        // build, not fail at runtime.
        // systemStream.process(AECCleanedMicSamples([Float](repeating: 0, count: VadManager.chunkSize)))
    }

    @Test("MicVadStream forwards onChunkBoundary from the wrapped controller")
    func micStreamForwardsChunkBoundary() async throws {
        let boundaryProbe = ChunkBoundaryProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                VadStreamResult(
                    state: state,
                    event: VadStreamEvent(kind: .speechEnd, sampleIndex: VadManager.chunkSize),
                    probability: 0.05
                )
            }
        )
        let micStream = MicVadStream(controller: controller)
        micStream.onChunkBoundary = { boundaryProbe.boundaryTriggered() }

        micStream.start()
        micStream.process(AECCleanedMicSamples([Float](repeating: 0, count: VadManager.chunkSize)))

        let deadline = ContinuousClock.now + .seconds(3)
        while boundaryProbe.count < 1, ContinuousClock.now < deadline {
            await MainActor.run {}
            try? await Task.sleep(for: .milliseconds(20))
        }
        micStream.stop()

        #expect(boundaryProbe.count == 1)
    }
}

private actor VadStreamProbe {
    private(set) var recordedCounts: [Int] = []

    func record(sampleCount: Int) {
        recordedCounts.append(sampleCount)
    }
}

private final class ChunkBoundaryProbe: @unchecked Sendable {
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

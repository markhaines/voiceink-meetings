// Fork-owned (no donor equivalent). Not a port.
//
// Proves the intended wiring for MeetingVadStreams.swift's compile-time stream boundary:
// - MicVadStream.process only accepts AECCleanedMicSamples and actually reaches the wrapped
//   StreamingVadController.
// - SystemVadStream.process only accepts RawSystemSamples and actually reaches the wrapped
//   StreamingVadController.
// - Both forward onChunkBoundary and start/stop correctly.
// - Two cheap, deterministic static scans catch the two ways production code could bypass the
//   compile-time boundary entirely:
//   - processAudioCallSitesAreFacadeOnly: a direct StreamingVadController.processAudio(_:) call
//     site anywhere under VoiceInk/ outside MeetingVadStreams.swift.
//   - unsafeTestOnlyMintIsNeverUsedInProduction: a call to
//     AECCleanedMicSamples.unsafeUnattestedForTestsOnly(_:) -- the DEBUG-only test escape hatch
//     -- anywhere under VoiceInk/ outside MeetingVadStreams.swift. THIRD ROUND fix: this closes
//     the gap where the escape hatch, being `#if DEBUG`-gated rather than sealed, compiles
//     cleanly in exactly the Debug configuration the next integrator will actually be working
//     in, and would otherwise hand raw mic straight into the mic VAD there with no error.
//
// Both scans are plain substring text scans, not real parsers: neither catches a call reached
// only through a stored/partially-applied method reference (e.g.
// `let fn = AECCleanedMicSamples.unsafeUnattestedForTestsOnly; fn(x)`), which does not contain
// the literal substring being searched for. Accepted, disclosed limit -- not something either
// scan tries to close.
//
// What this file does NOT and CANNOT test with a normal @Test: that certain lines fail to
// compile. Swift Testing has no "assert this does not compile" facility, and this project has no
// separate negative-compilation-test harness. Those claims are properties of the type system
// (see MeetingVadStreams.swift's header for exactly what is and isn't enforced) — each is left
// commented out below with the EXACT compiler error it produces, captured by hand: uncomment the
// line, build (VoiceInkTests, Debug), read the error, then re-comment. Three such controls exist
// in this file:
//
// 1. Crossing the mic/system wrappers (`MeetingVadStreamsTests.swift`, this suite, inside
//    `micStreamForwardsCleanedSamples`): `micStream.process(RawSystemSamples([...]))` fails with
//    "cannot convert value of type 'RawSystemSamples' to expected argument type
//    'AECCleanedMicSamples'" (and the mirror error for the system side).
// 2. Constructing `AECCleanedMicSamples` directly from this file
//    (`micStreamForwardsCleanedSamples`): `AECCleanedMicSamples([Float](repeating: 0, count: 1))`
//    fails with "'AECCleanedMicSamples' initializer is inaccessible due to 'fileprivate'
//    protection level" -- verbatim, captured by hand.
// 3. Satisfying `AECMicOutputAttestation` from this file (`FakeAECAttestation` type, below,
//    left as a negative control): the `_seal` requirement can be given the right TYPE, but not
//    a VALUE of it -- `AECAttestationSeal()` fails with "'AECAttestationSeal' initializer is
//    inaccessible due to 'fileprivate' protection level" -- verbatim, captured by hand.

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
        micStream.process(.unsafeUnattestedForTestsOnly([Float](repeating: 0, count: VadManager.chunkSize)))

        let deadline = ContinuousClock.now + .seconds(2)
        while await probe.recordedCounts.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        micStream.stop()

        #expect(await probe.recordedCounts == [VadManager.chunkSize])

        // Negative control 1 (see file header): crossing the wrappers must fail to build, not
        // fail at runtime.
        // micStream.process(RawSystemSamples([Float](repeating: 0, count: VadManager.chunkSize)))

        // Negative control 2 (see file header): constructing AECCleanedMicSamples directly, even
        // from this file, must fail to build -- `init` is `fileprivate` to MeetingVadStreams.swift,
        // not to this file.
        // _ = AECCleanedMicSamples([Float](repeating: 0, count: 1))
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

        // Negative control 1, mirrored (see file header): crossing the wrappers the other way
        // must fail to build, not fail at runtime.
        // systemStream.process(AECCleanedMicSamples.unsafeUnattestedForTestsOnly([Float](repeating: 0, count: VadManager.chunkSize)))
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
        micStream.process(.unsafeUnattestedForTestsOnly([Float](repeating: 0, count: VadManager.chunkSize)))

        let deadline = ContinuousClock.now + .seconds(3)
        while boundaryProbe.count < 1, ContinuousClock.now < deadline {
            await MainActor.run {}
            try? await Task.sleep(for: .milliseconds(20))
        }
        micStream.stop()

        #expect(boundaryProbe.count == 1)
    }

    @Test("no production call site drives StreamingVadController.processAudio directly, bypassing the facade")
    func processAudioCallSitesAreFacadeOnly() throws {
        let offenders = try Self.scanProductionSourceForOffendingSubstring(".processAudio(")

        #expect(
            offenders.isEmpty,
            """
            Found direct StreamingVadController.processAudio(_:) call site(s) outside \
            MeetingVadStreams.swift -- this bypasses the AEC-boundary facade \
            (MicVadStream/SystemVadStream) entirely:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    // THIRD ROUND fix: AECCleanedMicSamples.unsafeUnattestedForTestsOnly(_:) is only `#if DEBUG`
    // gated, not sealed -- so it compiles cleanly, and hands raw mic straight into the mic VAD
    // with no error, in exactly the Debug configuration the next integrator (whoever writes the
    // real meeting-engine glue code) will actually be developing against. This test closes that
    // gap the same way processAudioCallSitesAreFacadeOnly closes the direct-processAudio gap: a
    // static scan for the one substring that identifies the escape hatch, everywhere under
    // VoiceInk/ except its own definition.
    @Test("no production call site drives AECCleanedMicSamples.unsafeUnattestedForTestsOnly, bypassing attestation")
    func unsafeTestOnlyMintIsNeverUsedInProduction() throws {
        let offenders = try Self.scanProductionSourceForOffendingSubstring("unsafeUnattestedForTestsOnly(")

        #expect(
            offenders.isEmpty,
            """
            Found AECCleanedMicSamples.unsafeUnattestedForTestsOnly(_:) call site(s) outside \
            MeetingVadStreams.swift -- this is a DEBUG-only test escape hatch that hands back \
            samples with NO attestation they passed through AEC. Production glue code must \
            mint AECCleanedMicSamples from a real AECMicOutputAttestation instead (see \
            MeetingVadStreams.swift's AECCleanedMicSamples.mint(from:) and its header comment):
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Shared by both static-scan tests above. Scans every `.swift` file under `VoiceInk/`
    /// (production code only, not `Tests/`) except `MeetingVadStreams.swift` itself for
    /// `needle`, returning the paths of any file that contains it. A plain substring scan, not a
    /// real parser -- see this file's header comment for what that does and does not catch.
    private static func scanProductionSourceForOffendingSubstring(_ needle: String) throws -> [String] {
        // Resolve the repo root from this test file's own path, so this works regardless of
        // where the repo is checked out (a local Mac vs. a CI runner).
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()  // MeetingVadStreamsTests.swift -> Transcription/
            .deletingLastPathComponent()  // Transcription/ -> Meetings/
            .deletingLastPathComponent()  // Meetings/ -> Features/
            .deletingLastPathComponent()  // Features/ -> VoiceInkTests/
            .deletingLastPathComponent()  // VoiceInkTests/ -> Tests/
            .deletingLastPathComponent()  // Tests/ -> repo root
        let productionRoot = repoRoot.appendingPathComponent("VoiceInk", isDirectory: true)

        guard FileManager.default.fileExists(atPath: productionRoot.path) else {
            Issue.record("could not resolve VoiceInk/ from #filePath -- repo layout may have changed")
            return []
        }

        let allowedFileName = "MeetingVadStreams.swift"
        var offenders: [String] = []

        let enumerator = FileManager.default.enumerator(
            at: productionRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != allowedFileName else { continue }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if contents.contains(needle) {
                offenders.append(url.path(percentEncoded: false))
            }
        }

        return offenders
    }
}

// Negative control 3 (see file header): a type in this file attempting to conform to
// `AECMicOutputAttestation` must fail to build, because it cannot produce an `AECAttestationSeal`
// -- `AECAttestationSeal.init()` is `fileprivate` to MeetingVadStreams.swift, not to this file.
// Uncommenting this produces exactly:
//   "'AECAttestationSeal' initializer is inaccessible due to 'fileprivate' protection level"
// (verbatim, captured by hand; see file header item 3).
//
// private struct FakeAECAttestation: AECMicOutputAttestation {
//     var cleanedMicSamples: [Float] { [] }
//     var _seal: AECAttestationSeal { AECAttestationSeal() }
// }

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

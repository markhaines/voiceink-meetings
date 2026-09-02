// Fork-owned (no donor equivalent). Not a port.
//
// Proves MeetingVadStreams.swift's property: raw mic samples never reach the mic VAD; they pass
// through acoustic echo cancellation first. See that file's header for the design and for why the
// two previous attempts (a `fileprivate init`, then a sealed attestation protocol) were both
// defeated.
//
// Positive tests here:
// - MicVadStream.process runs the echo canceller and drives the wrapped StreamingVadController
//   with the CANCELLER'S OUTPUT, not with what the caller passed in. This is the property itself,
//   tested directly: the stub canceller returns a distinguishable buffer, and the test asserts the
//   VAD saw that and not the raw input.
// - MicVadStream.processFarEndReference feeds system audio to the canceller as the far-end
//   reference and drains any cleaned mic output into the mic VAD (donor parity, see below).
// - MicVadStream honours the donor's `!cleanedFloat.isEmpty` guard: an empty canceller result
//   drives the VAD not at all.
// - SystemVadStream.process only accepts RawSystemSamples and reaches its controller unmodified.
// - Both forward onChunkBoundary and start/stop.
// - Two cheap, deterministic static scans over production source catch the two textual ways
//   production code could sidestep the facade (see the tests themselves for exactly what each
//   does and does not catch).
//
// ===========================================================================================
// NEGATIVE CONTROLS: THE ATTACK LIST
// ===========================================================================================
//
// Swift Testing has no "assert this does not compile" facility and this project has no negative
// compilation harness, so each attack below was run by hand FROM THIS FILE (a separate file in
// the app target, with `@testable import VoiceInk`, which unlocks `internal` but NOT
// `fileprivate`/`private`), the compiler error captured verbatim, and the line left commented out
// next to its error. To re-verify any of them: uncomment, build the VoiceInkTests target in
// Debug, read the error, re-comment.
//
// Every attack below FAILS TO COMPILE except where explicitly marked ACCEPTED RESIDUAL. Each was
// run through a FULL `xcodebuild build-for-testing` of this target, not `swiftc -typecheck`:
// A6 below is rejected only by a definite-initialisation diagnostic, which type-checking alone
// does not run, so a typecheck-only sweep would have reported it as compiling.
//
//  A1. Direct construction of the receipt type from [Float].
//      `_ = AECCleanedMicSamples([Float](repeating: 0, count: 1))`
//      -> error: 'AECCleanedMicSamples' initializer is inaccessible due to 'fileprivate'
//         protection level
//      (see `micStreamCancelsBeforeVad`)
//
//  A2. THE v2 DEFEAT: conform to the attestation protocol with a trapping witness, then mint.
//      `struct Defeat: AECMicOutputAttestation { var _seal: AECAttestationSeal { fatalError() } }`
//      -> error: cannot find type 'AECMicOutputAttestation' in scope
//      -> error: cannot find type 'AECAttestationSeal' in scope
//      (those two are all the compiler emits: the unresolved types short-circuit before it
//      reaches the `AECCleanedMicSamples.mint(from:)` call, which is also gone)
//      The protocol, the seal and `mint(from:)` are deleted outright: there is no inbound
//      cleanliness claim left to make, so the defeat has nothing to attack.
//      (see `AttackA2` at the bottom of this file)
//
//  A3. Conform with a witness returning a legitimately-obtained value instead of a trap.
//      NOT APPLICABLE, and not merely unreachable: no such protocol exists any more (A2), and
//      there is no value of any this-file-sealed type to obtain in the first place. Recorded so
//      the next reviewer does not have to re-derive that this variant died with A2.
//
//  A4. Synthesised memberwise initialiser.
//      `_ = AECCleanedMicSamples(storedSamples: [Float](repeating: 0, count: 1))`
//      -> error: extraneous argument label 'storedSamples:' in call
//      -> error: 'AECCleanedMicSamples' initializer is inaccessible due to 'fileprivate'
//         protection level
//      (declaring an explicit initializer suppresses the memberwise one; the payload is `private`
//      besides, so even a synthesised one would be `private`)
//      (see `AttackA4` at the bottom of this file)
//
//  A5. THE THIRD DEFEAT, found while attacking this design and not caught by either earlier
//      review round. An extension in ANOTHER FILE of the same module adding a designated
//      initializer that assigns the stored property directly. Against the OLD shape
//      (`let samples: [Float]`, internal) this COMPILED AND LINKED CLEANLY, with no seal and no
//      protocol conformance — it defeated v1 and v2 alike. Against the current shape:
//      `extension AECCleanedMicSamples { init(raw: [Float]) { self.storedSamples = raw } }`
//      -> error: 'storedSamples' is inaccessible due to 'private' protection level
//      (see `AttackA5` at the bottom of this file)
//
//  A6. The A5 variant that initialises nothing at all, which type-checking alone lets through
//      and only definite-initialisation rejects.
//      `extension AECCleanedMicSamples { init(raw: [Float]) { } }`
//      -> error: 'self.init' isn't called on all paths before returning from initializer
//      (because the payload is `private`, the extension's file can see no stored property to
//      initialise, so the initializer is required to DELEGATE -- and the only initializer it
//      could delegate to is the `fileprivate` one it cannot reach. Note this is a definite-
//      initialisation diagnostic, not a type-check one: `swiftc -typecheck` alone does NOT
//      report it, which is why every attack here was run through a full build.)
//      (see `AttackA6` at the bottom of this file)
//
//  A7. Codable/decoder-based construction, retro-conformed from another file.
//      `extension AECCleanedMicSamples: Decodable {}`
//      -> error: extension outside of file declaring struct 'AECCleanedMicSamples' prevents
//         automatic synthesis of 'init(from:)' for protocol 'Decodable'
//      (see `AttackA7` at the bottom of this file)
//
//  A8. Reflection. `Mirror` is read-only and Swift exposes no public runtime API to allocate an
//      instance of a nominal type without calling one of its initializers. No construction route;
//      nothing to compile.
//
//  A9. A generic constraint reaching the type. A generic function can only construct `T` through
//      a protocol requirement it constrains `T` to (e.g. `T: Initializable`), and
//      `AECCleanedMicSamples` conforms to nothing that vends an initializer — only `Sendable`,
//      which has no requirements. Standard-library generic entry points that produce values
//      (`Array.init(repeating:count:)`, `Optional`, …) all need an existing value first.
//
// A10. ACCEPTED RESIDUAL — `unsafeBitCast`.
//      `unsafeBitCast([Float](repeating: 0, count: 1), to: AECCleanedMicSamples.self)`
//      COMPILES AND WORKS: the struct is layout-compatible with its single payload. This is
//      unpreventable in Swift for any type, the API name announces itself, and it is in the same
//      visible-deliberate-act category as passing a no-op canceller. Not chased. It IS flagged by
//      `forgedCleanedSampleConstructionIsAbsentFromProduction` below when it appears in
//      production code that also names the type — belt-and-braces, not a guarantee.
//
// A11. ACCEPTED RESIDUAL — a no-op `MicEchoCanceller` (one whose `processStreamingMic` returns
//      its input). Compiles by design: the abstraction has to be conformable or the AEC branch
//      could not satisfy it. Visible and deliberate in review. See MeetingVadStreams.swift's
//      "Residual holes" section.
//
// A12. Crossing the mic and system streams. Still a compile error, as before:
//      `micStream.process(RawSystemSamples([...]))`
//      -> error: cannot convert value of type 'RawSystemSamples' to expected argument type
//         'RawMicSamples'
//      `systemStream.process(RawMicSamples([...]))`
//      -> error: cannot convert value of type 'RawMicSamples' to expected argument type
//         'RawSystemSamples'
//      (see `micStreamCancelsBeforeVad` and `systemStreamForwardsRawSamples`)
//
// A13. Building a MicVadStream with no canceller at all, via the internal test seam.
//      `_ = MicVadStream(controller: someController)`
//      -> error: missing argument for parameter 'echoCanceller' in call
//      There is no controller-only initializer: every way to build a mic stream supplies a
//      canceller.
//      (see `AttackA13` at the bottom of this file)
//
// ===========================================================================================
// ATTACKS A14-A17 target a SEPARATE defeated shape: `MicVadStream.acceptFlushed(_ alreadyCleaned:
// [Float])`, an internal method (not `AECCleanedMicSamples` itself) that took arbitrary floats
// from ANY caller and minted a receipt for them -- "caller declares cleanliness" via a laundering
// METHOD rather than via the receipt type's constructibility. It is DELETED outright and replaced
// by `flushCanceller()`, which takes no floats at all and drains `echoCanceller` (this instance's
// OWN canceller) itself. These attacks probe that the deletion is real and that the replacement
// cannot be reopened into the same shape from outside this file.
// ===========================================================================================
//
// A14. Calling the deleted method by its old name.
//      `_ = micStream.acceptFlushed([Float](repeating: 0, count: 1))`
//      -> error: value of type 'MicVadStream' has no member 'acceptFlushed'
//      (see `AttackA14` at the bottom of this file)
//
// A15. Reintroducing the exact defeated shape from another file: an extension on `MicVadStream`
//      adding a method that takes arbitrary floats and mints a receipt for them by calling
//      `AECCleanedMicSamples`'s initializer directly. This is attack A1 wearing a different call
//      site (a method body instead of a bare expression), and fails for the identical reason:
//      the initializer is `fileprivate` to MeetingVadStreams.swift, so no other file -- an
//      extension included -- can reach it, regardless of which type or method is doing the
//      calling.
//      `extension MicVadStream { func launder(_ f: [Float]) -> AECCleanedMicSamples { AECCleanedMicSamples(f) } }`
//      -> error: 'AECCleanedMicSamples' initializer is inaccessible due to 'fileprivate'
//         protection level
//      (see `AttackA15` at the bottom of this file)
//
// A16. Reaching the canceller directly instead of through `flushCanceller()`, to drive it with
//      caller-chosen timing/arguments from outside. `echoCanceller` is `private`, not merely
//      unexposed by convention:
//      `extension MicVadStream { func peek() -> MicEchoCanceller { echoCanceller } }`
//      -> error: 'echoCanceller' is inaccessible due to 'private' protection level
//      (see `AttackA16` at the bottom of this file)
//
// A17. Subclassing to override `flushCanceller()` with a version that accepts injected floats.
//      `MicVadStream` is `final`:
//      `private final class Sub: MicVadStream {}` reached via
//      `class NotFinal: MicVadStream {}`
//      -> error: inheritance from a final class 'MicVadStream'
//      (see `AttackA17` at the bottom of this file)

import FluidAudio
import Foundation
import Testing
@testable import VoiceInk

/// Stub echo canceller. Returns a buffer that is DISTINGUISHABLE from its input (a different
/// sample count and a marker value), so a test can tell whether the VAD was driven with the
/// canceller's output or with the raw input that was handed in. That distinction is the whole
/// property under test.
private final class StubEchoCanceller: MicEchoCanceller, @unchecked Sendable {
    static let marker: Float = 0.5

    private let lock = NSLock()
    private var micCallCount = 0
    private var flushCallCount = 0
    private var systemFedSamples: [[Float]] = []
    private let cleanedForMic: [Float]
    private let cleanedForDrain: [Float]
    private let cleanedForFlush: [Float]

    /// - Parameters:
    ///   - cleanedForMic: what `processStreamingMic` returns for a non-empty input.
    ///   - cleanedForDrain: what it returns for the empty-input drain call that follows a
    ///     far-end reference feed.
    ///   - cleanedForFlush: what `flushStreamingMic` returns -- the samples this canceller
    ///     claims were still buffered internally. Distinct from the other two so a test can
    ///     tell which path produced a given receipt.
    init(cleanedForMic: [Float], cleanedForDrain: [Float] = [], cleanedForFlush: [Float] = []) {
        self.cleanedForMic = cleanedForMic
        self.cleanedForDrain = cleanedForDrain
        self.cleanedForFlush = cleanedForFlush
    }

    func processStreamingMic(_ rawMicSamples: [Float]) -> [Float] {
        lock.withLock { micCallCount += 1 }
        return rawMicSamples.isEmpty ? cleanedForDrain : cleanedForMic
    }

    func feedSystemSamples(_ systemSamples: [Float]) {
        lock.withLock { systemFedSamples.append(systemSamples) }
    }

    func flushStreamingMic() -> [Float] {
        lock.withLock { flushCallCount += 1 }
        return cleanedForFlush
    }

    var micCalls: Int { lock.withLock { micCallCount } }
    var flushCalls: Int { lock.withLock { flushCallCount } }
    var fedSystemBuffers: [[Float]] { lock.withLock { systemFedSamples } }
}

@Suite("MeetingVadStreams")
struct MeetingVadStreamsTests {
    /// The property itself: what reaches the VAD is the canceller's output, not the caller's
    /// input. The stub returns a buffer of a different length carrying a marker value, so a
    /// design that forwarded the raw input would fail on both counts.
    @Test("MicVadStream runs AEC first and drives the VAD with the cleaned samples, not the raw ones")
    func micStreamCancelsBeforeVad() async throws {
        let cleaned = [Float](repeating: StubEchoCanceller.marker, count: VadManager.chunkSize)
        let canceller = StubEchoCanceller(cleanedForMic: cleaned)
        let probe = VadStreamProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { samples, state in
                await probe.record(samples: samples)
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )
        let micStream = MicVadStream(controller: controller, echoCanceller: canceller)

        micStream.start()
        // Raw mic: twice the chunk size, all zeros. Nothing like what the canceller returns.
        let receipt = micStream.process(RawMicSamples([Float](repeating: 0, count: VadManager.chunkSize * 2)))

        let deadline = ContinuousClock.now + .seconds(2)
        while await probe.recordedBuffers.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        micStream.stop()

        let seen = await probe.recordedBuffers
        #expect(seen.count == 1)
        // The VAD saw the CLEANED buffer: right length, and carrying the canceller's marker.
        #expect(seen.first?.count == VadManager.chunkSize)
        #expect(seen.first?.allSatisfy { $0 == StubEchoCanceller.marker } == true)
        #expect(canceller.micCalls == 1)
        // The receipt handed back carries the same cleaned samples, for the chunk recorder.
        #expect(receipt.samples == cleaned)
        #expect(receipt.isEmpty == false)

        // Attack A12 (see file header): crossing the wrappers must fail to build.
        // micStream.process(RawSystemSamples([Float](repeating: 0, count: VadManager.chunkSize)))

        // Attack A1 (see file header): constructing the receipt directly, even from this file,
        // must fail to build -- `init` is `fileprivate` to MeetingVadStreams.swift.
        // _ = AECCleanedMicSamples([Float](repeating: 0, count: 1))

        // Attack A10 (see file header): ACCEPTED RESIDUAL. This one COMPILES and works. Left
        // commented out because it is a documented, accepted hole, not because it fails.
        // _ = unsafeBitCast([Float](repeating: 0, count: 1), to: AECCleanedMicSamples.self)
    }

    /// Donor parity for the `!cleanedFloat.isEmpty` guard (MeetingSession.swift:1233): when AEC
    /// yields nothing yet, the VAD must be driven not at all rather than with an empty buffer.
    @Test("MicVadStream does not drive the VAD when AEC yields no samples")
    func micStreamSkipsVadOnEmptyCancellerOutput() async throws {
        let canceller = StubEchoCanceller(cleanedForMic: [])
        let probe = VadStreamProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { samples, state in
                await probe.record(samples: samples)
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )
        let micStream = MicVadStream(controller: controller, echoCanceller: canceller)

        micStream.start()
        let receipt = micStream.process(RawMicSamples([Float](repeating: 0, count: VadManager.chunkSize)))
        try? await Task.sleep(for: .milliseconds(200))
        micStream.stop()

        #expect(await probe.recordedBuffers.isEmpty)
        #expect(canceller.micCalls == 1)
        #expect(receipt.isEmpty)
    }

    /// Donor parity for `enqueueRealtimeSystemSamples` (MeetingSession.swift:1238-1265): system
    /// audio is the AEC far-end reference, and the cleaned mic output it unblocks is drained into
    /// the MIC VAD. This path can produce mic VAD input, which is why it lives on MicVadStream.
    @Test("MicVadStream.processFarEndReference feeds AEC and drains cleaned mic output into the mic VAD")
    func micStreamDrainsFarEndReference() async throws {
        let drained = [Float](repeating: StubEchoCanceller.marker, count: VadManager.chunkSize)
        let canceller = StubEchoCanceller(cleanedForMic: [], cleanedForDrain: drained)
        let probe = VadStreamProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { samples, state in
                await probe.record(samples: samples)
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )
        let micStream = MicVadStream(controller: controller, echoCanceller: canceller)

        let systemAudio = [Float](repeating: 0.25, count: VadManager.chunkSize)
        micStream.start()
        let receipt = micStream.processFarEndReference(RawSystemSamples(systemAudio))

        let deadline = ContinuousClock.now + .seconds(2)
        while await probe.recordedBuffers.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        micStream.stop()

        #expect(canceller.fedSystemBuffers == [systemAudio])
        #expect(await probe.recordedBuffers.first?.allSatisfy { $0 == StubEchoCanceller.marker } == true)
        #expect(receipt.samples == drained)
    }

    /// `flushCanceller()` replaces the deleted `acceptFlushed(_ alreadyCleaned: [Float])` --
    /// see this file's header, attacks A14-A17. The property under test is the inversion itself:
    /// `MicVadStream` calls `echoCanceller.flushStreamingMic()` ITSELF and mints the receipt from
    /// that call's own result, so there is no floats parameter for a caller to have supplied
    /// anything through in the first place. Matches `acceptFlushed`'s old, still-correct
    /// contract otherwise: does not drive the wrapped VAD controller (donor
    /// `appendCleanedMicSamplesOnQueue` never does, for any flushed/cleaned buffer).
    @Test("MicVadStream.flushCanceller drains its OWN canceller and does not drive the VAD")
    func micStreamFlushesOwnCancellerWithoutDrivingVad() async throws {
        let flushed = [Float](repeating: StubEchoCanceller.marker, count: VadManager.chunkSize)
        let canceller = StubEchoCanceller(cleanedForMic: [], cleanedForFlush: flushed)
        let probe = VadStreamProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { samples, state in
                await probe.record(samples: samples)
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )
        let micStream = MicVadStream(controller: controller, echoCanceller: canceller)

        micStream.start()
        let receipt = micStream.flushCanceller()
        try? await Task.sleep(for: .milliseconds(200))
        micStream.stop()

        // The receipt carries exactly what the CANCELLER produced from its own internal
        // buffer -- there is no caller-supplied buffer in this call at all.
        #expect(receipt.samples == flushed)
        #expect(canceller.flushCalls == 1)
        // Matches acceptFlushed's old contract: this call never touches the wrapped controller.
        #expect(await probe.recordedBuffers.isEmpty)

        // Attack A14 (see file header): the deleted method name must no longer resolve.
        // _ = micStream.acceptFlushed([Float](repeating: 0, count: 1))
    }

    @Test("SystemVadStream forwards RawSystemSamples to the wrapped controller")
    func systemStreamForwardsRawSamples() async throws {
        let probe = VadStreamProbe()
        let controller = StreamingVadController(
            minChunkDuration: 0,
            maxChunkDuration: 3600,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { samples, state in
                await probe.record(samples: samples)
                return VadStreamResult(state: state, event: nil, probability: 0.0)
            }
        )
        let systemStream = SystemVadStream(controller: controller)

        systemStream.start()
        systemStream.process(RawSystemSamples([Float](repeating: 0, count: VadManager.chunkSize)))

        let deadline = ContinuousClock.now + .seconds(2)
        while await probe.recordedBuffers.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        systemStream.stop()

        #expect(await probe.recordedBuffers.map(\.count) == [VadManager.chunkSize])

        // Attack A12 mirrored (see file header): crossing the wrappers the other way must fail
        // to build.
        // systemStream.process(RawMicSamples([Float](repeating: 0, count: VadManager.chunkSize)))
    }

    @Test("MicVadStream forwards onChunkBoundary from the wrapped controller")
    func micStreamForwardsChunkBoundary() async throws {
        let boundaryProbe = ChunkBoundaryProbe()
        let canceller = StubEchoCanceller(
            cleanedForMic: [Float](repeating: StubEchoCanceller.marker, count: VadManager.chunkSize)
        )
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
        let micStream = MicVadStream(controller: controller, echoCanceller: canceller)
        micStream.onChunkBoundary = { boundaryProbe.boundaryTriggered() }

        micStream.start()
        micStream.process(RawMicSamples([Float](repeating: 0, count: VadManager.chunkSize)))

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
        let offenders = try Self.scanProductionSourceForOffendingSubstrings([".processAudio("])

        #expect(
            offenders.isEmpty,
            """
            Found direct StreamingVadController.processAudio(_:) call site(s) outside \
            MeetingVadStreams.swift -- this bypasses the AEC facade (MicVadStream) entirely and \
            can put raw mic samples into the mic VAD:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Successor to the old `unsafeTestOnlyMintIsNeverUsedInProduction` scan, kept working across
    /// the redesign rather than dropped. The DEBUG escape hatch it used to guard
    /// (`unsafeUnattestedForTestsOnly`) and the defeated attestation apparatus (`mint(from:)`) are
    /// both DELETED now, so this scan does two jobs: it fails if either is ever reintroduced into
    /// production code, and it fails on the remaining textual forgery routes for the receipt type
    /// -- a direct `AECCleanedMicSamples(` construction, or an `unsafeBitCast` in a file that
    /// names the type (attack A10, the accepted residual).
    ///
    /// Like the scan above this is a plain substring text scan, not a parser. It does not catch a
    /// call reached only through a stored or partially-applied reference, and `unsafeBitCast` is
    /// only flagged when it shares a file with the type's name. Accepted, disclosed limits.
    @Test("no production code forges AECCleanedMicSamples or reintroduces a construction escape hatch")
    func forgedCleanedSampleConstructionIsAbsentFromProduction() throws {
        // Direct construction and the two deleted escape hatches, unconditionally.
        var offenders = try Self.scanProductionSourceForOffendingSubstrings([
            "AECCleanedMicSamples(",
            "unsafeUnattestedForTestsOnly",
            "AECMicOutputAttestation",
            "AECAttestationSeal",
        ])

        // unsafeBitCast only counts as an offence in a file that also names the receipt type;
        // unrelated uses elsewhere in the app are none of this test's business.
        offenders += try Self.scanProductionSourceForFilesContainingAll([
            "unsafeBitCast",
            "AECCleanedMicSamples",
        ])

        #expect(
            offenders.isEmpty,
            """
            Found production code outside MeetingVadStreams.swift that constructs or forges \
            AECCleanedMicSamples, or reintroduces the deleted attestation/test escape hatch. \
            AECCleanedMicSamples is a receipt handed back by MicVadStream.process(_:), never \
            something production code builds for itself -- building one asserts samples passed \
            through AEC when nothing checked that they did:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Scans every `.swift` file under `VoiceInk/` (production code only, not `Tests/`) except
    /// `MeetingVadStreams.swift` itself, returning `path: needle` for each needle found.
    private static func scanProductionSourceForOffendingSubstrings(_ needles: [String]) throws -> [String] {
        try scanProductionSource { path, contents in
            needles.compactMap { contents.contains($0) ? "\(path): \($0)" : nil }
        }
    }

    /// As above, but only reports a file when it contains EVERY needle.
    private static func scanProductionSourceForFilesContainingAll(_ needles: [String]) throws -> [String] {
        try scanProductionSource { path, contents in
            needles.allSatisfy(contents.contains) ? ["\(path): \(needles.joined(separator: " + "))"] : []
        }
    }

    private static func scanProductionSource(
        _ inspect: (String, String) -> [String]
    ) throws -> [String] {
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
            offenders += inspect(url.path(percentEncoded: false), contents)
        }

        return offenders
    }
}

// ===========================================================================================
// Negative controls for attacks that need a top-level declaration. See this file's header for
// each attack's verbatim compiler error. All are commented out; uncomment one, build, re-comment.
// ===========================================================================================

// Attack A2 -- the v2 defeat (trapping witness). The protocol and the seal no longer exist:
//   error: cannot find type 'AECMicOutputAttestation' in scope
//   error: cannot find type 'AECAttestationSeal' in scope
//
// private struct AttackA2: AECMicOutputAttestation {
//     var cleanedMicSamples: [Float] { [Float](repeating: 0, count: 1) }
//     var _seal: AECAttestationSeal { fatalError() }
// }
// private func attackA2() -> AECCleanedMicSamples { AECCleanedMicSamples.mint(from: AttackA2()) }

// Attack A4 -- synthesised memberwise initialiser:
//   error: extraneous argument label 'storedSamples:' in call
//   error: 'AECCleanedMicSamples' initializer is inaccessible due to 'fileprivate' protection level
//
// private func attackA4() -> AECCleanedMicSamples {
//     AECCleanedMicSamples(storedSamples: [Float](repeating: 0, count: 1))
// }

// Attack A5 -- THE THIRD DEFEAT: an extension in another file adding an initializer that assigns
// the stored property. Compiled cleanly against the old internal-`let` shape; against the current
// `private` shape:
//   error: 'storedSamples' is inaccessible due to 'private' protection level
//
// extension AECCleanedMicSamples {
//     init(attackA5 raw: [Float]) { self.storedSamples = raw }
// }

// Attack A6 -- the A5 variant that assigns nothing, which `swiftc -typecheck` alone permits and
// only a full build rejects:
//   error: 'self.init' isn't called on all paths before returning from initializer
//
// extension AECCleanedMicSamples {
//     init(attackA6 raw: [Float]) { }
// }

// Attack A7 -- Codable/decoder-based construction retro-conformed from another file:
//   error: extension outside of file declaring struct 'AECCleanedMicSamples' prevents automatic
//          synthesis of 'init(from:)' for protocol 'Decodable'
//
// extension AECCleanedMicSamples: Decodable {}

// Attack A13 -- building a mic stream with no canceller via the internal test seam:
//   error: missing argument for parameter 'echoCanceller' in call
//
// private func attackA13(controller: StreamingVadController) -> MicVadStream {
//     MicVadStream(controller: controller)
// }

// Attack A14 -- calling the deleted `acceptFlushed` by its old name. Left inline in
// `micStreamFlushesOwnCancellerWithoutDrivingVad` above (needs a live `micStream` value) rather
// than at top level here:
//   error: value of type 'MicVadStream' has no member 'acceptFlushed'

// Attack A15 -- reintroducing the defeated "caller supplies floats" shape via an extension on
// MicVadStream (rather than a bare top-level expression, unlike A1) that constructs the receipt
// directly. Fails for the same reason as A1: the initializer is fileprivate to
// MeetingVadStreams.swift, and that does not change depending on which type's extension is
// doing the calling.
//   error: 'AECCleanedMicSamples' initializer is inaccessible due to 'fileprivate' protection
//          level
//
// extension MicVadStream {
//     func attackA15Launder(_ floats: [Float]) -> AECCleanedMicSamples {
//         AECCleanedMicSamples(floats)
//     }
// }

// Attack A16 -- reaching the canceller directly from another file, to drive it with
// caller-chosen arguments/timing outside `flushCanceller()`'s own call:
//   error: 'echoCanceller' is inaccessible due to 'private' protection level
//
// extension MicVadStream {
//     func attackA16PeekCanceller() -> MicEchoCanceller {
//         echoCanceller
//     }
// }

// Attack A17 -- subclassing to override `flushCanceller()` with a version that accepts injected
// floats. `MicVadStream` is `final`. This one is doubly blocked: the class declaration itself
// fails, AND (Swift still typechecks the body) the injected-floats construction inside it hits
// the same fileprivate wall as A1/A15:
//   error: inheritance from a final class 'MicVadStream'
//   error: 'AECCleanedMicSamples' initializer is inaccessible due to 'fileprivate' protection
//          level
//
// private class AttackA17Sub: MicVadStream {
//     func attackFlush() -> AECCleanedMicSamples {
//         AECCleanedMicSamples([Float](repeating: 0, count: 1))
//     }
// }

private actor VadStreamProbe {
    private(set) var recordedBuffers: [[Float]] = []

    func record(samples: [Float]) {
        recordedBuffers.append(samples)
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

// Fork-owned (no donor equivalent). Not a port.
//
// StreamingVadController.processAudio(_:) takes an untyped `[Float]`, and is fed from two
// different call sites in the donor's MeetingSession.swift with two DIFFERENT kinds of samples:
//   - the mic VAD controller gets ONLY AEC-cleaned mic samples
//     (MeetingSession.swift:1226-1233, `enqueueRealtimeMicSamples`:
//     "Meeting mic chunks must be driven by the cleaned mic stream. Raw mic VAD sees speaker
//     playback bleed and can create false `You` chunks even when AEC removed that speech from
//     the final mic audio.")
//   - the system VAD controller gets ONLY raw system samples
//     (MeetingSession.swift:1257-1262, `enqueueRealtimeSystemSamples`)
// Nothing in StreamingVadController's own signature enforces that split — an integrator wiring
// a later adapter stage could pass raw mic samples, or the wrong stream entirely, to either
// controller and nothing would complain until speaker-bleed "You" turns showed up in a real
// transcript. See ADAPTER-HANDOVER.md for the full picture.
//
// MicVadStream and SystemVadStream are a thin compile-time-enforced facade over
// StreamingVadController for exactly this: each accepts only its own nominal sample-wrapper
// type, so feeding a `RawSystemSamples` to `MicVadStream.process(_:)` (or an `AECCleanedMicSamples`
// to `SystemVadStream.process(_:)`) is a compile error, not a silent runtime defect. This
// deliberately does NOT edit StreamingVadController.swift itself — that file's port fidelity is
// verified byte-for-byte against the donor, and this facade only wraps it.
//
// What this DOES guarantee at compile time: you cannot accidentally cross the mic and system
// streams — a RawSystemSamples value cannot be handed to the mic VAD, and an
// AECCleanedMicSamples value cannot be handed to the system VAD, because the types are distinct
// and neither wrapper is convertible to the other without an explicit, visible unwrap + rewrap.
//
// SECOND ROUND, closing a real hole in the first version of this file: `AECCleanedMicSamples`
// used to have a plain, unrestricted `init(_ samples: [Float])`, so any file in the app target
// could write `AECCleanedMicSamples(rawMicFloats)` and hand it straight to
// `MicVadStream.process` with no compile error — the wrapper only defended against CROSSING mic
// and system, not against the actual property that matters: raw mic must never reach the mic
// VAD. `AECCleanedMicSamples.init` is now `fileprivate` — restricted to THIS file, not just to
// the module — so that direct call no longer compiles from anywhere else (see the negative
// control in MeetingVadStreamsTests.swift, and its captured compiler error). The only way to
// construct one from another file is `AECCleanedMicSamples.mint(from:)`, which requires a value
// conforming to `AECMicOutputAttestation` below.
//
// `AECMicOutputAttestation` is deliberately SEALED to this file too: its `_seal` requirement has
// type `AECAttestationSeal`, which is nameable anywhere in the module (it's `internal`, the
// default) but has NO accessible initializer outside this file — `init()` is `fileprivate`. A
// conforming type declared in another file can reference the type name, but it cannot construct
// a value of it (no public/internal init, no static factory anywhere), so it has no way to
// produce anything to return from `_seal`, so it cannot satisfy `AECMicOutputAttestation`, so it
// cannot call `mint(from:)` — full stop, today, for every file in the app target except this
// one. This is the standard Swift "sealed protocol via a non-constructible witness type" idiom,
// not an invented one-off trick. Verified by a second negative control in
// MeetingVadStreamsTests.swift (attempting the conformance from the test file) — its captured
// compiler error is quoted there too.
//
// The AEC port lives on a separate, still-unmerged branch (`phase-1-aec-dtln`, PR #6) as of this
// writing, so nothing here depends on its real types, and nothing there is edited. The intended
// integration shape is: once AEC lands, its own file adds a small conforming type (or an
// extension on its real output type) that implements `AECMicOutputAttestation` — which, because
// the protocol is sealed here, is only possible by SOMEONE EDITING THIS FILE to also grant that
// conformance a legitimate `_seal` value (e.g. a small internal factory added right here,
// reviewable in the same diff that wires AEC in). Until that happens, `mint(from:)` has zero
// legitimate callers anywhere in the codebase, which is correct and safe — there is no real AEC
// output to attest to yet.
//
// Residual limit, stated plainly: this closes the CARELESS/accidental path (a well-intentioned
// integrator writing `AECCleanedMicSamples(rawFloats)` or a naive extra conformance without also
// touching this file) — it does not, and within a single Swift module cannot, stop a determined
// actor from editing THIS file to weaken the seal (e.g. deleting `fileprivate`, or adding a
// throwaway conforming type right here) and shipping that as an innocuous-looking diff. Access
// control operates on files, not on intent, and Swift has no cross-file capability system short
// of a real module boundary. A separate SPM module (where `internal` would mean something) would
// close that residual gap too, but that touches project configuration and the package-trust
// file, which is out of scope for this stage and this agent's call — see ADAPTER-HANDOVER.md.
// One more concrete narrowing of the hole, disclosed precisely: `AECCleanedMicSamples
// .unsafeUnattestedForTestsOnly(_:)` (below, `#if DEBUG`-gated) exists so the test target can
// construct instances without a real AEC attestation. It does not exist in Release builds, so
// production misuse would fail Release compilation outright. But CI and the local Debug build
// (`VoiceInk Dev.app`) both build Debug — and Debug is exactly the configuration the NEXT
// integrator (the agent that writes the real MeetingEngine/MeetingSession-equivalent glue code)
// will be working in. A `#if DEBUG` gate alone is not narrow there: it compiles cleanly and
// hands raw mic straight into the mic VAD with no error, in precisely the build that matters.
// THIRD ROUND fix: `processAudioCallSitesAreFacadeOnly` in `MeetingVadStreamsTests.swift` was
// extended (see that test) to also fail if `unsafeUnattestedForTestsOnly(` appears anywhere
// under `VoiceInk/` outside this file's own definition — closing exactly that gap with the same
// cheap static-scan mechanism already used for the `processAudio` bypass, not a new mechanism.
// The renamed, harder-to-mistake-for-legitimate name is a second, independent mitigation on top
// of that scan, not a replacement for it.
//
// SEPARATELY, `StreamingVadController.processAudio(_:)` itself remains directly callable with a
// bare `[Float]` by ANYONE who imports it and skips this facade entirely — nothing about
// `MicVadStream`/`SystemVadStream` prevents that, because `StreamingVadController.swift` is a
// verbatim port that this stage deliberately does not modify. See "Bypassing this facade" below
// and ADAPTER-HANDOVER.md for what is and isn't done about that.
//
// Bypassing this facade: calling `StreamingVadController.processAudio(_:)` directly — on either
// the mic or the system controller — instead of going through `MicVadStream.process(_:)` /
// `SystemVadStream.process(_:)` is PROHIBITED for the mic path and bypasses every guarantee this
// file provides. Likewise, calling `AECCleanedMicSamples.unsafeUnattestedForTestsOnly(_:)` from
// anywhere other than `MeetingVadStreamsTests.swift` is PROHIBITED — its whole purpose is to let
// tests construct an instance without a real AEC attestation, and using it in production glue
// code reintroduces exactly the raw-mic-into-mic-VAD defect this file exists to prevent. Neither
// is preventable at compile time (the ported controller is intentionally left constructible and
// drivable directly, e.g. for the tests that verify its own port fidelity, and the DEBUG-only
// test escape hatch has to be callable from SOME other file or it couldn't serve tests at all).
// `MeetingVadStreamsTests.swift` has two cheap, deterministic static tests
// (`processAudioCallSitesAreFacadeOnly`, `unsafeTestOnlyMintIsNeverUsedInProduction`) that scan
// `VoiceInk/` (production code only, not `Tests/`) for each of those and fail if either is found
// outside this file — see those tests for exactly what they do and do not catch. Both are
// substring text scans, not real parsers: neither catches a call reached only through a
// stored/partially-applied method reference (`let fn = controller.processAudio; fn(x)`), which
// is an accepted, disclosed limit, not something either test tries to close.

import FluidAudio
import Foundation

/// Opaque witness that only this file can construct (`init` is `fileprivate`). Exists solely to
/// seal `AECMicOutputAttestation` below to this file — see this file's header comment for the
/// full explanation of the technique and what it does and does not guarantee.
struct AECAttestationSeal {
    fileprivate init() {}
}

/// A future AEC integration's output type is expected to conform to this once AEC lands. Every
/// conformance must supply `_seal`, whose type (`AECAttestationSeal`) can only be produced
/// inside THIS file — so, today, nothing outside this file can conform, which is intentional:
/// there is no real AEC output to attest to yet. See this file's header comment.
protocol AECMicOutputAttestation {
    /// The AEC-cleaned mic samples this attestation vouches for.
    var cleanedMicSamples: [Float] { get }
    /// Proof this attestation was constructed with this file's cooperation. Do not attempt to
    /// satisfy this from another file — see this file's header comment for why it cannot work.
    var _seal: AECAttestationSeal { get }
}

/// Float PCM samples that have already passed through AEC (acoustic echo cancellation) —
/// i.e. `neuralAec.processStreamingMic(...)`'s output in the donor, or this fork's equivalent.
/// Construction is restricted to this file (`init` is `fileprivate`) plus the sealed
/// `mint(from:)` entry point below. See this file's header comment and ADAPTER-HANDOVER.md for
/// why this exists and what it does and does not guarantee.
struct AECCleanedMicSamples: Sendable {
    let samples: [Float]

    fileprivate init(_ samples: [Float]) {
        self.samples = samples
    }

    /// The only way to construct `AECCleanedMicSamples` from outside this file. Requires an
    /// `AECMicOutputAttestation`, which nothing outside this file can currently provide — see
    /// this file's header comment for the intended integration shape.
    static func mint(from attestation: AECMicOutputAttestation) -> AECCleanedMicSamples {
        AECCleanedMicSamples(attestation.cleanedMicSamples)
    }
}

#if DEBUG
extension AECCleanedMicSamples {
    /// Test-only escape hatch, since `MeetingVadStreamsTests.swift` legitimately needs to
    /// construct `AECCleanedMicSamples` to test `MicVadStream` without a real AEC output to
    /// attest to. `@testable import` does not unlock `fileprivate`/`private` access — only
    /// `internal` — so this file still has to hand the test target something.
    ///
    /// Named `unsafeUnattestedForTestsOnly`, not `forTesting`, so a reader skimming a diff
    /// cannot mistake this for a legitimate integration path — it hands back samples with NO
    /// attestation that they ever passed through AEC. DO NOT CALL THIS OUTSIDE
    /// `MeetingVadStreamsTests.swift`. Doing so from any other production file under `VoiceInk/`
    /// is caught by `unsafeTestOnlyMintIsNeverUsedInProduction` in that test file — a static scan,
    /// not a compile error (see below for why a compile-time guarantee isn't available here).
    ///
    /// This symbol exists ONLY in `DEBUG` builds (VoiceInk's Debug configuration, which is what
    /// both CI and `VoiceInk Dev.app` build with — `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
    /// includes `DEBUG` there and not in Release). It does not exist at all in a Release build,
    /// so calling it from production glue code would fail Release compilation outright, not
    /// silently ship. It does NOT, however, stop misuse from another file within a Debug build
    /// — including the Debug build the next integrator will actually be developing against —
    /// which is exactly why the static scan above exists as a second layer. See this file's
    /// header "Residual limit" paragraph.
    static func unsafeUnattestedForTestsOnly(_ samples: [Float]) -> AECCleanedMicSamples {
        AECCleanedMicSamples(samples)
    }
}
#endif

/// Float PCM samples read directly from system audio capture, with no AEC cleaning applied.
/// This is deliberately raw — the system VAD stream is meant to see the unmodified system
/// audio (donor `MeetingSession.swift:1251-1262`).
struct RawSystemSamples: Sendable {
    let samples: [Float]

    init(_ samples: [Float]) {
        self.samples = samples
    }
}

/// Thin facade over `StreamingVadController`, scoped to the mic stream. Accepts only
/// `AECCleanedMicSamples` — passing raw mic samples, or the system stream, is a compile error.
final class MicVadStream: @unchecked Sendable {
    private let controller: StreamingVadController

    /// Forwarded from the wrapped controller. See `StreamingVadController.onChunkBoundary`'s
    /// own documentation for delivery-thread guarantees.
    var onChunkBoundary: (() -> Void)? {
        get { controller.onChunkBoundary }
        set { controller.onChunkBoundary = newValue }
    }

    convenience init(vadManager: VadManager) {
        self.init(controller: StreamingVadController(vadManager: vadManager))
    }

    /// Test/adapter-only seam: inject an already-constructed controller (e.g. one built via
    /// `StreamingVadController`'s internal injectable-closures initializer) instead of a real
    /// `VadManager`.
    internal init(controller: StreamingVadController) {
        self.controller = controller
    }

    func start() { controller.start() }
    func stop() { controller.stop() }
    func notifyRotation() { controller.notifyRotation() }

    func process(_ samples: AECCleanedMicSamples) {
        controller.processAudio(samples.samples)
    }
}

/// Thin facade over `StreamingVadController`, scoped to the system stream. Accepts only
/// `RawSystemSamples` — passing AEC-cleaned mic samples, or the mic stream, is a compile error.
final class SystemVadStream: @unchecked Sendable {
    private let controller: StreamingVadController

    var onChunkBoundary: (() -> Void)? {
        get { controller.onChunkBoundary }
        set { controller.onChunkBoundary = newValue }
    }

    convenience init(vadManager: VadManager) {
        self.init(controller: StreamingVadController(vadManager: vadManager))
    }

    internal init(controller: StreamingVadController) {
        self.controller = controller
    }

    func start() { controller.start() }
    func stop() { controller.stop() }
    func notifyRotation() { controller.notifyRotation() }

    func process(_ samples: RawSystemSamples) {
        controller.processAudio(samples.samples)
    }
}

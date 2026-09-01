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
// What this does NOT (and cannot, from this file alone) guarantee: that the samples inside an
// `AECCleanedMicSamples` actually passed through AEC. Nothing in this fork's Meetings slice yet
// owns the AEC boundary (a different Stage-1 cluster does), so `AECCleanedMicSamples.init` is a
// public, unrestricted constructor — a caller could technically wrap raw mic samples in it. That
// is a real, disclosed limit: closing it fully would mean this file also owning (or depending
// on) the AEC module's output type, which is out of scope for this stage. The mitigation is
// documentation plus the type name itself: the ONLY correct place to construct
// `AECCleanedMicSamples` is immediately after the AEC cleaning step, and that is spelled out in
// ADAPTER-HANDOVER.md. A future stage that owns both AEC and this facade could tighten this
// further (e.g. making the initializer `internal` to a shared module, or having the AEC output
// type itself conform to a marker protocol only it can satisfy) — noted there as a follow-up,
// not invented here without owning the pieces it would depend on.

import FluidAudio
import Foundation

/// Float PCM samples that have already passed through AEC (acoustic echo cancellation) —
/// i.e. `neuralAec.processStreamingMic(...)`'s output in the donor, or this fork's equivalent.
/// The ONLY correct construction site is immediately after that cleaning step. See this file's
/// header comment and ADAPTER-HANDOVER.md for why this exists and what it does not guarantee.
struct AECCleanedMicSamples: Sendable {
    let samples: [Float]

    init(_ samples: [Float]) {
        self.samples = samples
    }
}

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

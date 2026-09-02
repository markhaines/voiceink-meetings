// Fork-owned (no donor equivalent). Not a port.
//
// This is the seam `meeting-session-port-plan.md` (Seam 2) and `DECISION-transcription-seam.md`
// describe: `MeetingEngine` depends on this protocol, never on a concrete transcription backend.
// The donor's `TranscriptionCoordinator` is an `actor` with four methods that have no equivalent
// on this fork's `TranscriptionServiceRegistry` (no VAD-manager access, no diarization, no
// segment-bearing chunk transcription, and the registry is `@MainActor` while the meeting
// capture pipeline runs on a plain serial queue) -- so a real coordinator has to be BUILT, not
// adapted from the registry. That build is Stage 2c's job, not this stage's: this file ships
// only the protocol and a no-op stub, `NullMeetingTranscriptionCoordinator`, so `MeetingEngine`
// compiles, runs, and records real audio end-to-end today, with transcription always empty.
// Swapping the stub for Stage 2c's real actor requires no change to `MeetingEngine` itself, only
// to whatever constructs it.

import FluidAudio
import Foundation

/// One backend's transcription of one chunk/file. Fork-local re-declaration of the donor's
/// `SpeechTranscriptionResult` (`TranscriptionRuntime.swift:11-14`) -- same two-field shape, not
/// copied text (the donor type lived in a module this fork does not have), so it carries no MIT
/// attribution header. Consumed by `MicTurnNormalizer`/`SystemTurnNormalizer`.
struct SpeechTranscriptionResult: Sendable {
    let text: String
    let segments: [SpeechSegment]
}

/// The transcription seam `MeetingEngine` is built against.
///
/// Deliberately narrower than the donor's `TranscriptionCoordinator`: the donor signature also
/// threads a `BackendOption` and five per-backend language settings through every transcription
/// call. Both are cut here, not carried forward as unused placeholders -- backend selection has
/// no fork equivalent (`meeting-session-port-plan.md` Seam 1/2) and is a product decision this
/// stage does not make. Stage 2c's real implementation owns backend selection internally and
/// can add parameters to these methods when it lands; that is a protocol this fork owns, not an
/// upstream one, so widening it later is unconstrained.
protocol MeetingTranscriptionCoordinating: Sendable {
    /// The VAD manager driving chunk-boundary rotation, or nil if VAD is unavailable this
    /// session -- donor `TranscriptionCoordinator.getVadManager()`
    /// (`MeetingSession.swift:417`, `:1373`). A nil return matches the donor's own fallback
    /// path: `MeetingEngine.start()` then wires no VAD controller at all, so chunk rotation
    /// happens only at `stop()`, not mid-meeting -- see `MeetingEngine.swift`'s own note next
    /// to where it calls this.
    func getVadManager() async -> VadManager?

    /// Transcribes one already-rotated chunk file -- donor
    /// `transcriptionCoordinator.transcribeMeetingChunk(at:...)`
    /// (`MeetingSession.swift:778`, `:1078`, `:1311`).
    func transcribeMeetingChunk(at url: URL) async throws -> SpeechTranscriptionResult

    /// Transcribes a whole file in one pass -- donor
    /// `transcriptionCoordinator.transcribeMeeting(at:...)` (`MeetingSession.swift:1421`,
    /// `:1456`), used by the final-chunk and full-session-fallback paths. Not called by
    /// anything in this stage's `MeetingEngine`: the system-segment repair pass that calls it
    /// (`repairSystemSegmentsIfNeeded`) is deferred to Stage 2c alongside real backend
    /// transcription -- see `MeetingEngine.swift`'s header. Kept on the protocol regardless so
    /// Stage 2c does not need to widen this seam later.
    func transcribeMeeting(at url: URL) async throws -> SpeechTranscriptionResult

    /// Batch speaker diarization over the full system-audio recording -- donor
    /// `transcriptionCoordinator.diarizeSystemAudio(at:)` (`MeetingSession.swift:809`).
    func diarizeSystemAudio(at url: URL) async throws -> DiarizationResult?
}

/// This stage's implementation of ``MeetingTranscriptionCoordinating``: transcription is
/// stubbed. Every call returns the "nothing to transcribe" answer and never throws -- a stub
/// failing is not itself informative and would just add error-handling noise to
/// `MeetingEngine`'s already-stubbed paths.
struct NullMeetingTranscriptionCoordinator: MeetingTranscriptionCoordinating {
    func getVadManager() async -> VadManager? { nil }

    func transcribeMeetingChunk(at url: URL) async throws -> SpeechTranscriptionResult {
        SpeechTranscriptionResult(text: "", segments: [])
    }

    func transcribeMeeting(at url: URL) async throws -> SpeechTranscriptionResult {
        SpeechTranscriptionResult(text: "", segments: [])
    }

    func diarizeSystemAudio(at url: URL) async throws -> DiarizationResult? { nil }
}

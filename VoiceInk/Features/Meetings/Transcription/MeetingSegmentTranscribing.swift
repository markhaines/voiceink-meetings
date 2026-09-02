// Fork-owned (no donor equivalent). Not a port.
//
// The seam `MeetingTranscriptionCoordinator` routes across -- see
// `DECISION-transcription-seam.md` (Option (ii)): the coordinator calls FluidAudio and
// transcribe-cpp DIRECTLY for genuine per-segment timing where they can supply it, and falls
// back to a flat string + a single zero-duration `SpeechSegment` for every other backend --
// which `MicTurnNormalizer`/`SystemTurnNormalizer` (both ported verbatim, unmodified) already
// treat as "no meaningful timing" and NLTokenizer-sentence-split themselves. Both normalizers
// are the load-bearing logic; nothing here re-implements them.
//
// Backend selection -- which of `.fluidAudio`/`.transcribeCpp`/`.other` a given meeting actually
// runs -- is explicitly NOT decided by this stage. `MeetingTranscriptionCoordinating.swift`'s own
// header says so: "backend selection has no fork equivalent ... and is a product decision this
// stage does not make." It is threaded into `MeetingTranscriptionCoordinator.init` by whoever
// assembles the real coordinator, exactly as `MeetingEngine` itself takes its coordinator via
// constructor injection (defaulting to `NullMeetingTranscriptionCoordinator`).

import FluidAudio
import Foundation

/// A backend that can produce a transcript with genuine per-utterance segment timing for one
/// already-rotated chunk file, as opposed to a flat string. Two production conformers exist in
/// this file tree today: `FluidAudioMeetingSegmentTranscriber` and
/// `TranscribeCppMeetingSegmentTranscriber`. Every other backend (whisper.cpp, native Apple,
/// cloud) has no conformer -- `MeetingTranscriptionCoordinator` degrades to a flat string for
/// them, which is PARITY with the donor's own shipped behavior for those backends, not a
/// compromise (see `segment-timing-design.md` §C).
protocol MeetingSegmentTranscribing: Sendable {
    func transcribe(chunkAt url: URL) async throws -> SpeechTranscriptionResult
}

/// Batch speaker diarization over a whole system-audio recording -- donor
/// `transcriptionCoordinator.diarizeSystemAudio(at:)`. Separate from
/// `MeetingSegmentTranscribing` because diarization runs once, over the entire meeting's
/// system-audio file, not per rotated chunk.
protocol MeetingSystemAudioDiarizing: Sendable {
    func diarize(fileAt url: URL) async throws -> DiarizationResult?
}

/// Which backend is transcribing this meeting. `.other` covers whisper.cpp, native Apple, and
/// every cloud provider -- all of which land on the flat-string + sentence-split path today
/// (see this file's header, and this stage's PR description for exactly which backends are
/// wired to which path).
enum MeetingTranscriptionBackend: Sendable, Equatable {
    case fluidAudio
    case transcribeCpp
    case other
}

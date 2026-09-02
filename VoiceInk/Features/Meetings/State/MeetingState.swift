import Foundation

/// Lifecycle state of a single meeting recording, persisted on `Meeting.stateRawValue`.
///
/// Deliberately NOT `RecordingState` (`VoiceInk/Core/Recording/RecordingState.swift`): that
/// enum is upstream's own dictation/transcription lifecycle (idle/starting/recording/
/// transcribing/enhancing/busy), consumed exhaustively by `VoiceInkEngine` and its UI at every
/// call site upstream already wires. A meeting recording has a different shape entirely — it
/// can be paused mid-meeting (dictation cannot), and "finalizing" (flushing the last
/// incremental segments and closing the audio file) is meaningfully distinct from
/// "transcribing" a whole file after the fact. Folding meeting-only cases into
/// `RecordingState` would mean editing a type six other upstream call sites already switch
/// over exhaustively — exactly the upstream-file edit Stage 2a is scoped to avoid.
enum MeetingState: String, Codable, Sendable {
    /// Actively capturing audio and appending segments.
    case recording
    /// Capture is suspended; no audio is being written, but the meeting is not finished.
    case paused
    /// Recording has stopped; the last segments/audio are being flushed to disk.
    case finalizing
    /// Fully persisted and closed. `Meeting.endDate` is set.
    case completed
    /// Capture ended abnormally (crash recovery, unrecoverable device loss, etc). `endDate`
    /// may or may not be set depending on when the failure was detected.
    case failed
}

import Foundation
import SwiftData

/// Which physical audio stream a segment's text came from. Mirrors the "You" (mic) vs
/// "Others"/"Speaker N" (system, i.e. everyone else on the call) split
/// `TranscriptFormatter.merge` already uses when rendering a transcript
/// (`Features/Meetings/Transcription/TranscriptFormatter.swift`), so a segment's channel maps
/// directly onto that existing display convention instead of introducing a second vocabulary.
enum MeetingSegmentChannel: String, Codable, Sendable {
    case mic
    case system
}

/// One line of a meeting transcript: a speaker turn with its position in the meeting's own
/// timeline. Segments belong to exactly one `Meeting` (see that model's `segments`
/// relationship, which cascades delete onto these).
@Model
final class MeetingSegment {
    var id: UUID = UUID()

    /// Offset, in seconds from `Meeting.startDate`, where this segment begins. Absolute in the
    /// MEETING's timeline, not the mic or system chunk file that produced it — mic and system
    /// audio are captured as separate chunk streams (`PCMChunkRecorder`, one per channel) that
    /// don't share a byte offset, so a segment's position has to be expressed against the one
    /// clock both channels agree on: wall-clock time since the meeting started.
    var startOffset: TimeInterval = 0
    var endOffset: TimeInterval = 0

    /// Display label for who is speaking: "You" for the mic channel, "Speaker 1"/"Speaker 2"/
    /// "Others" for diarized system audio — see `TranscriptFormatter.findSpeaker`. Stored here
    /// rather than re-derived at read time, because diarization is a point-in-time best guess
    /// that should not silently change if the diarizer's labeling logic changes later.
    var speakerLabel: String = ""
    var text: String = ""

    /// Backing storage for `sourceChannel`. A raw `String` column, not the enum directly,
    /// matching this codebase's existing convention for persisted enums
    /// (`Transcription.transcriptionStatus`) so lifecycle/channel filtering stays
    /// predicate-friendly and isolated from any future case-name churn.
    private var sourceChannelRawValue: String = MeetingSegmentChannel.mic.rawValue

    /// Stable sort key for segments that share a `startOffset`. Mic and system audio are
    /// transcribed independently and interleaved after capture, so two segments can legitimately
    /// report the same offset; ties break on this index, not on insertion order, which SwiftData
    /// does not guarantee is preserved across fetches.
    var orderIndex: Int = 0

    /// Inverse of `Meeting.segments`. Optional because SwiftData relationships must be
    /// optional/defaultable on at least one side; a segment is always constructed with a
    /// meeting in practice (see `MeetingSegmentPersistenceActor`).
    var meeting: Meeting?

    var sourceChannel: MeetingSegmentChannel {
        get { MeetingSegmentChannel(rawValue: sourceChannelRawValue) ?? .mic }
        set { sourceChannelRawValue = newValue.rawValue }
    }

    init(
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        speakerLabel: String,
        text: String,
        sourceChannel: MeetingSegmentChannel,
        orderIndex: Int,
        meeting: Meeting? = nil
    ) {
        self.id = UUID()
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.speakerLabel = speakerLabel
        self.text = text
        self.sourceChannelRawValue = sourceChannel.rawValue
        self.orderIndex = orderIndex
        self.meeting = meeting
    }
}

import Foundation
import SwiftData

/// A single recorded meeting: the SwiftData root for everything the (not-yet-written)
/// MeetingEngine will produce during capture, and everything the (not-yet-written)
/// Transcripted-compatible exporter will read afterward.
///
/// The export-facing fields (`actionItems`, `summary`) exist now, ahead of both of those, so
/// this schema doesn't need a migration once they land: they are Stage 2b's meeting-
/// intelligence output and Phase 2's exporter input, but this model only stores whatever it is
/// given — it does not compute or export them itself.
@Model
final class Meeting {
    var id: UUID = UUID()
    var title: String = ""
    var startDate: Date = Date()
    var endDate: Date?

    /// Absolute filesystem path to this meeting's audio directory, a child of
    /// `MeetingRuntimePaths.meetingAudioDirectory()`. Stored as a path string, not a `URL`,
    /// matching `Transcription.audioFileURL`'s existing convention in this codebase.
    var audioDirectoryPath: String = ""

    /// Wall-clock length of the meeting so far. Updated incrementally during recording (see
    /// `MeetingSegmentPersistenceActor.updateDuration`) so a crash mid-meeting still leaves a
    /// usable value, rather than only ever being computed once from `endDate - startDate`.
    var duration: TimeInterval = 0

    /// Backing storage for `state`. A raw `String` column, not the enum directly, matching
    /// this codebase's existing convention for persisted enums
    /// (`Transcription.transcriptionStatus`).
    private var stateRawValue: String = MeetingState.recording.rawValue

    /// Ordered transcript segments. Deleting a `Meeting` deletes every segment belonging to
    /// it — a segment has no meaning once its parent meeting is gone.
    @Relationship(deleteRule: .cascade, inverse: \MeetingSegment.meeting)
    var segments: [MeetingSegment] = []

    // MARK: - Transcripted-compatible export fields (populated by Stage 2b+, not here)

    /// Action items extracted from the transcript. Empty until a later meeting-intelligence
    /// pass runs.
    var actionItems: [String] = []
    /// Free-text meeting summary. `nil` until a later meeting-intelligence pass populates it.
    var summary: String?

    var state: MeetingState {
        get { MeetingState(rawValue: stateRawValue) ?? .failed }
        set { stateRawValue = newValue.rawValue }
    }

    init(
        title: String,
        startDate: Date = Date(),
        audioDirectoryPath: String,
        state: MeetingState = .recording
    ) {
        self.id = UUID()
        self.title = title
        self.startDate = startDate
        self.audioDirectoryPath = audioDirectoryPath
        self.stateRawValue = state.rawValue
    }
}

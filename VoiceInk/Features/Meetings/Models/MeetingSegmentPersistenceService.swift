import Foundation
import SwiftData

/// Appends `MeetingSegment`s to a `Meeting` one at a time, saving after each write, so a
/// crash at minute 70 of a meeting loses at most the segment in flight — never the meeting,
/// and never anything already transcribed.
///
/// # Contract for the (not-yet-written) MeetingEngine
///
/// This service defines the persistence contract now, even though nothing calls it yet, so
/// the engine that eventually drives capture has a fixed, already-tested surface to write
/// against rather than inventing its own save discipline.
///
/// - Call ``startMeeting(title:audioDirectoryPath:startDate:)`` exactly once, at meeting
///   start. It creates and saves a `Meeting` in `.recording` state immediately — before a
///   single second of audio has been transcribed — so `meeting.id` exists for the engine to
///   reference from the moment capture begins.
/// - Call ``appendSegment(startOffset:endOffset:speakerLabel:text:sourceChannel:to:)`` as each
///   *finalized* transcript segment becomes available: after VAD + ASR + reconciliation have
///   produced a settled turn, never for interim/partial ASR results. Each call performs
///   exactly one `ModelContext.save()`. The engine must not batch or buffer segments itself —
///   batching here would reintroduce the "lose the last N minutes" failure mode this service
///   exists to remove.
/// - Call ``updateDuration(_:for:)`` periodically (e.g. once per audio chunk) so
///   `Meeting.duration` reflects reality even if the meeting is never cleanly finished.
/// - Call ``finish(_:endDate:)`` exactly once, at meeting end, to set `endDate`, fix
///   `duration` to the exact elapsed time, and move `state` to `.completed`.
/// - Call ``markFailed(_:)`` only for an in-process error the engine can detect and react to
///   (e.g. an unrecoverable device-loss error). It is not a substitute for crash recovery: if
///   the app crashes outright, no code runs to call this at all, and the `Meeting` is simply
///   left in whatever state (`.recording`/`.paused`) its last successful save left it in, with
///   every segment received up to that point intact. Deciding what a still-`.recording`
///   meeting found on next launch means (resume, mark `.failed`, ask the user) is the
///   MeetingEngine's job, not this service's — this service only guarantees the data is there
///   to make that decision from.
///
/// All methods run synchronously on the given `ModelContext`. `ModelContext` is not
/// `Sendable`; a caller on a different actor/executor must hop to the context's own actor
/// before calling in. This service holds no state of its own — every method reads and writes
/// only through `context` — so it is cheap to construct fresh per call or keep as a
/// long-lived value.
struct MeetingSegmentPersistenceService {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Creates and persists a new `Meeting` in `.recording` state.
    @discardableResult
    func startMeeting(
        title: String,
        audioDirectoryPath: String,
        startDate: Date = Date()
    ) throws -> Meeting {
        let meeting = Meeting(title: title, startDate: startDate, audioDirectoryPath: audioDirectoryPath)
        context.insert(meeting)
        try context.save()
        return meeting
    }

    /// Appends one finalized segment to `meeting` and saves immediately.
    ///
    /// `orderIndex` is assigned automatically from `meeting.segments.count`, so callers append
    /// in the order segments should read back in; it exists purely as a tiebreaker for
    /// segments that share a `startOffset` (see `MeetingSegment.orderIndex`), not as something
    /// callers need to manage themselves.
    @discardableResult
    func appendSegment(
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        speakerLabel: String,
        text: String,
        sourceChannel: MeetingSegmentChannel,
        to meeting: Meeting
    ) throws -> MeetingSegment {
        let segment = MeetingSegment(
            startOffset: startOffset,
            endOffset: endOffset,
            speakerLabel: speakerLabel,
            text: text,
            sourceChannel: sourceChannel,
            orderIndex: meeting.segments.count,
            meeting: meeting
        )
        context.insert(segment)
        try context.save()
        return segment
    }

    /// Updates `meeting.duration` and saves. Call periodically during recording so the stored
    /// duration stays close to real elapsed time even if `finish` is never reached.
    func updateDuration(_ duration: TimeInterval, for meeting: Meeting) throws {
        meeting.duration = duration
        try context.save()
    }

    /// Marks `meeting` `.paused` or `.recording` (whichever the engine reports) and saves.
    /// Exists so pause/resume is a persisted fact, not just in-memory engine state — a crash
    /// while paused should be recoverable as "was paused," not indistinguishable from a crash
    /// mid-recording.
    func updateState(_ state: MeetingState, for meeting: Meeting) throws {
        meeting.state = state
        try context.save()
    }

    /// Closes out `meeting`: sets `endDate`, recomputes `duration` from `startDate`/`endDate`
    /// exactly (rather than trusting the last `updateDuration` call), and moves `state` to
    /// `.completed`.
    func finish(_ meeting: Meeting, endDate: Date = Date()) throws {
        meeting.endDate = endDate
        meeting.duration = endDate.timeIntervalSince(meeting.startDate)
        meeting.state = .completed
        try context.save()
    }

    /// Marks `meeting` `.failed` and saves. See the type-level doc comment: this only covers
    /// an in-process error the caller can detect, not a hard crash.
    func markFailed(_ meeting: Meeting) throws {
        meeting.state = .failed
        try context.save()
    }
}

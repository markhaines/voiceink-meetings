import Foundation
import SwiftData

/// Appends `MeetingSegment`s to a `Meeting` one at a time, saving after each write, so a
/// crash at minute 70 of a meeting loses at most the segment in flight — never the meeting,
/// and never anything already transcribed.
///
/// # Contract for the (not-yet-written) MeetingEngine
///
/// This actor defines the persistence contract now, even though nothing calls it yet, so the
/// engine that eventually drives capture has a fixed, already-tested surface to write against
/// rather than inventing its own save discipline.
///
/// - Call ``startMeeting(title:audioDirectoryPath:startDate:)`` exactly once, at meeting
///   start. It creates and saves a `Meeting` in `.recording` state immediately — before a
///   single second of audio has been transcribed — and returns its `PersistentIdentifier` for
///   the engine to reference from the moment capture begins.
/// - Call ``appendSegment(startOffset:endOffset:speakerLabel:text:sourceChannel:to:)`` as each
///   *finalized* transcript segment becomes available: after VAD + ASR + reconciliation have
///   produced a settled turn, never for interim/partial ASR results. Each call performs
///   exactly one `ModelContext.save()`. The engine must not batch or buffer segments itself —
///   batching here would reintroduce the "lose the last N minutes" failure mode this actor
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
///   MeetingEngine's job, not this actor's — this actor only guarantees the data is there to
///   make that decision from.
///
/// # Concurrency
///
/// This type is a `@ModelActor`: SwiftData's purpose-built tool for driving a `ModelContext`
/// safely from outside the main actor
/// (<https://developer.apple.com/documentation/swiftdata/modelactor>). The macro synthesizes
/// its own `ModelContext`, bound to its own serial executor, from the `ModelContainer` passed
/// to the generated `init(modelContainer:)` — this type is never handed someone else's
/// context. Construct exactly one instance per `ModelContainer` and share it (an actor's
/// methods already serialize against each other; there is no benefit to more than one), and
/// call every method with `await` from the meeting capture pipeline's serial audio queue (or
/// anywhere else) — the actor's own serial executor is what makes that safe, not which queue
/// the caller happens to run on.
///
/// **The property this structurally guarantees, and how.** No managed `Meeting` or
/// `MeetingSegment` object — neither conforms to `Sendable`; both are reference types tied to
/// whichever `ModelContext` created them — ever crosses this actor's boundary. Every method
/// below takes and returns `PersistentIdentifier` (a `Sendable`, `Hashable`, `Codable` value
/// type) instead of a managed object. This is not a rule callers have to remember: a call
/// site that tries to pass a managed `Meeting` where a `PersistentIdentifier` is expected gets
/// a type-mismatch compile error, and a call site that forgets `await` on an actor-isolated
/// method gets an actor-isolation compile error — both unconditional language rules, not
/// gated behind a strict-concurrency build setting. Verified by deliberately writing both
/// violations against this file and capturing the verbatim compiler output; see
/// `FORK-PATCHES.md`'s Stage 2a fix-round entry for the transcript.
///
/// **No residual hole found, and this was checked rather than assumed.** Some older SwiftData
/// write-ups describe `ModelActor.modelContext` as `nonisolated`, which would let any caller
/// reach `actor.modelContext.insert(...)` synchronously and bypass every guarantee above. That
/// is NOT true of this SDK: `SwiftData.swiftinterface` (Xcode 26.6, macOS SDK) declares
/// `extension ModelActor { public var modelContext: ModelContext { get } }` with no
/// `nonisolated` modifier, which makes it actor-isolated by default — and attack 3 in the
/// verbatim compiler transcript below proves it: reaching `actor.modelContext` from a
/// non-isolated function is a compile error on this toolchain, the same as calling any other
/// method on this actor without `await`. Every cross-boundary path this file's public API
/// exposes — and, on this SDK, the inherited `modelContext` property too — is compiler-checked,
/// not merely documented.
@ModelActor
actor MeetingSegmentPersistenceActor {
    enum PersistenceError: Error, Sendable {
        case meetingNotFound(PersistentIdentifier)
    }

    /// Creates and persists a new `Meeting` in `.recording` state, returning its identifier.
    @discardableResult
    func startMeeting(
        title: String,
        audioDirectoryPath: String,
        startDate: Date = Date()
    ) throws -> PersistentIdentifier {
        let meeting = Meeting(title: title, startDate: startDate, audioDirectoryPath: audioDirectoryPath)
        modelContext.insert(meeting)
        try modelContext.save()
        return meeting.persistentModelID
    }

    /// Appends one finalized segment to the meeting identified by `meetingID` and saves
    /// immediately, returning the new segment's identifier.
    ///
    /// `orderIndex` is assigned automatically from the meeting's current segment count, so
    /// callers append in the order segments should read back in; it exists purely as a
    /// tiebreaker for segments that share a `startOffset` (see `MeetingSegment.orderIndex`),
    /// not as something callers need to manage themselves.
    @discardableResult
    func appendSegment(
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        speakerLabel: String,
        text: String,
        sourceChannel: MeetingSegmentChannel,
        to meetingID: PersistentIdentifier
    ) throws -> PersistentIdentifier {
        let meeting = try meeting(for: meetingID)
        let segment = MeetingSegment(
            startOffset: startOffset,
            endOffset: endOffset,
            speakerLabel: speakerLabel,
            text: text,
            sourceChannel: sourceChannel,
            orderIndex: meeting.segments.count,
            meeting: meeting
        )
        modelContext.insert(segment)
        try modelContext.save()
        return segment.persistentModelID
    }

    /// Updates the meeting's `duration` and saves. Call periodically during recording so the
    /// stored duration stays close to real elapsed time even if `finish` is never reached.
    func updateDuration(_ duration: TimeInterval, for meetingID: PersistentIdentifier) throws {
        let meeting = try meeting(for: meetingID)
        meeting.duration = duration
        try modelContext.save()
    }

    /// Sets the meeting's `state` (e.g. `.paused`/`.recording`) and saves. Exists so pause/
    /// resume is a persisted fact, not just in-memory engine state — a crash while paused
    /// should be recoverable as "was paused," not indistinguishable from a crash mid-recording.
    func updateState(_ state: MeetingState, for meetingID: PersistentIdentifier) throws {
        let meeting = try meeting(for: meetingID)
        meeting.state = state
        try modelContext.save()
    }

    /// Closes out the meeting: sets `endDate`, recomputes `duration` from `startDate`/
    /// `endDate` exactly (rather than trusting the last `updateDuration` call), and moves
    /// `state` to `.completed`.
    func finish(_ meetingID: PersistentIdentifier, endDate: Date = Date()) throws {
        let meeting = try meeting(for: meetingID)
        meeting.endDate = endDate
        meeting.duration = endDate.timeIntervalSince(meeting.startDate)
        meeting.state = .completed
        try modelContext.save()
    }

    /// Marks the meeting `.failed` and saves. See the type-level doc comment: this only
    /// covers an in-process error the caller can detect, not a hard crash.
    func markFailed(_ meetingID: PersistentIdentifier) throws {
        let meeting = try meeting(for: meetingID)
        meeting.state = .failed
        try modelContext.save()
    }

    /// Resolves `id` to a `Meeting`, without ever risking the crashes SwiftData's own
    /// identifier-lookup APIs have for an identifier this store doesn't recognize.
    ///
    /// Two APIs on this SDK LOOK like safe, recoverable "not found" checks and are NOT, both
    /// verified empirically against a deliberately foreign `PersistentIdentifier` (one from a
    /// completely different `ModelContainer`) — see `FORK-PATCHES.md`'s Stage 2a fix-round
    /// entry for both exact crash logs:
    ///
    /// - `ModelContext.model(for:)` returns a plain `any PersistentModel`, no `Optional` — a
    ///   cast off it (`as? Meeting`) looks like a normal nil-on-miss check. Touching the
    ///   result instead crashes the process outright: `Fatal error: This model instance was
    ///   invalidated because its backing data could no longer be found the store`
    ///   (`SwiftData/BackingData.swift:1057`).
    /// - `ModelActor`'s own built-in `self[id, as: Meeting.self]` subscript — the framework's
    ///   purpose-built, `Optional`-returning lookup for exactly this situation — does NOT
    ///   return `nil` for a foreign identifier either. It hands back a non-nil but invalid
    ///   `Meeting`, so this method's `guard let` would pass and only the LATER property
    ///   mutation traps: a real crash caught only by running this actor's own tests, symbolicated
    ///   to `Meeting.duration.setter` → SwiftData's `Observation` machinery → `_assertionFailure`
    ///   (`~/Library/Logs/DiagnosticReports/VoiceInk Dev-*.ips`, `EXC_BREAKPOINT`/`SIGTRAP`).
    ///   This is a worse failure mode than `model(for:)`'s, not a better one: it defers the
    ///   crash past the "did I find it" check into whatever mutation happens to run next.
    ///
    /// The safe path: `registeredModel(for:)` is a pure in-memory lookup with no store access
    /// at all (this actor's own context always has a `Meeting` registered the moment
    /// `startMeeting` creates it, so every legitimate call in a single actor's lifetime hits
    /// this branch). Falling back to a `FetchDescriptor` predicate query for an identifier
    /// this context hasn't seen yet (e.g. a fresh actor resolving a meeting that was persisted
    /// in an earlier process) is a real, targeted store query — an absent row is an empty
    /// result, not a fault to materialize, so it degrades to "not found" instead of crashing.
    /// This is the only one of the three approaches that survived being tested against a
    /// foreign identifier.
    private func meeting(for id: PersistentIdentifier) throws -> Meeting {
        if let registered: Meeting = modelContext.registeredModel(for: id) {
            return registered
        }
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        guard let meeting = try modelContext.fetch(descriptor).first else {
            throw PersistenceError.meetingNotFound(id)
        }
        return meeting
    }
}

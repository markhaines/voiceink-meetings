import Foundation
import SwiftData

/// Opaque receipt for a `Meeting` this store has persisted.
///
/// Handed back by ``MeetingStore/startMeeting(title:audioDirectoryPath:startDate:)`` and passed
/// to every later call about that meeting. It is a `Sendable` value type, so it can cross any
/// isolation boundary freely — which a managed `Meeting` cannot.
///
/// The `PersistentIdentifier` inside is `fileprivate` on purpose: in checked code, a caller
/// cannot unwrap a handle and feed the identifier to `ModelContext.model(for:)`, which is not
/// the recoverable "not found" check it looks like — it fatal-errors the process for an
/// identifier the store does not recognise (see ``MeetingStore`` and `FORK-PATCHES.md`). This
/// is an ergonomic guard against a known landmine, **not** a capability boundary: see
/// "Residual holes" on ``MeetingStore`` for what reflection can still recover, and why that
/// recovers no authority a caller holding the `ModelContainer` did not already have.
struct MeetingHandle: Hashable, Sendable {
    fileprivate let persistentID: PersistentIdentifier

    fileprivate init(_ persistentID: PersistentIdentifier) {
        self.persistentID = persistentID
    }
}

/// Opaque receipt for one persisted `MeetingSegment`. See ``MeetingHandle``.
struct MeetingSegmentHandle: Hashable, Sendable {
    fileprivate let persistentID: PersistentIdentifier

    fileprivate init(_ persistentID: PersistentIdentifier) {
        self.persistentID = persistentID
    }
}

enum MeetingStoreError: Error, Sendable {
    /// The handle does not name a meeting this store can resolve — either it came from a
    /// different store, or the row is gone. Thrown, never trapped; see ``MeetingStore``.
    case meetingNotFound(MeetingHandle)
}

// MARK: - MeetingStore

/// Appends `MeetingSegment`s to a `Meeting` one at a time, saving after each write, so a
/// crash at minute 70 of a meeting loses at most the segment in flight — never the meeting,
/// and never anything already transcribed.
///
/// # Contract for the (not-yet-written) MeetingEngine
///
/// This type defines the persistence contract now, even though nothing calls it yet, so the
/// engine that eventually drives capture has a fixed, already-tested surface to write against
/// rather than inventing its own save discipline.
///
/// - Call ``startMeeting(title:audioDirectoryPath:startDate:)`` exactly once, at meeting
///   start. It creates and saves a `Meeting` in `.recording` state immediately — before a
///   single second of audio has been transcribed — and returns a ``MeetingHandle`` for the
///   engine to reference from the moment capture begins.
/// - Call ``appendSegment(startOffset:endOffset:speakerLabel:text:sourceChannel:to:)`` as each
///   *finalized* transcript segment becomes available: after VAD + ASR + reconciliation have
///   produced a settled turn, never for interim/partial ASR results. Each call performs
///   exactly one `ModelContext.save()`. The engine must not batch or buffer segments itself —
///   batching here would reintroduce the "lose the last N minutes" failure mode this type
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
///   MeetingEngine's job, not this type's — this type only guarantees the data is there to
///   make that decision from.
///
/// Construct exactly one instance per `ModelContainer` and share it; every call is `async` and
/// runs on one serial executor, so there is no benefit to more than one. Calls are safe from
/// the meeting capture pipeline's serial audio queue, or anywhere else, because of that
/// executor — not because of which queue the caller happens to run on.
///
/// # The property this structurally guarantees
///
/// > **G.** The `ModelContext` this component mutates, and every managed `Meeting` /
/// > `MeetingSegment` registered in it, are unreachable from any code outside this file. No
/// > expression written elsewhere — using the language's *checked* features, i.e. anything
/// > short of `unsafeBitCast`/raw-memory forgery — yields that context, an object from it, or
/// > the actor that owns it. Every mutation of a meeting's persisted graph therefore happens
/// > on one serial executor, in call order, with one explicit `save()` per mutation.
///
/// Note the scope carefully. **G** is about *this component's* context. It does not, and
/// cannot, claim that the underlying store is single-writer: anyone holding the
/// `ModelContainer` can make their own `ModelContext` and read or write the same rows, which
/// is SwiftData's own supported model (contexts are independent; conflicts resolve at save).
/// What **G** rules out is the far nastier failure — a second isolation domain mutating the
/// objects *this* serial executor owns, which is a data race on non-`Sendable` reference types
/// rather than an ordinary write conflict.
///
/// Four independent mechanisms enforce **G**, each closing a route that the previous design
/// left open:
///
/// 1. **No `ModelActor` conformance anywhere on the exposed type — or on the engine.** This is
///    the fix for the defect that killed the previous two attempts. `ModelActor` declares
///    `nonisolated var modelExecutor: any ModelExecutor`, and `ModelExecutor` declares a
///    non-isolated `var modelContext: ModelContext`. Both are public protocol requirements, so
///    *any* conformer hands its live context to any caller, synchronously, via
///    `someActor.modelExecutor.modelContext` — and because the route is a protocol requirement
///    it is reachable generically (`func attack<A: ModelActor>(_ a: A)`), without naming the
///    conforming type at all. Marking the convenience `modelContext` property isolated does not
///    help; the inherited requirement is a separate door. So this file does not use
///    `@ModelActor`. ``MeetingPersistenceEngine`` hand-rolls exactly what that macro provides —
///    a `ModelContext` bound to a `DefaultSerialModelExecutor` that is also the actor's own
///    `unownedExecutor` — and conforms to nothing. There is no `modelExecutor` requirement to
///    reach through because the conformance that declares it does not exist.
/// 2. **The engine type is file-scoped.** `MeetingPersistenceEngine` is `private` at file
///    scope, so no code elsewhere can name it, declare a variable of it, extend it, or
///    instantiate one.
/// 3. **`MeetingStore` is a `struct`.** `ModelActor` refines `Actor`, which only a `class` or
///    `actor` can conform to, so `extension MeetingStore: ModelActor {}` is not merely
///    unwritten — it is unwritable. A retroactive conformance cannot put the leak back.
/// 4. **The engine is held only as a closure capture, never as a stored property.** A stored
///    property is reachable with `Mirror`, which needs no access to `private` and no compiler
///    permission: `Mirror(reflecting: store).children` would hand out the engine as `Any`, and
///    from there `as? DefaultSerialModelExecutor` (a *public* class with a public
///    `modelContext`) recovers the context at runtime. `Mirror` reports no children for a
///    closure and there is no API that reads a closure's captures, so routing every call
///    through ``EngineDispatch`` closes that route. This is proved at runtime, not asserted:
///    see `MeetingStoreIsolationTests.swift`.
///
/// Mechanisms 1-3 are compile-time; every attack against them is a committed negative control
/// in `scripts/negative-controls/`, run by `scripts/verify-meeting-store-isolation.sh`, which
/// fails if any of them ever starts compiling. Mechanism 4 is a runtime property with a
/// committed runtime test.
///
/// # Residual holes, stated plainly
///
/// - **Raw-memory forgery.** `unsafeBitCast`, `withMemoryRebound`, and friends can defeat any
///   Swift boundary; this one is no exception. The closure indirection does raise the cost from
///   a one-line cast to reconstructing an undocumented closure-context layout, but it is not a
///   defence and is not claimed as one. **G** is explicitly scoped to checked code.
/// - **`Mirror` on a ``MeetingHandle``** recovers the `PersistentIdentifier` inside it, despite
///   the field being `fileprivate`. That yields no authority: a `PersistentIdentifier` is only
///   useful with a `ModelContext`, and anyone able to make one already has
///   `fetch(FetchDescriptor<Meeting>())` over the same rows. It does not reach *this
///   component's* context, so **G** is unaffected. The `fileprivate` is there to keep ordinary
///   checked code away from `ModelContext.model(for:)`, not to hide a secret.
/// - **The `ModelContainer` is not a secret.** It is passed in by the caller, who therefore
///   still has it. See the scoping note on **G** above.
struct MeetingStore: Sendable {
    private let dispatch: EngineDispatch

    init(modelContainer: ModelContainer) {
        let engine = MeetingPersistenceEngine(modelContainer: modelContainer)
        // Every closure below captures `engine`. Deliberately no `let engine` stored property:
        // see mechanism 4 in this type's doc comment.
        dispatch = EngineDispatch(
            start: { title, audioDirectoryPath, startDate in
                try await engine.startMeeting(
                    title: title, audioDirectoryPath: audioDirectoryPath, startDate: startDate)
            },
            appendSegment: { draft, handle in
                try await engine.appendSegment(draft, to: handle)
            },
            updateDuration: { duration, handle in
                try await engine.updateDuration(duration, for: handle)
            },
            updateState: { state, handle in
                try await engine.updateState(state, for: handle)
            },
            finish: { handle, endDate in
                try await engine.finish(handle, endDate: endDate)
            },
            markFailed: { handle in
                try await engine.markFailed(handle)
            }
        )
    }

    /// Creates and persists a new `Meeting` in `.recording` state, returning its handle.
    @discardableResult
    func startMeeting(
        title: String,
        audioDirectoryPath: String,
        startDate: Date = Date()
    ) async throws -> MeetingHandle {
        try await dispatch.start(title, audioDirectoryPath, startDate)
    }

    /// Appends one finalized segment to the meeting named by `meeting` and saves immediately,
    /// returning the new segment's handle.
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
        to meeting: MeetingHandle
    ) async throws -> MeetingSegmentHandle {
        let draft = MeetingSegmentDraft(
            startOffset: startOffset,
            endOffset: endOffset,
            speakerLabel: speakerLabel,
            text: text,
            sourceChannel: sourceChannel
        )
        return try await dispatch.appendSegment(draft, meeting)
    }

    /// Updates the meeting's `duration` and saves. Call periodically during recording so the
    /// stored duration stays close to real elapsed time even if `finish` is never reached.
    func updateDuration(_ duration: TimeInterval, for meeting: MeetingHandle) async throws {
        try await dispatch.updateDuration(duration, meeting)
    }

    /// Sets the meeting's `state` (e.g. `.paused`/`.recording`) and saves. Exists so pause/
    /// resume is a persisted fact, not just in-memory engine state — a crash while paused
    /// should be recoverable as "was paused," not indistinguishable from a crash mid-recording.
    func updateState(_ state: MeetingState, for meeting: MeetingHandle) async throws {
        try await dispatch.updateState(state, meeting)
    }

    /// Closes out the meeting: sets `endDate`, recomputes `duration` from `startDate`/
    /// `endDate` exactly (rather than trusting the last `updateDuration` call), and moves
    /// `state` to `.completed`.
    func finish(_ meeting: MeetingHandle, endDate: Date = Date()) async throws {
        try await dispatch.finish(meeting, endDate)
    }

    /// Marks the meeting `.failed` and saves. See the type-level doc comment: this only
    /// covers an in-process error the caller can detect, not a hard crash.
    func markFailed(_ meeting: MeetingHandle) async throws {
        try await dispatch.markFailed(meeting)
    }
}

// MARK: - File-private implementation

/// The parameters of one `appendSegment` call, bundled so ``EngineDispatch`` stays readable.
private struct MeetingSegmentDraft: Sendable {
    let startOffset: TimeInterval
    let endOffset: TimeInterval
    let speakerLabel: String
    let text: String
    let sourceChannel: MeetingSegmentChannel
}

/// ``MeetingStore``'s entire link to its persistence engine: one `@Sendable` closure per
/// operation, each capturing the engine.
///
/// This exists solely so the engine is a closure capture rather than a stored property — the
/// difference between "unreachable" and "one `Mirror` hop away." See mechanism 4 in
/// ``MeetingStore``'s doc comment, and the runtime proof in `MeetingStoreIsolationTests.swift`.
private struct EngineDispatch: Sendable {
    let start: @Sendable (String, String, Date) async throws -> MeetingHandle
    let appendSegment: @Sendable (MeetingSegmentDraft, MeetingHandle) async throws -> MeetingSegmentHandle
    let updateDuration: @Sendable (TimeInterval, MeetingHandle) async throws -> Void
    let updateState: @Sendable (MeetingState, MeetingHandle) async throws -> Void
    let finish: @Sendable (MeetingHandle, Date) async throws -> Void
    let markFailed: @Sendable (MeetingHandle) async throws -> Void
}

/// The actor that actually owns the `ModelContext`.
///
/// **Deliberately not `@ModelActor`, and deliberately conforming to nothing.** The macro's only
/// substantive output is the three lines of `init` below plus a `ModelActor` conformance — and
/// that conformance is the leak this whole file is built to remove (mechanism 1 in
/// ``MeetingStore``'s doc comment). Everything the macro gives that this component actually
/// needs, it gives itself:
///
/// - a `ModelContext` created from the container, never handed in from outside;
/// - a `DefaultSerialModelExecutor` over that context, installed as this actor's own
///   `unownedExecutor`, so actor-isolated code here runs on the context's executor — the exact
///   arrangement `@ModelActor` synthesises;
/// - `private` file scope, so the type is not nameable, extendable or instantiable elsewhere.
///
/// What it does *not* inherit is `modelExecutor` (a `nonisolated` public requirement that hands
/// the context to any caller) and the `self[id, as:]` subscript (which returns a non-nil but
/// invalid object for a foreign identifier — see ``meeting(for:)``). Losing both is the point.
private actor MeetingPersistenceEngine {
    private let executor: DefaultSerialModelExecutor

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    private var modelContext: ModelContext { executor.modelContext }

    init(modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        // Autosave OFF, unconditionally. This component's whole contract is one explicit
        // `save()` per mutation; leaving autosave on would let SwiftData flush at moments
        // nothing here chose, which (a) makes the durability guarantee depend on a timer
        // rather than on this code, and (b) would let a future edit delete an explicit
        // `save()` without any test noticing. With it off, removing a `save()` fails
        // `MeetingStoreDurabilityTests` immediately — verified by doing exactly that; see
        // `FORK-PATCHES.md`.
        context.autosaveEnabled = false
        executor = DefaultSerialModelExecutor(modelContext: context)
    }

    @discardableResult
    func startMeeting(
        title: String,
        audioDirectoryPath: String,
        startDate: Date
    ) throws -> MeetingHandle {
        let meeting = Meeting(title: title, startDate: startDate, audioDirectoryPath: audioDirectoryPath)
        modelContext.insert(meeting)
        try modelContext.save()
        return MeetingHandle(meeting.persistentModelID)
    }

    @discardableResult
    func appendSegment(
        _ draft: MeetingSegmentDraft,
        to handle: MeetingHandle
    ) throws -> MeetingSegmentHandle {
        let meeting = try meeting(for: handle)
        let segment = MeetingSegment(
            startOffset: draft.startOffset,
            endOffset: draft.endOffset,
            speakerLabel: draft.speakerLabel,
            text: draft.text,
            sourceChannel: draft.sourceChannel,
            orderIndex: meeting.segments.count,
            meeting: meeting
        )
        modelContext.insert(segment)
        try modelContext.save()
        return MeetingSegmentHandle(segment.persistentModelID)
    }

    func updateDuration(_ duration: TimeInterval, for handle: MeetingHandle) throws {
        let meeting = try meeting(for: handle)
        meeting.duration = duration
        try modelContext.save()
    }

    func updateState(_ state: MeetingState, for handle: MeetingHandle) throws {
        let meeting = try meeting(for: handle)
        meeting.state = state
        try modelContext.save()
    }

    func finish(_ handle: MeetingHandle, endDate: Date) throws {
        let meeting = try meeting(for: handle)
        meeting.endDate = endDate
        meeting.duration = endDate.timeIntervalSince(meeting.startDate)
        meeting.state = .completed
        try modelContext.save()
    }

    func markFailed(_ handle: MeetingHandle) throws {
        let meeting = try meeting(for: handle)
        meeting.state = .failed
        try modelContext.save()
    }

    /// Resolves `handle` to a `Meeting`, without ever risking the crashes SwiftData's own
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
    ///   `Meeting`, so a `guard let` around it passes and only the LATER property mutation
    ///   traps: a real crash caught only by running this component's own tests, symbolicated
    ///   to `Meeting.duration.setter` → SwiftData's `Observation` machinery →
    ///   `_assertionFailure` (`~/Library/Logs/DiagnosticReports/VoiceInk Dev-*.ips`,
    ///   `EXC_BREAKPOINT`/`SIGTRAP`). This is a worse failure mode than `model(for:)`'s, not a
    ///   better one: it defers the crash past the "did I find it" check into whatever mutation
    ///   happens to run next. Dropping the `ModelActor` conformance removes that subscript from
    ///   this type entirely, so it cannot be reached for by mistake later.
    ///
    /// The safe path: `registeredModel(for:)` is a pure in-memory lookup with no store access
    /// at all (this engine's own context always has a `Meeting` registered the moment
    /// `startMeeting` creates it, so every legitimate call in a single engine's lifetime hits
    /// this branch). Falling back to a `FetchDescriptor` predicate query for an identifier
    /// this context hasn't seen yet (e.g. a fresh engine resolving a meeting that was persisted
    /// in an earlier process) is a real, targeted store query — an absent row is an empty
    /// result, not a fault to materialize, so it degrades to "not found" instead of crashing.
    /// This is the only one of the three approaches that survived being tested against a
    /// foreign identifier.
    private func meeting(for handle: MeetingHandle) throws -> Meeting {
        let id = handle.persistentID
        if let registered: Meeting = modelContext.registeredModel(for: id) {
            return registered
        }
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        guard let meeting = try modelContext.fetch(descriptor).first else {
            throw MeetingStoreError.meetingNotFound(handle)
        }
        return meeting
    }
}

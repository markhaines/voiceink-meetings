// Partly ported from Muesli-HQ/muesli
// (native/MuesliNative/Tests/MuesliTests/MeetingSessionTitleTests.swift), partly new for this
// fork's own additions (MeetingStore persistence wiring, which the donor never had).
//
// `MeetingProcessingStageTests` and `MeetingEngineRecoveryPolicyTests` below port the
// `MeetingProcessingStage`/`shouldAttemptSystemRecovery` fixtures verbatim (renamed target from
// `MeetingSession` to `MeetingEngine`). NOT ported from `MeetingSessionTitleTests.swift`:
// `DictationStartAdmissionPolicy`/`MeetingProcessingAdmissionPolicy` tests (those types belong
// to VoiceInkEngine's own dictation-admission logic, never touched by this port, and are not
// declared anywhere in this file or its donor source) and `MeetingSessionTitleTests`'
// `calendarTitleCandidate` tests (title generation is cut this stage -- see MeetingEngine.swift's
// header).
//
// `MeetingEngineTests` is new: it exercises MeetingEngine's actual lifecycle (start/pause/
// resume/discard/stop) against fake mic/system-audio recorders and a fake transcription
// coordinator, backed by a real in-memory MeetingStore, so the crash-safety persistence wiring
// this stage adds is verified against real code, not just reasoned about in comments.
//
// One deliberate coverage gap, disclosed rather than silently accepted: VAD-driven MID-MEETING
// chunk rotation (`MicVadStream`/`SystemVadStream`'s `onChunkBoundary` firing automatically) is
// exercised by construction only here, not by a running test. `VadManager` is a real
// FluidAudio model-backed type with no lightweight test double in this fork --
// `StreamingVadControllerTests.swift` itself only tests below the VadManager layer, via
// `StreamingVadController`'s injectable-closures internal init, and `MicVadStream`/
// `SystemVadStream`'s public initializers only accept a real `VadManager`. This mirrors an
// existing test boundary in this fork, not a gap this port introduced. What IS covered here
// instead: `pause()` calls `rotateChunkOnQueue()`/`rotateSystemChunkOnQueue()` directly,
// regardless of whether a VAD facade exists (donor behavior, ported verbatim), which gives a
// real mid-meeting chunk-rotation-and-persist path to test without a VadManager.
//
// MIT License
//
// Copyright (c) 2026 Pranav Hari
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// See NOTICE for full attribution.

import CoreAudio
import FluidAudio
import Foundation
import SwiftData
import Testing

@testable import VoiceInk

@Suite("Meeting processing stage")
struct MeetingProcessingStageTests {
    @Test("audio processing keeps dictation blocked")
    func audioProcessingBlocksDictation() {
        #expect(!MeetingProcessingStage.transcribingAudio.allowsDictation)
        #expect(!MeetingProcessingStage.cleaningAudio.allowsDictation)
    }

    @Test("post-transcription processing allows dictation")
    func postTranscriptionAllowsDictation() {
        #expect(MeetingProcessingStage.generatingTitle.allowsDictation)
        #expect(MeetingProcessingStage.summarizingNotes.allowsDictation)
    }
}

@Suite("MeetingEngine recovery policy")
struct MeetingEngineRecoveryPolicyTests {
    @Test("Nemotron falls back to system audio when streaming produced no segments")
    func unifiedNemotronRecoversEmptySystemTranscript() {
        #expect(MeetingEngine.shouldAttemptSystemRecovery(
            usesUnifiedNemotronTranscript: true,
            hasSystemSegments: false
        ))
    }

    @Test("Nemotron skips redundant system recovery when streaming produced segments")
    func unifiedNemotronKeepsStreamingSystemTranscript() {
        #expect(!MeetingEngine.shouldAttemptSystemRecovery(
            usesUnifiedNemotronTranscript: true,
            hasSystemSegments: true
        ))
    }

    @Test("batch meeting paths retain their existing system recovery behavior")
    func batchPathStillAttemptsSystemRecovery() {
        #expect(MeetingEngine.shouldAttemptSystemRecovery(
            usesUnifiedNemotronTranscript: false,
            hasSystemSegments: true
        ))
    }

    @Test("batch meeting paths recover when no system segments exist")
    func batchPathRecoversEmptySystemTranscript() {
        #expect(MeetingEngine.shouldAttemptSystemRecovery(
            usesUnifiedNemotronTranscript: false,
            hasSystemSegments: false
        ))
    }
}

// MARK: - Fakes

private final class FakeMeetingMicRecorder: MeetingMicRecording {
    var preferredInputDeviceID: AudioObjectID?
    var onRawPCMSamples: (([Int16]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var onHandoffOutcome: ((MeetingMicHandoffOutcome) -> Void)?

    private(set) var prepareCalls = 0
    private(set) var startCalls = 0
    private(set) var pauseCalls = 0
    private(set) var resumeCalls = 0
    private(set) var stopCalls = 0
    private(set) var cancelCalls = 0
    var stopURL: URL?

    func prepare() throws { prepareCalls += 1 }
    func start() throws { startCalls += 1 }
    func pause() { pauseCalls += 1 }
    func resume() { resumeCalls += 1 }
    func stop() -> URL? { stopCalls += 1; return stopURL }
    func cancel() { cancelCalls += 1 }
    func currentPower() -> Float { -30 }
    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        MeetingMicRecorderDiagnosticsSnapshot(recorderKind: .systemDefaultStreaming, preferredInputDeviceID: nil, route: nil)
    }
    func invalidateForTeardown() {}
    @discardableResult
    func requestSameRouteRecovery(reason: String) -> MeetingMicRecoveryRequestResult { .unavailable }
}

private final class FakeSystemAudioRecorder: SystemAudioCapturing {
    var onPCMSamples: (([Int16]) -> Void)?
    private(set) var isRecording = false
    private(set) var isPaused = false
    var captureHeartbeat: UInt64 = 0
    var onCaptureFailure: ((Error) -> Void)?
    private(set) var isRebuilding = false
    var supportsHeartbeatMonitoring = false
    var isRouteSettling = false

    private(set) var startCalls = 0
    private(set) var pauseCalls = 0
    private(set) var resumeCalls = 0
    private(set) var stopCalls = 0
    var stopURL: URL?

    func start() async throws {
        startCalls += 1
        isRecording = true
    }
    func pause() { pauseCalls += 1; isPaused = true }
    func resume() { resumeCalls += 1; isPaused = false }
    func stop() -> URL? {
        stopCalls += 1
        isRecording = false
        return stopURL
    }
    @discardableResult
    func rebuildForHealthRecovery(reason: String) -> Bool { false }
}

/// Distinguishes mic vs. system chunk files by directory name (`MeetingRuntimePaths`'s two
/// `PCMChunkRecorder` directory names), since both channels funnel through the same
/// `MeetingTranscriptionCoordinating.transcribeMeetingChunk(at:)` entry point.
private struct FakeTranscriptionCoordinator: MeetingTranscriptionCoordinating {
    var micText = ""
    var systemText = ""

    func getVadManager() async -> VadManager? { nil }

    func transcribeMeetingChunk(at url: URL) async throws -> SpeechTranscriptionResult {
        let text = url.deletingLastPathComponent().lastPathComponent == MeetingRuntimePaths.micChunkDirectoryName
            ? micText
            : systemText
        return SpeechTranscriptionResult(text: text, segments: [])
    }

    func transcribeMeeting(at url: URL) async throws -> SpeechTranscriptionResult {
        SpeechTranscriptionResult(text: "", segments: [])
    }

    func diarizeSystemAudio(at url: URL) async throws -> DiarizationResult? { nil }
}

/// Regression fixture for the "silent chunk loss on stop()" finding: every mic-chunk
/// transcription sleeps for `delayNanoseconds` before returning, so a chunk rotated just before
/// `stop()` is still in flight when `stop()` reaches `micChunkCollector
/// .closeAndDrainSortedSegments()` -- reproducing the race between that close and the chunk's
/// own completion-time `retire` call, rather than hoping timing happens to line up.
private struct DelayedMicChunkTranscriptionCoordinator: MeetingTranscriptionCoordinating {
    let delayNanoseconds: UInt64
    let micText: String

    func getVadManager() async -> VadManager? { nil }

    func transcribeMeetingChunk(at url: URL) async throws -> SpeechTranscriptionResult {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return SpeechTranscriptionResult(text: micText, segments: [])
    }

    func transcribeMeeting(at url: URL) async throws -> SpeechTranscriptionResult {
        SpeechTranscriptionResult(text: "", segments: [])
    }

    func diarizeSystemAudio(at url: URL) async throws -> DiarizationResult? { nil }
}

/// Deterministic suspend/release point for the "retire races persist" regression below.
/// `wait()` suspends until `open()` is called (or returns immediately if already open) --
/// used to hold one specific chunk's `persistSegments` call open exactly as long as the test
/// needs, rather than approximating a race with a fixed `Task.sleep` delay.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let toResume = waiters
        waiters.removeAll()
        toResume.forEach { $0.resume() }
    }
}

/// Returns `micText` for the FIRST mic chunk only; every later mic chunk transcribes to empty
/// text (which `transcribeMicChunk` turns into zero segments). That keeps the racing chunk the
/// ONLY chunk carrying the text the persistence fixture below targets, so `stop()`'s own
/// final-chunk persist call can never be mistaken for the racing one -- the difference between
/// proving the collector-drain path waits out and reports the racing chunk, and proving only
/// that *some* persist call blocked `stop()`.
private struct SingleMicChunkTranscriptionCoordinator: MeetingTranscriptionCoordinating {
    let micText: String
    private let calls = CallCounter()

    func getVadManager() async -> VadManager? { nil }

    func transcribeMeetingChunk(at url: URL) async throws -> SpeechTranscriptionResult {
        guard url.deletingLastPathComponent().lastPathComponent == MeetingRuntimePaths.micChunkDirectoryName else {
            return SpeechTranscriptionResult(text: "", segments: [])
        }
        let isFirst = await calls.claimFirst()
        return SpeechTranscriptionResult(text: isFirst ? micText : "", segments: [])
    }

    func transcribeMeeting(at url: URL) async throws -> SpeechTranscriptionResult {
        SpeechTranscriptionResult(text: "", segments: [])
    }

    func diarizeSystemAudio(at url: URL) async throws -> DiarizationResult? { nil }
}

private actor CallCounter {
    private var claimed = false

    func claimFirst() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// The error `RacingChunkPersistence` throws, carrying the segment text it refused so a test can
/// assert it was THAT chunk's failure that surfaced, not any failure at all.
private struct StubPersistenceError: Error {
    let text: String
}

/// A `MeetingPersisting` that behaves exactly like the real `MeetingStore` it wraps, except that
/// `appendSegment` for one chosen segment text optionally suspends and then always throws.
///
/// This is what replaced `MeetingEngine.init`'s `persistenceGateForTesting` closure, which
/// review rejected: that parameter was module-internal and took an arbitrary non-returning async
/// closure, so production code inside the app target could suspend persistence -- and `stop()`
/// -- indefinitely through a hook with no production purpose. The engine now names its
/// persistence dependency by protocol (`MeetingPersisting`), so this fixture is an ordinary
/// injected test double living in the test target, and the engine has no test-only parameter at
/// all. See `MeetingPersisting.swift`'s header.
///
/// It wraps a real `MeetingStore` rather than reimplementing one so every call the test is not
/// interested in still hits real SwiftData and the on-disk assertions stay meaningful.
private struct RacingChunkPersistence: MeetingPersisting {
    let store: MeetingStore
    /// The one segment text whose persistence is gated and failed.
    let failingSegmentText: String
    /// Opened by this fixture the moment the targeted `appendSegment` is reached. This is the
    /// "gate entered" signal a test waits on to construct the race deterministically, instead of
    /// sleeping and hoping: a sleep lets the pre-fix code reach the gate too, so a sleep-built
    /// race proves nothing about which interleaving actually ran.
    let enteredGate: Gate?
    /// Awaited before the targeted `appendSegment` throws, so a test controls exactly how long
    /// that persistence attempt stays outstanding. `nil` fails immediately, with no suspension.
    let releaseGate: Gate?

    @discardableResult
    func startMeeting(title: String, audioDirectoryPath: String, startDate: Date) async throws -> MeetingHandle {
        try await store.startMeeting(title: title, audioDirectoryPath: audioDirectoryPath, startDate: startDate)
    }

    @discardableResult
    func appendSegment(
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        speakerLabel: String,
        text: String,
        sourceChannel: MeetingSegmentChannel,
        to meeting: MeetingHandle
    ) async throws -> MeetingSegmentHandle {
        guard text == failingSegmentText else {
            return try await store.appendSegment(
                startOffset: startOffset,
                endOffset: endOffset,
                speakerLabel: speakerLabel,
                text: text,
                sourceChannel: sourceChannel,
                to: meeting
            )
        }
        await enteredGate?.open()
        await releaseGate?.wait()
        throw StubPersistenceError(text: text)
    }

    func updateDuration(_ duration: TimeInterval, for meeting: MeetingHandle) async throws {
        try await store.updateDuration(duration, for: meeting)
    }

    func updateState(_ state: MeetingState, for meeting: MeetingHandle) async throws {
        try await store.updateState(state, for: meeting)
    }

    func finish(_ meeting: MeetingHandle, endDate: Date) async throws {
        try await store.finish(meeting, endDate: endDate)
    }

    func markFailed(_ meeting: MeetingHandle) async throws {
        try await store.markFailed(meeting)
    }
}

/// Thread-safe call counter for `AlwaysFailingMarkFailedPersistence.markFailed`, so a test can
/// prove `discard()`'s retry loop actually ran the bounded number of attempts it promises, not
/// just that it swallowed one failure the way the pre-fix `try?` did.
private actor MarkFailedCallCounter {
    private(set) var count = 0

    func increment() { count += 1 }
}

/// A `MeetingPersisting` that behaves like the real `MeetingStore` it wraps except that
/// `markFailed` always throws -- regression fixture for "`discard()`'s `markMeetingFailedAfter
/// Discard` can leave a meeting row stuck" (FOLLOWUPS.md / FORK-PATCHES.md). Every other call is
/// forwarded unchanged so `engine.start()` still persists a real, fetchable `Meeting` row.
private struct AlwaysFailingMarkFailedPersistence: MeetingPersisting {
    let store: MeetingStore
    let markFailedCalls: MarkFailedCallCounter

    @discardableResult
    func startMeeting(title: String, audioDirectoryPath: String, startDate: Date) async throws -> MeetingHandle {
        try await store.startMeeting(title: title, audioDirectoryPath: audioDirectoryPath, startDate: startDate)
    }

    @discardableResult
    func appendSegment(
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        speakerLabel: String,
        text: String,
        sourceChannel: MeetingSegmentChannel,
        to meeting: MeetingHandle
    ) async throws -> MeetingSegmentHandle {
        try await store.appendSegment(
            startOffset: startOffset,
            endOffset: endOffset,
            speakerLabel: speakerLabel,
            text: text,
            sourceChannel: sourceChannel,
            to: meeting
        )
    }

    func updateDuration(_ duration: TimeInterval, for meeting: MeetingHandle) async throws {
        try await store.updateDuration(duration, for: meeting)
    }

    func updateState(_ state: MeetingState, for meeting: MeetingHandle) async throws {
        try await store.updateState(state, for: meeting)
    }

    func finish(_ meeting: MeetingHandle, endDate: Date) async throws {
        try await store.finish(meeting, endDate: endDate)
    }

    func markFailed(_ meeting: MeetingHandle) async throws {
        await markFailedCalls.increment()
        throw StubPersistenceError(text: "markFailed")
    }
}

/// Ordered record of what happened, so "stop() did not return early" is checked as an ORDERING
/// fact after the run rather than only as a snapshot taken during it.
private actor EventLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

/// Lets a test observe "has `engine.stop()` returned yet?" from outside, without consuming
/// its result via `Task.value` (which would itself suspend until completion, defeating the
/// point of checking whether it has completed).
private actor StopOutcomeBox {
    private(set) var result: MeetingEngineResult?

    func complete(_ result: MeetingEngineResult) {
        self.result = result
    }
}

@Suite("MeetingEngine", .serialized)
struct MeetingEngineTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Meeting.self, MeetingSegment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func fetchOnlyMeeting(from container: ModelContainer) throws -> Meeting? {
        try ModelContext(container).fetch(FetchDescriptor<Meeting>()).first
    }

    private func fetchSegments(from container: ModelContainer) throws -> [MeetingSegment] {
        try ModelContext(container).fetch(FetchDescriptor<MeetingSegment>())
    }

    /// Bounded poll for the fire-and-forget chunk-completion watcher Task
    /// (`rotateChunkOnQueue`/`rotateSystemChunkOnQueue`'s retire watcher) to reach the store.
    /// There is no lower-level synchronization hook to await instead: the watcher Task is
    /// deliberately fire-and-forget in production, matching the donor's own chunk-completion
    /// design (`meeting-session-port-plan.md` section 5).
    private func waitForSegmentCount(
        _ expected: Int,
        in container: ModelContainer,
        timeout: TimeInterval = 3
    ) async throws -> [MeetingSegment] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let segments = try fetchSegments(from: container)
            if segments.count >= expected { return segments }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try fetchSegments(from: container)
    }

    /// Bounded poll for `pause()`/`resume()`'s fire-and-forget `persistence.updateState(...)`
    /// Task to land -- same rationale as `waitForSegmentCount`: both callers are deliberately
    /// fire-and-forget in production (neither `pause()` nor `resume()` is `async`), so there is
    /// no synchronous completion signal to await instead.
    private func waitForMeetingState(
        _ expected: MeetingState,
        in container: ModelContainer,
        timeout: TimeInterval = 3
    ) async throws -> Meeting? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let meeting = try fetchOnlyMeeting(from: container)
            if meeting?.state == expected { return meeting }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try fetchOnlyMeeting(from: container)
    }

    private func fakeAudioSamples(count: Int = 1600) -> [Int16] {
        Array(repeating: 1000, count: count)
    }

    @Test("start persists a recording Meeting row with a real, existing audio directory")
    func startPersistsRecordingMeeting() async throws {
        let container = try makeContainer()
        let store = MeetingStore(modelContainer: container)
        let mic = FakeMeetingMicRecorder()
        let system = FakeSystemAudioRecorder()
        let engine = MeetingEngine(
            title: "Weekly sync",
            persistence: store,
            retainRecording: false,
            meetingMicRecorder: mic,
            systemAudioRecorderOverride: system
        )

        try await engine.start()

        let meeting = try #require(try fetchOnlyMeeting(from: container))
        #expect(meeting.title == "Weekly sync")
        #expect(meeting.state == .recording)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: meeting.audioDirectoryPath, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
        #expect(mic.prepareCalls == 1)
        #expect(mic.startCalls == 1)
        #expect(system.startCalls == 1)

        _ = try await engine.stop()
    }

    @Test("pause rotates and persists the in-flight chunk before any crash could lose it")
    func pauseRotatesAndPersistsInFlightChunk() async throws {
        let container = try makeContainer()
        let store = MeetingStore(modelContainer: container)
        let mic = FakeMeetingMicRecorder()
        let system = FakeSystemAudioRecorder()
        system.stopURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let coordinator = FakeTranscriptionCoordinator(micText: "hello from the mic", systemText: "hello from the room")
        let engine = MeetingEngine(
            title: "Standup",
            persistence: store,
            transcriptionCoordinator: coordinator,
            retainRecording: false,
            meetingMicRecorder: mic,
            systemAudioRecorderOverride: system
        )

        try await engine.start()
        mic.onRawPCMSamples?(fakeAudioSamples())
        system.onPCMSamples?(fakeAudioSamples())

        engine.pause()

        let segments = try await waitForSegmentCount(2, in: container)
        #expect(segments.count == 2)
        let micSegment = try #require(segments.first { $0.sourceChannel == .mic })
        #expect(micSegment.text == "hello from the mic")
        #expect(micSegment.speakerLabel == "You")
        let systemSegment = try #require(segments.first { $0.sourceChannel == .system })
        #expect(systemSegment.text == "hello from the room")
        #expect(systemSegment.speakerLabel == "Others")

        let meeting = try #require(try await waitForMeetingState(.paused, in: container))
        #expect(meeting.state == .paused)
        #expect(mic.pauseCalls == 1)
        #expect(system.pauseCalls == 1)

        engine.resume()
        let resumedMeeting = try #require(try await waitForMeetingState(.recording, in: container))
        #expect(resumedMeeting.state == .recording)
        #expect(mic.resumeCalls == 1)

        _ = try await engine.stop()
    }

    @Test("discard marks the meeting failed and never transcribes")
    func discardMarksFailed() async throws {
        let container = try makeContainer()
        let store = MeetingStore(modelContainer: container)
        let mic = FakeMeetingMicRecorder()
        let system = FakeSystemAudioRecorder()
        let coordinator = FakeTranscriptionCoordinator(micText: "should never be persisted", systemText: "")
        let engine = MeetingEngine(
            title: "Abandoned",
            persistence: store,
            transcriptionCoordinator: coordinator,
            retainRecording: false,
            meetingMicRecorder: mic,
            systemAudioRecorderOverride: system
        )

        try await engine.start()
        mic.onRawPCMSamples?(fakeAudioSamples())

        engine.discard()

        let meeting = try await waitForMeetingState(.failed, in: container)
        #expect(meeting?.state == .failed)
        #expect(try fetchSegments(from: container).isEmpty)
        #expect(mic.cancelCalls == 1)
    }

    /// Regression test for FOLLOWUPS.md's "`discard()` can leave a meeting row stuck in
    /// `.recording`/`.paused`": before the fix, `discard()`'s `Task { try? await persistence
    /// .markFailed(meetingHandle) }` called `markFailed` exactly once and silently dropped
    /// whatever it threw, so this test's counter would stop at 1 and never reach
    /// `discardMarkFailedMaxAttempts`, failing. After the fix, `markMeetingFailedAfterDiscard`
    /// retries up to `discardMarkFailedMaxAttempts` times before giving up and logging, so the
    /// counter reaches that bound even though `AlwaysFailingMarkFailedPersistence.markFailed`
    /// never succeeds.
    @Test("discard retries markFailed before giving up on a persistently failing store")
    func discardRetriesMarkFailedOnPersistentFailure() async throws {
        let container = try makeContainer()
        let store = MeetingStore(modelContainer: container)
        let markFailedCalls = MarkFailedCallCounter()
        let persistence = AlwaysFailingMarkFailedPersistence(store: store, markFailedCalls: markFailedCalls)
        let mic = FakeMeetingMicRecorder()
        let system = FakeSystemAudioRecorder()
        let engine = MeetingEngine(
            title: "Abandoned with a hostile store",
            persistence: persistence,
            retainRecording: false,
            meetingMicRecorder: mic,
            systemAudioRecorderOverride: system
        )

        try await engine.start()
        engine.discard()

        let deadline = Date().addingTimeInterval(5)
        while await markFailedCalls.count < MeetingEngine.discardMarkFailedMaxAttempts, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(await markFailedCalls.count == MeetingEngine.discardMarkFailedMaxAttempts)
    }

    @Test("stop finalizes the meeting and assembles the reconciled transcript")
    func stopFinalizesMeeting() async throws {
        let container = try makeContainer()
        let store = MeetingStore(modelContainer: container)
        let mic = FakeMeetingMicRecorder()
        let system = FakeSystemAudioRecorder()
        system.stopURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let coordinator = FakeTranscriptionCoordinator(micText: "final words from me", systemText: "final words from the room")
        let engine = MeetingEngine(
            title: "Retro",
            persistence: store,
            transcriptionCoordinator: coordinator,
            retainRecording: false,
            meetingMicRecorder: mic,
            systemAudioRecorderOverride: system
        )

        try await engine.start()
        mic.onRawPCMSamples?(fakeAudioSamples())
        system.onPCMSamples?(fakeAudioSamples())

        let result = try await engine.stop()

        #expect(result.title == "Retro")
        #expect(result.rawTranscript.contains("final words from me"))
        #expect(result.rawTranscript.contains("final words from the room"))
        #expect(result.durationSeconds >= 0)

        let meeting = try #require(try fetchOnlyMeeting(from: container))
        #expect(meeting.state == .completed)
        #expect(meeting.endDate != nil)

        let segments = try fetchSegments(from: container)
        #expect(segments.contains { $0.text == "final words from me" && $0.sourceChannel == .mic })
        #expect(segments.contains { $0.text == "final words from the room" && $0.sourceChannel == .system })

        #expect(mic.stopCalls == 1)
        #expect(system.stopCalls == 1)
    }

    /// Regression test for the "silent chunk loss on stop()" finding. Rotation watchers only
    /// persist a chunk AFTER a successful `retire`, but `stop()` closes the collector
    /// (`closeAndDrainSortedSegments`) and drains still-in-flight chunks DIRECTLY, which makes
    /// their own later `retire` call fail and exit before persisting -- so a chunk still
    /// transcribing when the user hits stop would appear in the returned transcript while being
    /// absent from the store. This is a defect the port introduced (the donor has no per-chunk
    /// persistence watcher to preserve), not donor behavior to keep.
    ///
    /// `pause()` rotates a real mic chunk (same mechanism VAD-driven rotation uses) and registers
    /// its transcription with `micChunkCollector`. `DelayedMicChunkTranscriptionCoordinator`
    /// makes that transcription take `delayNanoseconds`, so it is still pending in the collector
    /// when `stop()` -- called immediately after, with no wait in between -- reaches
    /// `micChunkCollector.closeAndDrainSortedSegments()`. That reproduces the race
    /// deterministically instead of hoping timing lines up.
    @Test("stop() does not silently drop a chunk that was still transcribing when it was called")
    func stopPersistsChunkStillInFlightAtCallTime() async throws {
        let container = try makeContainer()
        let store = MeetingStore(modelContainer: container)
        let mic = FakeMeetingMicRecorder()
        let system = FakeSystemAudioRecorder()
        let coordinator = DelayedMicChunkTranscriptionCoordinator(
            delayNanoseconds: 300_000_000,
            micText: "in-flight when stop was called"
        )
        let engine = MeetingEngine(
            title: "Race",
            persistence: store,
            transcriptionCoordinator: coordinator,
            retainRecording: false,
            meetingMicRecorder: mic,
            systemAudioRecorderOverride: system
        )

        try await engine.start()
        mic.onRawPCMSamples?(fakeAudioSamples())

        // Rotates the mic chunk and registers its (slow) transcription with micChunkCollector,
        // then returns immediately -- the transcription is still running in the background.
        engine.pause()

        // Called with no wait: the 300ms delayed transcription cannot have completed yet, so
        // `stop()` is guaranteed to race its own `closeAndDrainSortedSegments()` against that
        // chunk's still-pending completion.
        let result = try await engine.stop()

        // The segment reaches the returned transcript either way (this was never in question).
        #expect(result.rawTranscript.contains("in-flight when stop was called"))

        // The bug: it never reached the store, because the chunk's own watcher Task's `retire`
        // call raced the collector's close and lost, so persistence was skipped entirely.
        let segments = try fetchSegments(from: container)
        #expect(segments.contains { $0.text == "in-flight when stop was called" && $0.sourceChannel == .mic })
    }

    /// Regression test for the SIBLING of the "silent chunk loss" finding above, found on
    /// re-review of that fix: the mid-meeting watcher (`rotateChunkOnQueue`) called
    /// `retire(id:segments:)` BEFORE `persistSegments`, so a chunk could be moved into the
    /// collector's `completedSegments` bucket -- and so be treated by
    /// `closeAndDrainSortedSegments()` as "already someone else's job to persist, don't touch
    /// it again" -- while its actual persistence attempt was still outstanding, or had already
    /// failed silently to stderr. "Retired" meant "persistence is ABOUT to be attempted," not
    /// "persistence completed," and the collector's drain could not tell the difference.
    ///
    /// This test now pins BOTH halves of that invariant on the drain-wins side of the race:
    /// `stop()` does not return while the racing chunk's persistence is outstanding, AND when
    /// that persistence fails, the failure reaches `MeetingEngineResult.persistenceFailures`
    /// rather than only stderr. A previous revision asserted the first half only, which left
    /// the second free to regress unnoticed.
    ///
    /// DETERMINISTIC BY CONSTRUCTION, not by sleeping. The race is built by waiting on
    /// `enteredGate` -- a signal `RacingChunkPersistence` opens the instant the racing chunk's
    /// `appendSegment` is reached -- so the chunk's persistence is provably suspended, and its
    /// task provably still pending, before `stop()` is ever called. An earlier revision slept
    /// 100ms here instead, which review correctly rejected: under pre-fix scheduling the old
    /// drain path could reach the gate itself within that window, so the test passed either way
    /// and proved nothing about which interleaving ran. The one remaining `Task.sleep` below is
    /// an OBSERVATION window ("has stop() returned yet?"), not part of constructing the race,
    /// and the `EventLog` ordering assertion checks the same fact a second way without it.
    @Test("stop() waits out a racing chunk's persistence and reports its failure")
    func stopAwaitsRacingChunkPersistenceAndSurfacesItsFailure() async throws {
        let container = try makeContainer()
        let mic = FakeMeetingMicRecorder()
        let system = FakeSystemAudioRecorder()
        let enteredGate = Gate()
        let releaseGate = Gate()
        let persistence = RacingChunkPersistence(
            store: MeetingStore(modelContainer: container),
            failingSegmentText: "gated racing chunk",
            enteredGate: enteredGate,
            releaseGate: releaseGate
        )
        let engine = MeetingEngine(
            title: "GatedRace",
            persistence: persistence,
            transcriptionCoordinator: SingleMicChunkTranscriptionCoordinator(micText: "gated racing chunk"),
            retainRecording: false,
            meetingMicRecorder: mic,
            systemAudioRecorderOverride: system
        )

        try await engine.start()
        mic.onRawPCMSamples?(fakeAudioSamples())

        // Rotates the mic chunk and registers its task with the collector, synchronously.
        engine.pause()

        // The race, imposed rather than raced for: this returns only once that chunk's
        // persistence attempt is actually inside the gate, so the task CANNOT have completed
        // and CANNOT have been retired when stop() closes the collector below.
        await enteredGate.wait()

        let box = StopOutcomeBox()
        let log = EventLog()
        let stopTask = Task {
            let result = try await engine.stop()
            await log.record("stopReturned")
            await box.complete(result)
        }

        // Observation window only (see this test's doc comment): stop() must NOT have returned
        // while the racing chunk's persistence is still suspended.
        try await Task.sleep(for: .milliseconds(300))
        let completedWhileGated = await box.result != nil
        #expect(!completedWhileGated, "stop() returned while the racing chunk's persistence was still gated shut")

        await log.record("gateOpened")
        await releaseGate.open()
        try await stopTask.value
        let result = try #require(await box.result)

        // The same fact as the snapshot above, as an ordering: stop() cannot have returned
        // before the gate was opened.
        #expect(await log.events == ["gateOpened", "stopReturned"])

        // Completion half: the segment is in the transcript.
        #expect(result.rawTranscript.contains("gated racing chunk"))
        // Failure half: and the caller is told it never reached disk.
        #expect(result.persistenceFailures.contains { ($0 as? StubPersistenceError)?.text == "gated racing chunk" })
        let segments = try fetchSegments(from: container)
        #expect(!segments.contains { $0.text == "gated racing chunk" })
    }

    /// The OTHER side of that race, and the half two fix rounds left open: the chunk's own
    /// watcher Task reaches `await task.value` FIRST and retires the chunk before `stop()`
    /// closes the collector. Completion was already guaranteed on this side (persistence lives
    /// inside the awaited task, so `retire` succeeding means it already ran). Failure reporting
    /// was not: `retire` took only the segments, so the failure was dropped at that moment and
    /// `closeAndDrainSortedSegments()` handed back a segment it could no longer report a
    /// persistence failure for. The transcript said the meeting was complete, the result said
    /// it persisted cleanly, and the only record otherwise was a line on stderr -- exactly the
    /// silent partial loss this whole path exists to prevent.
    ///
    /// DETERMINISTIC BY CONSTRUCTION, with no sleep and no gate: `onChunkTranscribed` is fired
    /// by the watcher only AFTER its `retire` call has already succeeded, so waiting on it
    /// before calling `stop()` does not merely make the watcher-wins interleaving likely, it
    /// makes the drain-wins one impossible.
    @Test("stop() reports the persistence failure of a chunk its watcher retired first")
    func stopSurfacesPersistenceFailureOfAlreadyRetiredChunk() async throws {
        let container = try makeContainer()
        let mic = FakeMeetingMicRecorder()
        let system = FakeSystemAudioRecorder()
        let persistence = RacingChunkPersistence(
            store: MeetingStore(modelContainer: container),
            failingSegmentText: "retired before stop",
            enteredGate: nil,
            releaseGate: nil
        )
        let engine = MeetingEngine(
            title: "RetiredBeforeStop",
            persistence: persistence,
            transcriptionCoordinator: SingleMicChunkTranscriptionCoordinator(micText: "retired before stop"),
            retainRecording: false,
            meetingMicRecorder: mic,
            systemAudioRecorderOverride: system
        )

        let retired = Gate()
        engine.onChunkTranscribed = { segments, _ in
            guard segments.contains(where: { $0.text == "retired before stop" }) else { return }
            Task { await retired.open() }
        }

        try await engine.start()
        mic.onRawPCMSamples?(fakeAudioSamples())
        engine.pause()

        // Fired only after the watcher's `retire` succeeded, so by the time stop() runs the
        // chunk is already in the collector's completed bucket and its task is gone.
        await retired.wait()

        let result = try await engine.stop()

        #expect(result.rawTranscript.contains("retired before stop"))
        #expect(
            result.persistenceFailures.contains { ($0 as? StubPersistenceError)?.text == "retired before stop" },
            "a chunk retired before stop() lost its persistence failure: the transcript reports it, the store does not have it, and the result says the meeting persisted cleanly"
        )
        let segments = try fetchSegments(from: container)
        #expect(!segments.contains { $0.text == "retired before stop" })
    }
}

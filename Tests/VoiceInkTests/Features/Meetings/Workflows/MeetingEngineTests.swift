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
}

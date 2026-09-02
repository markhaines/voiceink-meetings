// Ported from Muesli-HQ/muesli (native/MuesliNative/Sources/MuesliNativeApp/MeetingSession.swift,
// 1475 lines), per the seam map at `.tandem/884f6ef6905c4e2aa4e2ca28c34ea629/meeting-session-port-plan.md`
// and the transcription-seam decision at `.tandem/884f6ef6905c4e2aa4e2ca28c34ea629/DECISION-transcription-seam.md`.
// `MeetingChunkCollector` (donor lines 8-92) was split into its own file,
// `MeetingChunkCollector.swift`, in this same directory.
//
// This is a PARTIAL port. What is cut, and why, is recorded next to each cut below rather than
// silently dropped -- see `meeting-session-port-plan.md`'s KEEP/CUT/REWRITE table for the full
// per-line-range accounting this file follows. Summary of what is NOT in this stage:
//
//   - Transcription is stubbed behind `MeetingTranscriptionCoordinating`
//     (Transcription/MeetingTranscriptionCoordinating.swift). This stage wires the seam;
//     Stage 2c builds the real coordinator actor.
//   - Title generation, notes summarization (`MeetingSummaryClient`), and diagnostics reporting
//     (`MeetingSessionDiagnostics`) are cut -- donor code with zero fork equivalent, and this
//     stage's `stop()` returns a slim `MeetingEngineResult` ending at the reconciled raw
//     transcript, per the seam map's row 2 recommendation.
//   - `ScreenContextCapture`/`MeetingScreenContextCollector` (Seam 5) is cut -- explicitly an
//     unwanted feature per the port brief.
//   - `MeetingRecordingWriter` (Seam 6, retained mixed-audio recording) is WIRED IN, not cut --
//     correcting a premise this dispatch's own seam map got wrong. The seam map (written before
//     PR #9, `meeting-recording-writer`, landed) asserted the type was "entirely absent from the
//     fork" and recommended stubbing it out. It is not absent: `MeetingRecordingWriter.swift`
//     exists, is fully tested (`MeetingRecordingWriterTests.swift`, 9 tests), and its own
//     FORK-PATCHES.md entry says explicitly "Not wired into any engine" -- i.e. it was landed
//     ahead of a consumer, and `MeetingEngine` is that consumer. Wiring it in (matching donor
//     call sites exactly: `appendMic`/`appendSystem` with RAW samples before AEC,
//     `markPauseBoundary()` on pause, `stop()`/`cancel()` on teardown) is materially more
//     faithful than the seam map's proposed stub, so this port does that instead. Gated by a new
//     `retainRecording: Bool` init parameter (default `true`, no fork settings surface exists to
//     read a real user preference from yet -- see the seam map's own Seam 1 finding that
//     `AppConfig` has no fork equivalent). `MeetingRecordingWriter.persistTemporaryRecordingAsync`
//     (the temp-WAV-to-permanent-M4A step) is deliberately NOT called here: donor's own
//     `MeetingSession.swift` never calls it either -- only `MuesliController.swift` does, which
//     this dispatch explicitly excludes from this port. `MeetingEngineResult.retainedRecordingURL`
//     is therefore the raw temp WAV, exactly matching donor's `MeetingSessionResult` semantics;
//     persisting it permanently is a later stage's (a future app-controller's) job.
//   - Streaming display-only partials (`MeetingStreamingPartialSession`,
//     `MeetingLiveCaptionModelStore`) are cut -- no fork equivalent, and the donor's own comment
//     (donor line 481) says the VAD-chunk pipeline remains the durable source of truth with or
//     without them.
//   - `MeetingTranscriptChunkHealthTracker` (donor: `micChunkHealthTracker`/
//     `systemChunkHealthTracker`) is cut -- NOT flagged by the seam map (a gap this port found),
//     has no fork equivalent, and every one of its call sites in the donor sits inside either
//     the cut diagnostics report or the deferred system-segment repair pass below. Nothing in
//     this stage's `stop()`/rotation path needs it.
//   - The system-segment repair pass (`repairSystemSegmentsIfNeeded`,
//     `fallbackToFullSessionSystemTranscription`) is deferred to Stage 2c alongside the real
//     transcription coordinator: it depends on `MeetingTranscriptHealthMonitor`,
//     `MeetingMicRepairPlanner`, and `AudioConverter`, none of which exist in this fork (seam
//     map's own staged-work-breakdown item 3 flags this as an open question, not a certainty,
//     to resolve "before writing transcribeMicChunk" -- resolved here as: not this stage).
//     `shouldAttemptSystemRecovery` is kept regardless, per the seam map's explicit
//     recommendation, since it is dependency-free and its tests are portable now.
//   - Backend selection (donor `BackendOption` + `updateBackend`/`currentBackend()`) is cut, not
//     carried forward as a placeholder enum: the seam map calls this a product decision with no
//     fork equivalent, and inventing one now would just be deleted when Stage 2c's coordinator
//     makes the real choice internally.
//
// NEW, not from the donor: `MeetingStore` (SwiftData) integration. The donor has no
// persistence layer at all -- this fork added `MeetingStore` in PR #8 specifically so
// `MeetingEngine` would have a durability contract to write against (see that type's own doc
// comment). `startMeeting`/`appendSegment`/`updateDuration`/`updateState`/`finish`/`markFailed`
// calls below are this stage's own wiring, not a donor behavior being preserved.
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
import os

/// Which stage of post-capture processing a meeting is in. Donor's four-case enum, kept
/// verbatim even though the two title/notes-generation cases (`generatingTitle`,
/// `summarizingNotes`) are not reachable from this stage's slim `stop()` -- carrying the whole
/// enum now means Stage 2c's title/notes work does not need to touch every call site that
/// switches over it.
enum MeetingProcessingStage {
    case transcribingAudio
    case cleaningAudio
    case generatingTitle
    case summarizingNotes

    var allowsDictation: Bool {
        switch self {
        case .transcribingAudio, .cleaningAudio:
            false
        case .generatingTitle, .summarizingNotes:
            true
        }
    }
}

/// Slim result of a finished meeting recording. Deliberately smaller than the donor's
/// `MeetingSessionResult`: no title/notes/export fields, since title generation, notes
/// summarization, and diagnostics reporting are all cut for this stage (see this file's
/// header). Grows again once `Enhancement/`/`Views/`/`Export/` land.
struct MeetingEngineResult: Sendable {
    let title: String
    let startTime: Date
    let endTime: Date
    let durationSeconds: Double
    let rawTranscript: String
    let systemRecordingURL: URL?
    /// The raw temp WAV `MeetingRecordingWriter` produced, or nil if retention was off or
    /// nothing was recorded. NOT transcoded/moved to permanent storage -- see this file's
    /// header on why `persistTemporaryRecordingAsync` is deliberately not called here.
    let retainedRecordingURL: URL?
    /// Set only if `retainRecording` was on and `MeetingRecordingWriter.init()` itself threw
    /// (e.g. could not open the temp file for writing) -- donor
    /// `retainedRecordingWriterError`/`MeetingSessionResult.retainedRecordingError`.
    let retainedRecordingError: Error?
}

/// Port of the donor's `MeetingSession` -- the serial orchestrator for one meeting's capture:
/// mic + system audio, AEC, VAD-driven chunk rotation, per-chunk transcription (stubbed this
/// stage), and incremental persistence through `MeetingStore`. Parallel to `VoiceInkEngine`,
/// never touching it: meeting state stays entirely separate from dictation's `RecordingState`.
final class MeetingEngine {
    private static let logger = Logger(subsystem: "com.hainesy.voiceinkmeetings", category: "MeetingEngine")

    private let title: String
    private let persistence: MeetingStore
    private let transcriptionCoordinator: MeetingTranscriptionCoordinating
    private let systemAudioRecorder: SystemAudioCapturing
    private let neuralAec = MeetingNeuralAec()

    /// Route-aware mic recorder with real-time 16 kHz mono PCM access.
    private var meetingMicRecorder: MeetingMicRecording
    private var rawMicChunkRecorder: PCMChunkRecorder?
    private var systemChunkRecorder: PCMChunkRecorder?
    private let retainRecording: Bool
    private var retainedRecordingWriter: MeetingRecordingWriter?
    private var retainedRecordingWriterError: Error?
    /// VAD facade for speech-boundary chunk rotation. Renamed from the donor's
    /// `vadController`/`systemVadController: StreamingVadController?` to the fork's own
    /// AEC-cleaned-mic facade types (`meeting-session-port-plan.md` section 4) -- constructing
    /// a bare `StreamingVadController` here directly, instead of through this facade, is
    /// exactly the bypass `MeetingVadStreamsTests.processAudioCallSitesAreFacadeOnly` exists to
    /// catch.
    private var micVad: MicVadStream?
    private var systemVad: SystemVadStream?
    private let micChunkCollector = MeetingChunkCollector()
    private let systemChunkCollector = MeetingChunkCollector()
    private let micHealthTracker = MeetingMicHealthTracker()
    private let micRecoveryCoordinator = MeetingMicRecoveryCoordinator()
    private let systemAudioWatchdog = MeetingSystemAudioWatchdog()
    private var systemAudioWatchdogTimer: DispatchSourceTimer?
    private let chunkRotationQueue = DispatchQueue(label: "com.hainesy.voiceinkmeetings.meeting-engine.chunk-rotation")
    private let pausedDisplayLock = OSAllocatedUnfairLock(initialState: false)
    private var chunkTimingTracker = MeetingChunkTimingTracker()
    private var systemChunkTimingTracker = MeetingChunkTimingTracker()

    var onMicHealthChanged: ((MeetingMicHealthSnapshot) -> Void)?
    /// Episode-level mic-health events: one degraded/recovered pair per actual degradation
    /// episode, or a single unrecovered event if the meeting ends while degraded. Feed
    /// telemetry here; keep per-snapshot UI updates on `onMicHealthChanged`.
    var onMicHealthEpisode: ((MeetingMicHealthEpisodeEvent) -> Void)?
    /// Fired at most once per meeting when confirmed degradation is classified as user-muted
    /// input (no recovery episode is opened in that case).
    var onMicHealthUserMuted: (() -> Void)?
    /// Episode-level system-audio (tap) health events: degraded when the IO heartbeat stalls
    /// or a rebuild fails terminally, recovered when capture resumes, unrecovered if the
    /// meeting ends dead.
    var onSystemAudioHealthEpisode: ((MeetingSystemAudioHealthEvent) -> Void)?
    var onChunkTranscribed: (([SpeechSegment], String) -> Void)?

    /// `MeetingStore` handle for this meeting, assigned once `start()`'s
    /// `persistence.startMeeting` call succeeds. Every persistence call after that is a no-op
    /// (via `try?`) if this is somehow nil -- see `persistSegments(_:channel:)` -- which can
    /// only happen if a caller invokes `pause()`/`resume()`/`stop()`/`discard()` before
    /// `start()` ever ran; the donor has no equivalent guard because it has no persistence
    /// layer at all.
    private var meetingHandle: MeetingHandle?

    /// Current mic power level for waveform visualization.
    func currentPower() -> Float {
        if pausedDisplayLock.withLock({ $0 }) {
            return -160
        }
        return meetingMicRecorder.currentPower()
    }

    private(set) var startTime: Date?
    private(set) var isRecording = false
    private(set) var isPaused = false

    private func setPausedStateOnQueue(_ paused: Bool) {
        isPaused = paused
        pausedDisplayLock.withLock { $0 = paused }
    }

    /// - Parameter useCoreAudioTap: picks `CoreAudioSystemRecorder` (default) or
    ///   `SystemAudioRecorder` (ScreenCaptureKit) for system-audio capture, matching donor's
    ///   `config.useCoreAudioTap` switch (donor lines 267-271). A plain `Bool` parameter here,
    ///   not a settings struct: every other field the seam map's proposed `AppConfig`
    ///   replacement would have carried (`enableScreenContext`, live-partials backend
    ///   selection, the five `resolved*Language` knobs) is moot under this stage's cuts, so a
    ///   one-field struct would be pure ceremony. Revisit into a struct if backend selection
    ///   adds real fields later.
    /// - Parameter retainRecording: donor's `config.meetingRecordingSavePolicy != .never` gate
    ///   on `setupRetainedRecordingWriterIfNeeded()`. Defaults `true`: there is no fork settings
    ///   surface yet to read a real user preference from (Seam 1), and the writer itself is
    ///   already landed and tested, so defaulting it off would silently disable a working
    ///   feature for no reason tied to this stage's own scope.
    /// - Parameter systemAudioRecorderOverride: test-only seam, NOT present in the donor (its
    ///   `MeetingSession.init` hardcodes the same `useCoreAudioTap` switch with no injection
    ///   point either -- verified). Added here because this stage's brief requires verifying
    ///   `MeetingStore`'s per-chunk persistence wiring under test, and that is otherwise
    ///   unreachable without real CoreAudio-tap/ScreenCaptureKit hardware access. `nil` (the
    ///   default) reproduces the donor's exact hardcoded behavior for every real caller.
    init(
        title: String,
        persistence: MeetingStore,
        transcriptionCoordinator: MeetingTranscriptionCoordinating = NullMeetingTranscriptionCoordinator(),
        useCoreAudioTap: Bool = true,
        retainRecording: Bool = true,
        meetingMicRecorder: MeetingMicRecording = RouteAwareMeetingMicRecorder(),
        systemAudioRecorderOverride: SystemAudioCapturing? = nil
    ) {
        self.title = title
        self.persistence = persistence
        self.transcriptionCoordinator = transcriptionCoordinator
        self.retainRecording = retainRecording
        self.meetingMicRecorder = meetingMicRecorder
        if let systemAudioRecorderOverride {
            self.systemAudioRecorder = systemAudioRecorderOverride
        } else if useCoreAudioTap {
            self.systemAudioRecorder = CoreAudioSystemRecorder()
        } else {
            self.systemAudioRecorder = SystemAudioRecorder()
        }
        micRecoveryCoordinator.recoveryRequest = { [weak meetingMicRecorder] reason in
            guard let meetingMicRecorder else { return .unavailable }
            return meetingMicRecorder.requestSameRouteRecovery(reason: reason)
        }
        // Recovery handoffs mid-transition reliably fail their first-buffer window; defer them
        // until the daemon settles (same signal the tap watchdog uses -- BT transitions move
        // input and output together).
        micRecoveryCoordinator.isRouteSettling = { [weak systemAudioRecorder] in
            systemAudioRecorder?.isRouteSettling ?? false
        }
        micRecoveryCoordinator.onEpisodeEvent = { [weak self] event in
            self?.onMicHealthEpisode?(event)
        }
        micRecoveryCoordinator.isInputMuted = { [weak self] in
            self?.isCaptureInputMuted() ?? false
        }
        micRecoveryCoordinator.onUserMuted = { [weak self] in
            self?.onMicHealthUserMuted?()
        }
        micRecoveryCoordinator.contextProvider = { [weak meetingMicRecorder] in
            guard let snapshot = meetingMicRecorder?.diagnosticsSnapshot() else {
                return MeetingMicEpisodeContext()
            }
            return MeetingMicEpisodeContext(
                recorderKind: snapshot.recorderKind.rawValue,
                routeCategory: snapshot.route?.outputRouteKind,
                selectedInputResolved: snapshot.route?.selectedInputDeviceResolved
            )
        }
        meetingMicRecorder.onHandoffOutcome = { [weak micRecoveryCoordinator] outcome in
            micRecoveryCoordinator?.noteHandoffOutcome(outcome)
        }
        systemAudioWatchdog.captureHeartbeat = { [weak systemAudioRecorder] in
            systemAudioRecorder?.captureHeartbeat ?? 0
        }
        systemAudioWatchdog.isCaptureActive = { [weak systemAudioRecorder] in
            guard let recorder = systemAudioRecorder else { return false }
            return recorder.isRecording && !recorder.isPaused && !recorder.isRebuilding
        }
        systemAudioWatchdog.isPaused = { [weak systemAudioRecorder] in
            systemAudioRecorder?.isPaused ?? false
        }
        systemAudioWatchdog.isRouteSettling = { [weak systemAudioRecorder] in
            systemAudioRecorder?.isRouteSettling ?? false
        }
        systemAudioWatchdog.lastMicCallbackAt = { [weak self] in
            self?.micHealthTracker.snapshot().lastRawMicCallbackAt
        }
        systemAudioWatchdog.recoveryRequest = { [weak systemAudioRecorder] reason in
            systemAudioRecorder?.rebuildForHealthRecovery(reason: reason) ?? false
        }
        systemAudioWatchdog.onMicBlindnessDegradation = { [weak micRecoveryCoordinator] reason in
            micRecoveryCoordinator?.noteExternalDegradation(reason: reason)
        }
        systemAudioWatchdog.onEpisodeEvent = { [weak self] event in
            self?.onSystemAudioHealthEpisode?(event)
        }
        systemAudioRecorder.onCaptureFailure = { [weak systemAudioWatchdog] error in
            systemAudioWatchdog?.noteCaptureFailure(reason: "rebuild_exhausted: \(error.localizedDescription)")
        }
    }

    func setPreferredMicrophoneInputDeviceID(_ deviceID: AudioObjectID?) {
        meetingMicRecorder.preferredInputDeviceID = deviceID
    }

    /// True when the capture device is muted or zero-gain at the source (user intent), which
    /// presents the same all-zero signature as a broken route. Called by the coordinator at
    /// episode confirmation and at most 1Hz while a suppressed degradation continues -- never
    /// per sample batch.
    private func isCaptureInputMuted() -> Bool {
        var deviceID = meetingMicRecorder.preferredInputDeviceID ?? kAudioObjectUnknown
        if deviceID == kAudioObjectUnknown {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
            ) == noErr, deviceID != kAudioObjectUnknown else { return false }
        }
        // Volume and mute controls may live on the main element (0) or on any input channel.
        // Enumerate the device's actual input channel count via the stream configuration and
        // probe every channel; a read failure just means "no control there".
        var elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain]
        var configAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var configSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &configAddress, 0, nil, &configSize) == noErr, configSize > 0 {
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(configSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { raw.deallocate() }
            if AudioObjectGetPropertyData(deviceID, &configAddress, 0, nil, &configSize, raw) == noErr {
                let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                let channelCount = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
                if channelCount > 0 {
                    elements.append(contentsOf: (1...channelCount).map { AudioObjectPropertyElement($0) })
                }
            }
        }
        for element in elements {
            var volumeAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: element
            )
            var volume: Float32 = 1
            var volumeSize = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &volumeSize, &volume) == noErr,
               volume <= 0.0001 {
                return true
            }
            var muteAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: element
            )
            var muted: UInt32 = 0
            var muteSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &muteSize, &muted) == noErr,
               muted != 0 {
                return true
            }
        }
        return false
    }

    // MARK: - Lifecycle

    func start() async throws {
        let vadManager = await transcriptionCoordinator.getVadManager()
        let now = Date()

        // Per-meeting audio directory, a child of MeetingRuntimePaths.meetingAudioDirectory(),
        // matching Meeting.audioDirectoryPath's documented contract. Distinct from
        // MeetingRecordingWriter's own temp-directory retained recording (a single mixed WAV,
        // not per-meeting-scoped) -- this directory is reserved for a future permanent-storage
        // step (`persistTemporaryRecordingAsync`, not called by this stage -- see this file's
        // header) to move that retained recording into.
        let audioDirectory = try MeetingRuntimePaths.meetingAudioDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let handle = try await persistence.startMeeting(
            title: title,
            audioDirectoryPath: audioDirectory.path,
            startDate: now
        )
        meetingHandle = handle

        // AEC must be loaded before audio pipeline starts (streaming mode)
        await neuralAec.preload()

        chunkRotationQueue.sync {
            startTime = now
            chunkTimingTracker.start()
            systemChunkTimingTracker.start()
            isRecording = true
            setPausedStateOnQueue(false)
        }

        do {
            try prepareRealtimeAudioPipeline(vadManager: vadManager)
            try meetingMicRecorder.prepare()
            setupRetainedRecordingWriterIfNeeded()
            try await systemAudioRecorder.start()
            startSystemAudioWatchdog()
            try meetingMicRecorder.start()
        } catch {
            stopSystemAudioWatchdog()
            micVad?.stop()
            micVad = nil
            systemVad?.stop()
            systemVad = nil
            meetingMicRecorder.onRawPCMSamples = nil
            systemAudioRecorder.onPCMSamples = nil
            retainedRecordingWriter?.cancel()
            retainedRecordingWriter = nil
            rawMicChunkRecorder?.cancel()
            rawMicChunkRecorder = nil
            systemChunkRecorder?.cancel()
            systemChunkRecorder = nil
            chunkRotationQueue.sync {
                isRecording = false
                setPausedStateOnQueue(false)
                startTime = nil
                chunkTimingTracker.discard()
                systemChunkTimingTracker.discard()
            }
            meetingMicRecorder.cancel()
            if let url = systemAudioRecorder.stop() {
                try? FileManager.default.removeItem(at: url)
            }
            // Donor cancels only systemChunkCollector here, not micChunkCollector -- ported
            // verbatim (MeetingSession.swift's own start() catch block), not "fixed": fidelity
            // means preserving this asymmetry, not silently correcting what might be a donor
            // oversight.
            systemChunkCollector.cancelAll()
            try? await persistence.markFailed(handle)
            throw error
        }
        if micVad != nil {
            fputs("[meeting] started with VAD-driven chunk rotation\n", stderr)
        } else {
            fputs("[meeting] VAD not available, using max-duration fallback only\n", stderr)
        }
    }

    func pause() {
        let shouldPause = chunkRotationQueue.sync { () -> Bool in
            guard isRecording, !isPaused else { return false }
            appendFlushedStreamingMicOnQueue()
            rotateChunkOnQueue()
            rotateSystemChunkOnQueue()
            retainedRecordingWriter?.markPauseBoundary()
            neuralAec.resetForStreaming()
            setPausedStateOnQueue(true)
            return true
        }
        guard shouldPause else { return }

        meetingMicRecorder.pause()
        systemAudioRecorder.pause()
        if let meetingHandle {
            Task { try? await persistence.updateState(.paused, for: meetingHandle) }
        }
        fputs("[meeting] recording paused\n", stderr)
    }

    func resume() {
        let shouldResume = chunkRotationQueue.sync { () -> Bool in
            guard isRecording, isPaused else { return false }
            setPausedStateOnQueue(false)
            return true
        }
        guard shouldResume else { return }

        meetingMicRecorder.resume()
        systemAudioRecorder.resume()
        if let meetingHandle {
            Task { try? await persistence.updateState(.recording, for: meetingHandle) }
        }
        fputs("[meeting] recording resumed\n", stderr)
    }

    /// Abandon the recording -- stop everything, delete temp files, don't transcribe.
    ///
    /// `MeetingStore` has no "discarded" `MeetingState` case (only recording/paused/
    /// finalizing/completed/failed -- see that type), and its doc comment scopes `markFailed`
    /// to "an in-process error the engine can detect and react to," which a deliberate user
    /// discard is not. There is no better fit among the five states MeetingStore's PR #8
    /// contract actually offers, so this calls `markFailed` as the closest available terminal
    /// state (closer than `finish`, which implies a completed transcript). Flagged here as a
    /// real gap, not a confident modeling choice: a true "discarded" outcome needs a
    /// MeetingStore capability this stage does not add.
    func discard() {
        let (rawRecorder, systemRecorder) = chunkRotationQueue.sync { () -> (PCMChunkRecorder?, PCMChunkRecorder?) in
            isRecording = false
            setPausedStateOnQueue(false)
            chunkTimingTracker.discard()
            systemChunkTimingTracker.discard()
            let rawRecorder = rawMicChunkRecorder
            let systemRecorder = systemChunkRecorder
            rawMicChunkRecorder = nil
            systemChunkRecorder = nil
            return (rawRecorder, systemRecorder)
        }
        // Same contract as stop(): the queue barrier above drains pending sample callbacks;
        // only then is episode state final.
        micRecoveryCoordinator.finishMeeting()
        stopSystemAudioWatchdog()
        micVad?.stop()
        micVad = nil
        systemVad?.stop()
        systemVad = nil
        retainedRecordingWriter?.cancel()
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil
        rawRecorder?.cancel()
        systemRecorder?.cancel()
        meetingMicRecorder.onRawPCMSamples = nil
        meetingMicRecorder.cancel()
        systemAudioRecorder.onPCMSamples = nil
        if let url = systemAudioRecorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        micChunkCollector.cancelAll()
        systemChunkCollector.cancelAll()
        if let meetingHandle {
            Task { try? await persistence.markFailed(meetingHandle) }
        }
        fputs("[meeting] recording discarded\n", stderr)
    }

    func stop() async throws -> MeetingEngineResult {
        let endTime = Date()
        var micSegments: [SpeechSegment] = []
        var systemSegments: [SpeechSegment] = []

        micVad?.stop()
        micVad = nil
        systemVad?.stop()
        systemVad = nil
        meetingMicRecorder.onRawPCMSamples = nil
        systemAudioRecorder.onPCMSamples = nil

        let (meetingStart, lastChunkTiming, lastRawMicURL, lastSystemChunkTiming, lastSystemChunkURL) = chunkRotationQueue.sync { () -> (Date, MeetingChunkTimingSnapshot?, URL?, MeetingChunkTimingSnapshot?, URL?) in
            isRecording = false
            setPausedStateOnQueue(false)

            // Flush partial AEC frame before stopping chunk recorder
            appendFlushedStreamingMicOnQueue()

            let meetingStart = self.startTime ?? Date()
            let lastRawMicURL = rawMicChunkRecorder?.stop()
            let lastSystemChunkURL = systemChunkRecorder?.stop()
            rawMicChunkRecorder = nil
            systemChunkRecorder = nil
            let lastChunkTiming = chunkTimingTracker.finish()
            let lastSystemChunkTiming = systemChunkTimingTracker.finish()
            return (meetingStart, lastChunkTiming, lastRawMicURL, lastSystemChunkTiming, lastSystemChunkURL)
        }
        // The chunkRotationQueue barrier above guarantees every sample callback enqueued
        // before teardown has been processed and that later callbacks bail on
        // isRecording == false. Only now is the coordinator's episode state final; close any
        // open degradation episode as unrecovered.
        micRecoveryCoordinator.finishMeeting()
        // Cancel the watchdog before stopping the recorder so no late tick can request a
        // rebuild mid-teardown.
        stopSystemAudioWatchdog()
        let rawStreamingMicURL = meetingMicRecorder.stop()
        let retainedRecordingURL = retainedRecordingWriter?.stop()
        retainedRecordingWriter = nil
        defer {
            if let rawStreamingMicURL {
                try? FileManager.default.removeItem(at: rawStreamingMicURL)
            }
        }

        let systemAudioURL = systemAudioRecorder.stop()

        let finalMicSegments = await transcribeMicChunk(
            rawURL: lastRawMicURL,
            chunkTiming: lastChunkTiming,
            isFinalChunk: true
        )
        micSegments.append(contentsOf: finalMicSegments)
        await persistSegments(finalMicSegments, channel: .mic)

        if let lastSystemChunkURL {
            let chunkOffset = lastSystemChunkTiming?.startTimeSeconds ?? 0
            let chunkDuration = lastSystemChunkTiming?.durationSeconds ?? 0
            fputs("[meeting] transcribing final system chunk (offset=\(String(format: "%.0f", chunkOffset))s)\n", stderr)
            do {
                let result = try await transcriptionCoordinator.transcribeMeetingChunk(at: lastSystemChunkURL)
                let normalizedSegments = normalizeSystemTranscription(
                    result: result,
                    startTime: chunkOffset,
                    endTime: chunkOffset + max(chunkDuration, 0.1)
                )
                systemSegments.append(contentsOf: normalizedSegments)
                await persistSegments(normalizedSegments, channel: .system)
            } catch {
                fputs("[meeting] final system chunk transcription failed: \(error)\n", stderr)
            }
            try? FileManager.default.removeItem(at: lastSystemChunkURL)
        }

        var diarizationSegments: [TimedSpeakerSegment]?
        if let systemAudioURL,
           let diarizationResult = try? await transcriptionCoordinator.diarizeSystemAudio(at: systemAudioURL) {
            diarizationSegments = diarizationResult.segments
        }

        micSegments.append(contentsOf: await micChunkCollector.closeAndDrainSortedSegments())
        micSegments.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        systemSegments.append(contentsOf: await systemChunkCollector.closeAndDrainSortedSegments())
        systemSegments.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        // The offline system-segment repair pass (donor `repairSystemSegmentsIfNeeded`,
        // gated by `shouldAttemptSystemRecovery`) is deferred to Stage 2c: it needs
        // `MeetingTranscriptHealthMonitor`/`MeetingMicRepairPlanner`/`AudioConverter`, none of
        // which exist in this fork, and it is meaningless against a stubbed transcription
        // coordinator that never produces real segments to evaluate the health of. See this
        // file's header.

        fputs("[meeting] \(micSegments.count) mic chunks transcribed during meeting\n", stderr)
        fputs("[meeting] \(systemSegments.count) system chunks transcribed during meeting\n", stderr)

        let reconciledTranscriptInputs = TranscriptReconciler.reconcile(
            micTurns: micSegments,
            systemSegments: systemSegments,
            diarizationSegments: diarizationSegments
        )

        let rawTranscript = TranscriptFormatter.merge(
            micSegments: reconciledTranscriptInputs.micSegments,
            systemSegments: reconciledTranscriptInputs.systemSegments,
            diarizationSegments: reconciledTranscriptInputs.diarizationSegments,
            meetingStart: meetingStart
        )

        if let meetingHandle {
            try? await persistence.finish(meetingHandle, endDate: endTime)
        }

        return MeetingEngineResult(
            title: title,
            startTime: meetingStart,
            endTime: endTime,
            durationSeconds: max(endTime.timeIntervalSince(meetingStart), 0),
            rawTranscript: rawTranscript,
            systemRecordingURL: systemAudioURL,
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: retainedRecordingWriterError
        )
    }

    /// Donor `MeetingSession.shouldAttemptSystemRecovery` (`MeetingSession.swift:968-973`),
    /// kept per the seam map's explicit recommendation even though its only donor caller (the
    /// system-segment repair pass) is deferred to Stage 2c: it is dependency-free, and porting
    /// it now means Stage 2c's repair pass does not need to reintroduce it. Always evaluates
    /// `usesUnifiedNemotronTranscript: false` from any current call site in this file, since
    /// unified-Nemotron streaming partials are cut -- kept as a parameter, not hardcoded, so
    /// the function's own tests (ported verbatim below) still cover both branches.
    static func shouldAttemptSystemRecovery(
        usesUnifiedNemotronTranscript: Bool,
        hasSystemSegments: Bool
    ) -> Bool {
        !usesUnifiedNemotronTranscript || !hasSystemSegments
    }

    // MARK: - Persistence

    /// Appends each of `segments` to the persisted meeting as a finalized turn -- NOT waiting
    /// for end-of-meeting cross-stream reconciliation (`TranscriptReconciler.reconcile`, which
    /// runs exactly once, at `stop()`). Waiting for reconciliation would defeat `MeetingStore`'s
    /// entire purpose for a long meeting: nothing would reach disk until the meeting ended, and
    /// a crash at minute 70 would lose everything. `MeetingStore.appendSegment`'s own doc
    /// comment scopes this to "finalized" segments, never "interim/partial ASR results" --
    /// every segment reaching this method already satisfies that, because streaming partials
    /// are cut in this fork: there is no interim/partial result path left to confuse with a
    /// settled one.
    ///
    /// `speakerLabel` is necessarily pre-diarization best-effort here ("You" for mic, "Others"
    /// for system -- the same fallback `TranscriptFormatter` itself uses when no diarization is
    /// available), because diarization only ever runs once, in `stop()`, well after individual
    /// chunks have already been persisted. `MeetingStore`'s public API (PR #8's fixed contract)
    /// has no "update an already-persisted segment's label" operation, so a later diarization
    /// pass cannot retroactively relabel what is already on disk. Disclosed limitation, not
    /// silently accepted: flagged in this port's report.
    private func persistSegments(_ segments: [SpeechSegment], channel: MeetingSegmentChannel) async {
        guard let meetingHandle else { return }
        let speakerLabel = channel == .mic ? "You" : "Others"
        for segment in segments {
            _ = try? await persistence.appendSegment(
                startOffset: segment.start,
                endOffset: segment.end,
                speakerLabel: speakerLabel,
                text: segment.text,
                sourceChannel: channel,
                to: meetingHandle
            )
        }
        guard let startTime else { return }
        try? await persistence.updateDuration(durationSeconds(from: startTime, to: Date()), for: meetingHandle)
    }

    private func durationSeconds(from start: Date, to end: Date) -> Double {
        max(end.timeIntervalSince(start), 0)
    }

    // MARK: - Chunk rotation

    private func appendFlushedStreamingMicOnQueue() {
        let flushed = neuralAec.flushStreamingMic()
        if let micVad {
            // Route through the facade for consistency with the realtime path, even though
            // this specific call never drives the wrapped VAD controller (see
            // MeetingVadStreams.swift's `acceptFlushed(_:)` doc comment).
            appendCleanedMicSamplesOnQueue(micVad.acceptFlushed(flushed).samples)
        } else {
            appendCleanedMicSamplesOnQueue(flushed)
        }
    }

    /// Called by VAD on speech boundaries or max-duration fallback. Rotates the streaming mic
    /// file and sends the completed chunk for transcription.
    private func rotateChunkOnQueue() {
        guard isRecording, !isPaused else { return }
        appendFlushedStreamingMicOnQueue()
        guard let chunkTiming = chunkTimingTracker.rotate() else {
            return
        }
        let rawChunkURL = rawMicChunkRecorder?.rotateFile()

        guard rawChunkURL != nil else {
            return
        }

        let chunkOffset = chunkTiming.startTimeSeconds

        fputs("[meeting] rotating raw mic chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)
        let task = Task { [weak self] () -> [SpeechSegment] in
            guard let self else { return [] }
            if Task.isCancelled {
                self.cleanupTemporaryChunkURLs(rawChunkURL)
                return []
            }
            return await self.transcribeMicChunk(
                rawURL: rawChunkURL,
                chunkTiming: chunkTiming,
                isFinalChunk: false
            )
        }
        let (registered, retireID) = micChunkCollector.add(task)
        if registered {
            Task { [weak self] in
                let segments = await task.value
                guard let self else { return }
                guard self.micChunkCollector.retire(id: retireID, segments: segments) else { return }
                await self.persistSegments(segments, channel: .mic)
                guard !segments.isEmpty else { return }
                self.onChunkTranscribed?(segments, "You")
            }
        } else {
            task.cancel()
            cleanupTemporaryChunkURLs(rawChunkURL)
        }
    }

    private func rotateSystemChunkOnQueue() {
        guard isRecording, !isPaused else { return }
        guard let chunkURL = systemChunkRecorder?.rotateFile(),
              let chunkTiming = systemChunkTimingTracker.rotate() else {
            return
        }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkDuration = chunkTiming.durationSeconds
        fputs("[meeting] rotating system chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)
        let task = Task { [weak self] () -> [SpeechSegment] in
            defer {
                try? FileManager.default.removeItem(at: chunkURL)
            }
            guard let self else { return [] }
            do {
                if Task.isCancelled {
                    return []
                }
                let result = try await self.transcriptionCoordinator.transcribeMeetingChunk(at: chunkURL)
                if !result.text.isEmpty {
                    fputs("[meeting] system chunk transcribed: \"\(String(result.text.prefix(60)))...\"\n", stderr)
                    return self.normalizeSystemTranscription(
                        result: result,
                        startTime: chunkOffset,
                        endTime: chunkOffset + max(chunkDuration, 0.1)
                    )
                }
            } catch {
                fputs("[meeting] system chunk transcription failed: \(error)\n", stderr)
            }
            return []
        }
        let (registered, retireID) = systemChunkCollector.add(task)
        if registered {
            Task { [weak self] in
                let segments = await task.value
                guard let self else { return }
                guard self.systemChunkCollector.retire(id: retireID, segments: segments) else { return }
                await self.persistSegments(segments, channel: .system)
                guard !segments.isEmpty else { return }
                self.onChunkTranscribed?(segments, "Others")
            }
        } else {
            task.cancel()
        }
    }

    private func startSystemAudioWatchdog() {
        // Only heartbeat-capable backends can be stall-monitored: the SCK fallback reports
        // heartbeat 0 permanently and would false-fire degraded episodes every meeting.
        guard systemAudioRecorder.supportsHeartbeatMonitoring else { return }
        stopSystemAudioWatchdogTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.hainesy.voiceinkmeetings.meeting-engine.system-audio-watchdog"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak systemAudioWatchdog] in
            systemAudioWatchdog?.tick()
        }
        systemAudioWatchdogTimer = timer
        timer.resume()
    }

    /// Cancel the tick timer (no late rebuilds mid-teardown) and terminalize any open tap
    /// episode. Safe to call from stop() and discard().
    private func stopSystemAudioWatchdog() {
        stopSystemAudioWatchdogTimer()
        systemAudioWatchdog.finishMeeting()
    }

    private func stopSystemAudioWatchdogTimer() {
        systemAudioWatchdogTimer?.cancel()
        systemAudioWatchdogTimer = nil
    }

    private func setupRetainedRecordingWriterIfNeeded() {
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil

        guard retainRecording else { return }

        do {
            retainedRecordingWriter = try MeetingRecordingWriter()
        } catch {
            retainedRecordingWriterError = error
            fputs("[meeting] failed to prepare retained recording writer: \(error)\n", stderr)
        }
    }

    private func prepareRealtimeAudioPipeline(vadManager: VadManager?) throws {
        rawMicChunkRecorder = try PCMChunkRecorder(directoryName: MeetingRuntimePaths.micChunkDirectoryName)
        systemChunkRecorder = try PCMChunkRecorder(directoryName: MeetingRuntimePaths.systemChunkDirectoryName)
        configureRealtimeAudioCallbacks(vadManager: vadManager)
    }

    private func configureRealtimeAudioCallbacks(vadManager: VadManager?) {
        if let vadManager {
            let mic = MicVadStream(vadManager: vadManager, echoCanceller: neuralAec)
            mic.onChunkBoundary = { [weak self] in
                // Streaming VAD callbacks can arrive off-main; serialize chunk rotation explicitly.
                self?.chunkRotationQueue.async { [weak self] in
                    self?.rotateChunkOnQueue()
                }
            }
            mic.start()
            micVad = mic

            let system = SystemVadStream(vadManager: vadManager)
            system.onChunkBoundary = { [weak self] in
                self?.chunkRotationQueue.async { [weak self] in
                    self?.rotateSystemChunkOnQueue()
                }
            }
            system.start()
            systemVad = system
        } else {
            micVad = nil
            systemVad = nil
        }
        neuralAec.resetForStreaming()
        meetingMicRecorder.onRawPCMSamples = { [weak self] samples in
            self?.enqueueRealtimeMicSamples(samples)
        }
        systemAudioRecorder.onPCMSamples = { [weak self] samples in
            self?.enqueueRealtimeSystemSamples(samples)
        }
    }

    private func enqueueRealtimeMicSamples(_ rawSamples: [Int16]) {
        guard !rawSamples.isEmpty else { return }

        chunkRotationQueue.async { [weak self] in
            guard let self, self.isRecording, !self.isPaused else { return }

            let healthSnapshot = self.micHealthTracker.noteRawMicSamples(rawSamples)
            self.onMicHealthChanged?(healthSnapshot)
            self.micRecoveryCoordinator.process(healthSnapshot)
            self.retainedRecordingWriter?.appendMic(rawSamples)

            let floatSamples = rawSamples.map { Float($0) / 32767.0 }

            // Meeting mic chunks must be driven by the cleaned mic stream. Raw mic VAD sees
            // speaker playback bleed and can create false `You` chunks even when AEC removed
            // that speech from the final mic audio (ADAPTER-HANDOVER.md section 1).
            if let micVad = self.micVad {
                let cleaned = micVad.process(RawMicSamples(floatSamples))
                self.appendCleanedMicSamplesOnQueue(cleaned.samples)
            } else {
                // No VAD manager this session (see start()'s log line). There is no mic VAD to
                // protect from raw audio in this branch -- MeetingVadStreams.swift's facade
                // boundary is specifically about the mic VAD, which does not exist here -- so
                // calling the canceller directly, exactly as the donor's unconditional
                // `neuralAec.processStreamingMic` call does, does not bypass anything.
                let cleaned = self.neuralAec.processStreamingMic(floatSamples)
                self.appendCleanedMicSamplesOnQueue(cleaned)
            }
        }
    }

    private func enqueueRealtimeSystemSamples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }

        chunkRotationQueue.async { [weak self] in
            guard let self, self.isRecording, !self.isPaused else { return }

            let healthSnapshot = self.micHealthTracker.noteSystemSamples(samples)
            self.onMicHealthChanged?(healthSnapshot)
            self.micRecoveryCoordinator.process(healthSnapshot)
            self.retainedRecordingWriter?.appendSystem(samples)
            self.systemChunkRecorder?.append(samples)
            self.systemChunkTimingTracker.append(sampleCount: samples.count)

            let floatSamples = samples.map { Float($0) / 32767.0 }

            if let micVad = self.micVad {
                let drained = micVad.processFarEndReference(RawSystemSamples(floatSamples))
                self.appendCleanedMicSamplesOnQueue(drained.samples)
            } else {
                self.neuralAec.feedSystemSamples(floatSamples)
                self.appendCleanedMicSamplesOnQueue(self.neuralAec.processStreamingMic([]))
            }

            if let systemVad = self.systemVad {
                systemVad.process(RawSystemSamples(floatSamples))
            }
        }
    }

    private func appendCleanedMicSamplesOnQueue(_ cleanedFloat: [Float]) {
        guard !cleanedFloat.isEmpty else { return }
        let cleanedInt16 = cleanedFloat.map { sample -> Int16 in
            Int16(max(-1.0, min(1.0, sample)) * 32767)
        }
        rawMicChunkRecorder?.append(cleanedInt16)
        chunkTimingTracker.append(sampleCount: cleanedInt16.count)
    }

    private func transcribeMicChunk(
        rawURL: URL?,
        chunkTiming: MeetingChunkTimingSnapshot?,
        isFinalChunk: Bool
    ) async -> [SpeechSegment] {
        defer {
            cleanupTemporaryChunkURLs(rawURL)
        }

        guard let chunkTiming, let rawURL else { return [] }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkDuration = chunkTiming.durationSeconds
        let logPrefix = isFinalChunk ? "[meeting] transcribing final mic chunk" : "[meeting] transcribing mic chunk"

        return await transcribeMicChunk(
            at: rawURL,
            chunkOffset: chunkOffset,
            chunkDuration: chunkDuration,
            logPrefix: logPrefix
        ) ?? []
    }

    private func transcribeMicChunk(
        at url: URL,
        chunkOffset: TimeInterval,
        chunkDuration: TimeInterval,
        logPrefix: String
    ) async -> [SpeechSegment]? {
        fputs("\(logPrefix) (offset=\(String(format: "%.0f", chunkOffset))s, source=raw)\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeetingChunk(at: url)
            guard !result.text.isEmpty else { return [] }
            fputs("[meeting] mic chunk transcribed (raw): \"\(String(result.text.prefix(60)))...\"\n", stderr)
            return MicTurnNormalizer.normalize(
                result: result,
                startTime: chunkOffset,
                endTime: chunkOffset + max(chunkDuration, 0.1)
            )
        } catch {
            fputs("[meeting] mic chunk transcription failed (raw): \(error)\n", stderr)
            return nil
        }
    }

    private func cleanupTemporaryChunkURLs(_ urls: URL?...) {
        urls.compactMap { $0 }.forEach { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func normalizeSystemTranscription(
        result: SpeechTranscriptionResult,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> [SpeechSegment] {
        SystemTurnNormalizer.normalize(
            result: result,
            startTime: startTime,
            endTime: endTime
        )
    }
}

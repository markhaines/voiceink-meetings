// Fork-owned (no donor equivalent). Not a port.
//
// FOLLOWUPS.md's WIRING GATE, item 1: "Real-audio / real-model smoke testing of all three
// adapters". Every other test under Features/Meetings/Transcription/ exercises
// `FluidAudioMeetingSegmentTranscriber` / `FluidAudioMeetingDiarizer` / `MeetingTranscriptionCoordinator`
// against fakes (`FakeSegmentTranscriber`, injected loaders, etc.) -- correctly, for what those
// files are proving. This file is the one place that constructs the REAL FluidAudio runtime
// (a real `FluidAudioTranscriptionService` loading a real Parakeet v3 CoreML model, a real
// `FluidAudioMeetingDiarizer` loading a real `DiarizerManager`) and drives it through this fork's
// own seam -- `MeetingTranscriptionCoordinator.transcribeMeetingChunk`, never FluidAudio's
// `AsrManager`/`DiarizerManager` called directly -- against real audio.
//
// GATED THE WAY THIS REPO ALREADY GATES HARDWARE TESTS. `isRunningInCI` below is the exact same
// idiom `AudioGraphExceptionBridgeTests.swift` uses (`VOICEINK_CI`, set by
// `.github/workflows/ci.yml`'s "Run test targets" step via the `TEST_RUNNER_` prefix xcodebuild
// forwards) -- reused verbatim rather than reinvented, because CI has neither the downloaded
// models nor real audio hardware and would hang or fail trying to use either.
//
// ON TOP OF THAT CI GATE, every test here also checks its OWN real-world prerequisite (a
// downloaded Parakeet v3 model, one of Mark's own dictation recordings, a cached or
// network-downloadable diarizer model) and disables itself with a specific message when that
// prerequisite is absent. This is a CONVENIENCE for ordinary developer/CI runs, stated exactly
// rather than oversold: a machine with `VOICEINK_CI` unset but no models/audio present (a fresh
// clone, a CI runner someone points a debugger at) skips cleanly with a reason instead of hanging
// on a missing model file -- but skipping still produces a GREEN, PASSING suite with nothing
// exercised, same as any other disabled test. That is correct and desired for those ordinary
// runs. It is NOT, by itself, a guarantee that the gate has actually run.
//
// GATE-RUNNING MODE closes that gap. THE COMMAND TO RUN, copy it exactly -- this is the ONLY
// form that actually engages gate mode from outside the test process:
//
//     TEST_RUNNER_REALMODEL_SMOKE_GATE_MODE=1 xcodebuild test \
//       -project VoiceInk.xcodeproj -scheme VoiceInk -destination 'platform=macOS' \
//       -only-testing:VoiceInkTests/RealModelSmokeTests
//
// TWO DIFFERENT NAMES, ON PURPOSE, and getting this wrong silently defeats the whole mechanism
// (see below): `TEST_RUNNER_REALMODEL_SMOKE_GATE_MODE` is the EXTERNAL environment variable you
// set on the `xcodebuild` invocation above. `xcodebuild test` launches the actual test host
// through a LaunchServices-mediated path that does not inherit that shell's environment at all
// -- except for variables prefixed `TEST_RUNNER_`, which it forwards into the test host process
// WITH THE PREFIX STRIPPED (the same mechanism `VOICEINK_CI`/`TEST_RUNNER_VOICEINK_CI` already
// uses; see that pair's own comment below and FORK-PATCHES.md's "phase-1-mic-route" section for
// where this was first proven). `REALMODEL_SMOKE_GATE_MODE` (no `TEST_RUNNER_` prefix) is the
// UNPREFIXED name `isGateRunningMode` below reads via `ProcessInfo.processInfo.environment`
// INSIDE that already-launched test process -- it is not something an external caller sets
// directly. Setting the unprefixed form on `xcodebuild`'s own invocation
// (`REALMODEL_SMOKE_GATE_MODE=1 xcodebuild test ...`) does NOTHING: it never crosses the
// LaunchServices boundary, `isGateRunningMode` reads `nil` inside the test host exactly as if
// gate mode were never requested, a missing prerequisite quietly SKIPS, and the run reports
// green -- the exact false assurance this mechanism exists to prevent, reintroduced by a reader
// following an unprefixed instruction. `RealModelSmokeTests` is only one entry in a repo-wide
// list of these flags; FOLLOWUPS.md's "Gate-running modes" section is the one place that lists
// every `<GATE>_GATE_MODE` flag in its correct external, `TEST_RUNNER_`-prefixed form, with a
// single copyable command that runs all of them together -- check there before adding another.
//
// What gate mode DOES guarantee, once engaged with the command above: with
// `TEST_RUNNER_REALMODEL_SMOKE_GATE_MODE=1` set on the `xcodebuild` invocation, this suite
// passing means both tests actually executed their real model-load/inference path end to end --
// a missing prerequisite fails the run instead of skipping it, and that now includes the
// `VOICEINK_CI` check: GATE MODE OVERRIDES THE CI SKIP, on CI or anywhere else.
//
// An earlier version of this file disabled both tests unconditionally whenever `VOICEINK_CI` was
// set, gate mode or not, on the reasoning that CI has no downloaded models and no real audio
// hardware, so forcing these tests to run there would fail for an unrelated, uninteresting reason
// rather than prove anything about the gate. That reasoning is now superseded, and its strongest
// point deserves an answer, not a silent deletion: a gate-mode failure on a runner with no models
// is NOT an unrelated failure -- it is exactly the information an operator who explicitly set
// `TEST_RUNNER_REALMODEL_SMOKE_GATE_MODE=1` asked for. The entire purpose of gate mode is that a
// pass means the real path ran and a missing prerequisite fails loudly; an environment variable a
// caller may not know about -- whether it happens to be CI or anything else -- must never be able
// to silently downgrade an explicitly requested gate into a skip, or the guarantee becomes
// conditional in exactly the false-assurance way this mechanism exists to eliminate. Nobody sets
// gate mode on a CI runner by accident; if they do, a loud failure beats a silent green.
//
// MAKING THAT FAILURE SELF-EXPLANATORY -- CORRECTLY, THIS TIME. An earlier round of this fix put
// the explanation (naming the missing prerequisite and the CI environment) into the three
// `.disabled(if: ..., "...")` SKIP messages above and claimed a gate-mode failure would carry it.
// That was wrong, and the reasoning error is worth stating precisely: `!isGateRunningMode` is
// ANDed into every one of those `.disabled` conditions, so gate mode is EXACTLY the thing that
// stops them from firing -- the skip messages exist only in the branch gate mode is designed to
// never take. Proven empirically: with the Parakeet v3 model deliberately absent and gate mode
// engaged, the real failure text was FluidAudio's own generic library error --
// `Caught error: .loadingFailed("Parakeet model files are incomplete. Download the model from AI
// Models.")` -- naming neither the CI environment nor this file's own diagnosis, because the code
// path that ran was the ordinary real-model-load path, which has no reason to know about CI or
// gate mode at all. Fixed properly this time: each test body below now re-checks its own
// prerequisite explicitly, under `if isGateRunningMode { ... }`, BEFORE touching any real
// FluidAudio/diarizer work, and throws `GateModePrerequisiteMissing` (see below) with a message
// naming the specific missing prerequisite and, when `isRunningInCI` is also true, stating
// plainly that `VOICEINK_CI` identifies this environment as a CI runner with no downloaded models
// or real audio hardware by design -- so a reader of a red CI run understands "this runner cannot
// satisfy this gate," not "the product is broken." Because this check only fires when the
// prerequisite is ACTUALLY missing, it never masks a genuine failure in the real load/inference
// path on a machine where the prerequisite is present.
//
// What gate mode still does NOT guarantee: anything on an ordinary run where gate mode is NOT
// engaged (including every CI run and every plain local `xcodebuild test`) -- a missing
// prerequisite there still produces a quiet skip and a green suite, which remains correct,
// desired convenience behavior, not a new guarantee.
//
// AUDIO PROVENANCE, stated plainly:
//   - The transcription test uses ONE of Mark's own real dictation recordings, found under
//     `~/Library/Application Support/com.prakashjoshipax.VoiceInk/Recordings/` -- real speech,
//     captured by his daily-driver VoiceInk install, at whatever sample rate that app recorded
//     at. The ORIGINAL is only ever opened for reading (`AVAudioFile(forReading:)`,
//     `FileManager.copyItem(at:to:)`'s source side); every test operates on a copy in a scratch
//     temp file, and the original is never moved or written to.
//   - The diarizer test cannot reuse that audio: it is single-speaker mic dictation, not the
//     multi-speaker system-audio shape `FluidAudioMeetingDiarizer` exists for, and no real
//     multi-speaker system-audio recording exists on this machine. It SYNTHESIZES one instead,
//     using two distinct macOS `say` voices reading different sentences back to back. That is a
//     genuine limitation, disclosed rather than hidden: this proves the diarizer's real
//     load/run path executes end to end and produces a real `DiarizationResult` against real
//     CoreML models, NOT that its diarization accuracy has been validated against a real
//     multi-speaker recording -- deliverable 3 in the task that produced this file says exactly
//     that trade is acceptable when real multi-speaker audio does not exist.
//
// WHAT THIS FILE DELIBERATELY DOES NOT DO: construct `MeetingEngine`, touch
// `NullMeetingTranscriptionCoordinator`, or reach into any app composition root. It builds a
// `MeetingTranscriptionCoordinator` directly, the same way a future composition root eventually
// will, entirely inside test scope -- see FOLLOWUPS.md's WIRING GATE header for why nothing does
// that in production yet.

import AVFoundation
import Darwin
import FluidAudio
import Foundation
import Testing
@testable import VoiceInk

/// Same idiom as `AudioGraphExceptionBridgeTests.isRunningInCI` (see that file's header for the
/// full mechanism). Not reinvented: FOLLOWUPS.md gate item 1 explicitly asks for the existing
/// idiom to be reused rather than a second one invented.
private var isRunningInCI: Bool {
    ProcessInfo.processInfo.environment["VOICEINK_CI"] != nil
}

/// See this file's header, "GATE-RUNNING MODE", for the full mechanism and the canonical command.
/// When set, a missing prerequisite is no longer grounds to skip -- the test runs anyway and
/// fails for real if the prerequisite truly is not met. This OVERRIDES the `isRunningInCI` skip
/// too: both `.disabled` traits below read `isRunningInCI && !isGateRunningMode`, so gate mode
/// makes the test actually run instead of skip, on CI or anywhere else. The self-explanatory
/// naming of the missing prerequisite does NOT come from those `.disabled` traits, which gate
/// mode causes to never fire -- see the file header's "MAKING THAT FAILURE SELF-EXPLANATORY"
/// section and `GateModePrerequisiteMissing` below for where that explanation actually lives.
///
/// READ THIS BEFORE SETTING ANYTHING: the string below, `REALMODEL_SMOKE_GATE_MODE`, is the
/// UNPREFIXED name this already-launched test process reads its own environment for -- it is
/// NOT what an external caller sets. Engaging this from outside requires the EXTERNAL,
/// `TEST_RUNNER_`-prefixed form on the `xcodebuild` invocation instead:
/// `TEST_RUNNER_REALMODEL_SMOKE_GATE_MODE=1 xcodebuild test ...` -- xcodebuild strips the
/// `TEST_RUNNER_` prefix when it forwards a variable into the test host, which is the ONLY way
/// anything set on the outer `xcodebuild` command reaches this `ProcessInfo` lookup at all.
private var isGateRunningMode: Bool {
    ProcessInfo.processInfo.environment["REALMODEL_SMOKE_GATE_MODE"] != nil
}

/// Pulled out to a plain constant, not built inline with `+` inside the `@Test` attribute:
/// string concatenation directly inside a macro's argument list made the type checker time out
/// ("unable to type-check this expression in reasonable time"). A single string literal referenced
/// by name type-checks trivially.
private let transcriptionSkippedOnCIMessage: String = """
    hardware/model test skipped on CI (no Parakeet v3 model, no audio hardware) -- see \
    AudioGraphExceptionBridgeTests.swift for the same VOICEINK_CI idiom; set \
    TEST_RUNNER_REALMODEL_SMOKE_GATE_MODE=1 to force this to run and fail loudly here instead \
    of skipping
    """

private let diarizerSkippedOnCIMessage: String = """
    hardware/model test skipped on CI (no diarizer model, no audio hardware) -- see \
    AudioGraphExceptionBridgeTests.swift for the same VOICEINK_CI idiom; set \
    TEST_RUNNER_REALMODEL_SMOKE_GATE_MODE=1 to force this to run and fail loudly here instead \
    of skipping
    """

/// Appended to a gate-mode prerequisite-failure message when `isRunningInCI` is also true, so a
/// reader of a red CI run is told plainly that this environment cannot satisfy the gate rather
/// than mistaking the failure for a product defect. Empty on a non-CI machine: there, a missing
/// prerequisite failing under gate mode needs no CI-specific caveat.
private var ciEnvironmentNote: String {
    guard isRunningInCI else { return "" }
    return """
         VOICEINK_CI is set, identifying this environment as a CI runner: CI has no downloaded \
        models and no real audio hardware by design, so this failure here is expected -- it means \
        this runner cannot satisfy this gate, not that the product is broken.
        """
}

/// Thrown by the explicit gate-mode prerequisite checks at the top of each test body below. The
/// `.disabled(if: ..., "...")` SKIP messages above cannot do this job: `!isGateRunningMode` is
/// ANDed into every one of those conditions, so gate mode is precisely what makes them never
/// fire, and the skip text they carry is never displayed on a gate-mode run. This type exists so
/// gate mode's own failure -- not a `.disabled` trait -- carries the explanation instead. See the
/// file header's "MAKING THAT FAILURE SELF-EXPLANATORY" section for the full story of why the
/// first attempt at this put the explanation in the wrong place.
private struct GateModePrerequisiteMissing: Error, CustomStringConvertible {
    let description: String
}

private var transcriptionModelMissingGateFailureMessage: String {
    "GATE MODE forced this test to run despite a missing prerequisite: no local Parakeet v3 "
        + "model at \(AsrModels.defaultCacheDirectory(for: .v3).path)."
        + ciEnvironmentNote
}

private var transcriptionAudioMissingGateFailureMessage: String {
    "GATE MODE forced this test to run despite a missing prerequisite: no usable 8-20s "
        + "recording found under \(RealAudioFixture.recordingsDirectory.path)."
        + ciEnvironmentNote
}

private var diarizerModelMissingGateFailureMessage: String {
    "GATE MODE forced this test to run despite a missing prerequisite: diarizer model not "
        + "already cached locally and huggingface.co is unreachable -- cannot run this test for "
        + "real."
        + ciEnvironmentNote
}

private struct UnexpectedFallbackInvoked: Error {}

/// Swift Testing's `print()` output from a real `xcodebuild test` invocation is not reliably
/// visible in the plain-text build log this task's report is generated from (verified empirically
/// while building this file: `Test Case ... passed` lines appear, raw `print()` lines do not).
/// Every real measurement this file produces is therefore ALSO appended to a plain file, so the
/// numbers can be read back directly rather than screen-scraped from a log format that dropped
/// them once already. `print()` is kept too, for anyone reading Xcode's own test log.
///
/// Every line carries a per-process `runID` so a number can always be traced to the run that
/// produced it, even when two parallel test workers (Swift Testing's default) or two separate
/// `xcodebuild test` invocations append to the same path -- this file was previously reviewed for
/// exactly that hazard: a fixed path with no run identifier lets stale or concurrent-worker
/// measurements mix silently. Appends via a raw `open(..., O_APPEND)` file descriptor rather than
/// `FileHandle.seekToEndOfFile()` + `write()`, because the latter is two syscalls with a race
/// window between them across processes; `O_APPEND` makes each `write()` atomic at the point the
/// kernel assigns it a file offset, which is what actually prevents interleaved/torn lines from
/// two workers writing at once.
private enum MetricsSink {
    static let path =
        ProcessInfo.processInfo.environment["REALMODEL_SMOKE_METRICS_PATH"]
        ?? "/tmp/voiceink-meetings-realmodel-smoke-metrics.log"

    /// Process id + a short random suffix: unique per test-worker process, stable for every line
    /// that process writes, so grepping one run's lines out of a shared file is a one-line filter.
    private static let runID = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))"

    static func record(_ line: String) {
        let full = "[run=\(runID)] \(line)"
        print(full)
        guard let data = (full + "\n").data(using: .utf8) else { return }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, raw.count)
        }
        close(fd)
    }
}

private extension Duration {
    var secondsDouble: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// Whether the real Parakeet v3 model this test needs is actually present on disk -- premise (a)
/// from the task that produced this file, checked with FluidAudio's own `AsrModels.modelsExist`
/// rather than a hand-rolled file check, so this test agrees with the runtime about what "present"
/// means.
private enum RealModelAvailability {
    static var parakeetV3Present: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    /// Whether the diarizer's own required model files (`ModelNames.Diarizer.requiredModels`:
    /// `pyannote_segmentation.mlmodelc`, `wespeaker_v2.mlmodelc`) are already present under
    /// FluidAudio's own cache directory for the diarizer repo. FluidAudio has no
    /// `AsrModels.modelsExist`-equivalent helper for the diarizer, so this checks the same files
    /// `DiarizerModels.download` itself looks for, at the same path
    /// (`DiarizerModels.defaultModelsDirectory()`), rather than inventing a different notion of
    /// "present". When true, `FluidAudioMeetingDiarizer()`'s production init loads from disk and
    /// needs no network at all -- see the diarizer test's gating below, which only requires
    /// network reachability when a download would actually be necessary.
    static var diarizerModelsPresent: Bool {
        let directory = DiarizerModels.defaultModelsDirectory()
        let fm = FileManager.default
        return ModelNames.Diarizer.requiredModels.allSatisfy { modelFileName in
            fm.fileExists(atPath: directory.appendingPathComponent(modelFileName).path)
        }
    }
}

private enum RealAudioFixtureError: Error {
    case noRecordingAvailable
    case bufferAllocationFailed
    case sayFailed(status: Int32)
}

/// Sources one real recording from Mark's own daily-driver VoiceInk install and hands out
/// read-only-derived copies for testing. See this file's header for the full provenance
/// disclosure.
private enum RealAudioFixture {
    static let recordingsDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(
            "Library/Application Support/com.prakashjoshipax.VoiceInk/Recordings",
            isDirectory: true
        )

    static var isAvailable: Bool {
        sourceRecording() != nil
    }

    /// Deterministic pick (sorted by filename, first match wins) so repeated runs exercise the
    /// same recording: the first real dictation recording between 8 and 20 seconds -- long enough
    /// for a genuine multi-sentence transcript, short enough to keep this smoke test's own
    /// runtime bounded. Read-only: `AVAudioFile(forReading:)` never writes.
    static func sourceRecording() -> URL? {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: recordingsDirectory, includingPropertiesForKeys: nil
            )
        else {
            return nil
        }
        let wavs = entries
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in wavs {
            guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0
            else { continue }
            let duration = Double(file.length) / file.processingFormat.sampleRate
            if duration >= 8, duration <= 20 {
                return url
            }
        }
        return nil
    }

    /// Copies the chosen recording into a scratch temp file. The source in Mark's Recordings
    /// directory is opened for reading only by both `sourceRecording()` above and by
    /// `FileManager.copyItem`'s source side; this never moves or writes to it.
    static func copyForTesting() throws -> URL {
        guard let source = sourceRecording() else {
            throw RealAudioFixtureError.noRecordingAvailable
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-meetings-realmodel-smoke-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Extracts a `durationSeconds`-long slice starting at `startSeconds` into its own file, for
    /// the representative-chunk latency measurement (gate item 1's second deliverable).
    static func extractChunk(from source: URL, startSeconds: Double, durationSeconds: Double) throws -> URL {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        input.framePosition = AVAudioFramePosition(startSeconds * format.sampleRate)
        let frameCount = AVAudioFrameCount(durationSeconds * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw RealAudioFixtureError.bufferAllocationFailed
        }
        try input.read(into: buffer, frameCount: frameCount)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-meetings-realmodel-smoke-chunk-\(UUID().uuidString).wav")
        let output = try AVAudioFile(forWriting: destination, settings: input.fileFormat.settings)
        try output.write(from: buffer)
        return destination
    }
}

/// Two macOS `say` voices reading different sentences back to back, concatenated into one file.
/// NOT real speech -- see this file's header. Exists only because no real multi-speaker
/// system-audio recording exists on this machine to exercise `FluidAudioMeetingDiarizer`'s real
/// load/run path against.
private enum SyntheticMultiSpeakerAudio {
    static func make() throws -> URL {
        let voice1 = try synthesize(
            text: "This is speaker one talking about the quarterly numbers.", voice: "Samantha"
        )
        let voice2 = try synthesize(
            text: "And this is speaker two responding with a different opinion entirely.",
            voice: "Alex"
        )
        defer {
            try? FileManager.default.removeItem(at: voice1)
            try? FileManager.default.removeItem(at: voice2)
        }
        return try concatenate([voice1, voice2])
    }

    private static func synthesize(text: String, voice: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-meetings-realmodel-smoke-say-\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", destination.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RealAudioFixtureError.sayFailed(status: process.terminationStatus)
        }
        return destination
    }

    private static func concatenate(_ sources: [URL]) throws -> URL {
        var buffers: [AVAudioPCMBuffer] = []
        var format: AVAudioFormat?
        for source in sources {
            let file = try AVAudioFile(forReading: source)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
                )
            else {
                throw RealAudioFixtureError.bufferAllocationFailed
            }
            try file.read(into: buffer)
            buffers.append(buffer)
            format = file.processingFormat
        }
        guard let format else { throw RealAudioFixtureError.bufferAllocationFailed }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-meetings-realmodel-smoke-multispeaker-\(UUID().uuidString).aiff")
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        for buffer in buffers {
            try output.write(from: buffer)
        }
        return destination
    }
}

/// Whether `huggingface.co` is reachable, checked with a short, bounded HEAD request rather than
/// assumed. Only consulted by the diarizer test's gate when
/// `RealModelAvailability.diarizerModelsPresent` is false: if the diarizer's real model
/// (`FluidInference/speaker-diarization-coreml`) is ALREADY cached under FluidAudio's own
/// Application-Support directory, `FluidAudioMeetingDiarizer`'s production `DiarizerModels.load()`
/// path loads it from disk and needs no network at all, so this test must not demand
/// reachability in that case. Network is required only when a download would actually happen.
private enum NetworkProbe {
    static var huggingFaceReachable: Bool {
        var reachable = false
        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(url: URL(string: "https://huggingface.co")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                reachable = true
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 6)
        return reachable
    }
}

/// Samples this process's resident set size on a background poll while real model
/// load/inference runs, and reports the peak. A plain locked class rather than an actor: the
/// poll loop and `stopPolling()` both need synchronous access, and there is no async work to
/// isolate here beyond the poll's own sleep.
private final class RSSPeakTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var peakBytes: UInt64
    private var pollTask: Task<Void, Never>?

    init() {
        peakBytes = Self.currentResidentBytes()
    }

    func startPolling() {
        pollTask = Task.detached { [weak self] in
            while let self, !Task.isCancelled {
                self.record(Self.currentResidentBytes())
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    @discardableResult
    func stopPolling() -> UInt64 {
        pollTask?.cancel()
        pollTask = nil
        lock.lock()
        defer { lock.unlock() }
        return peakBytes
    }

    private func record(_ value: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if value > peakBytes { peakBytes = value }
    }

    private static func currentResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

@Suite("Real-model / real-audio smoke tests (FOLLOWUPS.md WIRING GATE item 1)", .serialized)
struct RealModelSmokeTests {

    @Test(
        "real Parakeet v3 loads and transcribes real dictation audio through MeetingTranscriptionCoordinator",
        .disabled(if: isRunningInCI && !isGateRunningMode, "\(transcriptionSkippedOnCIMessage)"),
        .disabled(
            if: !RealModelAvailability.parakeetV3Present && !isGateRunningMode,
            "no local Parakeet v3 model at \(AsrModels.defaultCacheDirectory(for: .v3).path)"
        ),
        .disabled(
            if: !RealAudioFixture.isAvailable && !isGateRunningMode,
            "no usable 8-20s recording found under \(RealAudioFixture.recordingsDirectory.path)"
        )
    )
    func realModelTranscribesRealAudio() async throws {
        // Gate mode bypasses the `.disabled` traits above entirely, including their skip
        // messages -- so if either prerequisite is genuinely still missing, check it again here,
        // explicitly, before touching any real FluidAudio path, and fail with a message that
        // names it (plus the CI environment, when applicable) instead of letting the run fall
        // through to FluidAudio's own generic, unrelated-sounding error text.
        if isGateRunningMode {
            if !RealModelAvailability.parakeetV3Present {
                throw GateModePrerequisiteMissing(description: transcriptionModelMissingGateFailureMessage)
            }
            if !RealAudioFixture.isAvailable {
                throw GateModePrerequisiteMissing(description: transcriptionAudioMissingGateFailureMessage)
            }
        }

        let recording = try RealAudioFixture.copyForTesting()
        defer { try? FileManager.default.removeItem(at: recording) }
        let chunk = try RealAudioFixture.extractChunk(from: recording, startSeconds: 3, durationSeconds: 4)
        defer { try? FileManager.default.removeItem(at: chunk) }

        let rss = RSSPeakTracker()
        rss.startPolling()
        defer { rss.stopPolling() }

        let service = FluidAudioTranscriptionService()
        let model = FluidAudioModel(
            name: "parakeet-tdt-0.6b-v3",
            displayName: "Parakeet V3",
            description: "GATE ITEM 1 smoke test",
            size: "494 MB",
            speed: 0.99,
            accuracy: 0.94,
            ramUsage: 0.8,
            supportedLanguages: ["en": "English"]
        )

        // Deliverable 2: real model-load time for the first load in THIS TEST PROCESS. Named
        // `first-load-in-process-seconds`, not `cold-...`: this test does not verify or control
        // the state of macOS's own CoreML/ANE compilation cache, which persists across process
        // launches and can make a "first load in this process" dramatically faster than a
        // genuinely never-before-loaded state on this Mac would be (see FOLLOWUPS.md's GATE ITEM
        // 1 section for the measured difference and why no ratio is claimed between them). The
        // model files are already downloaded on disk (premise (a)), so this never includes a
        // network download either way.
        let loadStart = ContinuousClock.now
        try await service.loadModel(for: model)
        let loadElapsed = loadStart.duration(to: .now)
        MetricsSink.record("REALMODEL-SMOKE first-load-in-process-seconds=\(loadElapsed.secondsDouble)")

        let transcriber = await MainActor.run {
            FluidAudioMeetingSegmentTranscriber(
                access: MeetingAsrRuntimeAccess.sharingDictationRuntime(
                    of: service,
                    isDictationActiveOrPending: { false }
                )
            )
        }

        let coordinator = MeetingTranscriptionCoordinator(
            backend: .fluidAudio,
            fluidAudioTranscriber: transcriber,
            fallbackTranscribe: { _ in throw UnexpectedFallbackInvoked() }
        )

        // Deliverable 1: real transcript text from real speech, through the coordinator's own
        // routing (not FluidAudio called directly).
        let fullStart = ContinuousClock.now
        let fullResult = try await coordinator.transcribeMeetingChunk(at: recording)
        let fullElapsed = fullStart.duration(to: .now)
        let wordCount = fullResult.text.split(whereSeparator: { $0.isWhitespace }).count
        MetricsSink.record(
            "REALMODEL-SMOKE full-recording-seconds=\(fullElapsed.secondsDouble) "
                + "words=\(wordCount) segments=\(fullResult.segments.count) "
                + "text=\"\(fullResult.text)\""
        )

        #expect(
            wordCount >= 5,
            "expected a genuine multi-word transcript from ~15s of real dictation, got: \(fullResult.text)"
        )
        #expect(!fullResult.segments.isEmpty)
        // Proves real per-token segment timing came back through the coordinator's
        // `.fluidAudio` route, not its flat zero-duration fallback shape (`route(_:)`'s
        // `flatFallback`, which this test's `fallbackTranscribe` would have made fail loudly
        // anyway if it had been reached).
        #expect(fullResult.segments.contains { $0.end > $0.start })

        // Deliverable 2: representative 3-5s chunk latency, first call (includes any
        // first-inference warmup) and second call (steady state) on the SAME chunk.
        let chunkStart1 = ContinuousClock.now
        let chunkResult1 = try await coordinator.transcribeMeetingChunk(at: chunk)
        let chunkElapsed1 = chunkStart1.duration(to: .now)
        MetricsSink.record(
            "REALMODEL-SMOKE chunk-4s-first-call-seconds=\(chunkElapsed1.secondsDouble) "
                + "words=\(chunkResult1.text.split(whereSeparator: { $0.isWhitespace }).count)"
        )

        let chunkStart2 = ContinuousClock.now
        _ = try await coordinator.transcribeMeetingChunk(at: chunk)
        let chunkElapsed2 = chunkStart2.duration(to: .now)
        MetricsSink.record("REALMODEL-SMOKE chunk-4s-second-call-seconds=\(chunkElapsed2.secondsDouble)")

        let peakRSS = rss.stopPolling()
        MetricsSink.record(
            "REALMODEL-SMOKE peak-rss-bytes=\(peakRSS) peak-rss-mb=\(Double(peakRSS) / 1_048_576)"
        )
        #expect(peakRSS > 0, "RSS sampling must have produced at least one real reading")
    }

    @Test(
        "real FluidAudioMeetingDiarizer loads and diarizes a synthesized multi-speaker recording, measured against its loadOperationTimeout ceiling",
        .disabled(if: isRunningInCI && !isGateRunningMode, "\(diarizerSkippedOnCIMessage)"),
        .disabled(
            if: !RealModelAvailability.diarizerModelsPresent && !NetworkProbe.huggingFaceReachable
                && !isGateRunningMode,
            "diarizer model not already cached locally and huggingface.co is unreachable -- cannot run this test for real"
        )
    )
    func realDiarizerLoadsAndRuns() async throws {
        // Same reasoning as the transcription test above: gate mode bypasses the `.disabled`
        // traits (and their skip messages) entirely, so re-check the same prerequisite here,
        // explicitly, and fail with a message naming it before touching any real diarizer path.
        if isGateRunningMode, !RealModelAvailability.diarizerModelsPresent, !NetworkProbe.huggingFaceReachable {
            throw GateModePrerequisiteMissing(description: diarizerModelMissingGateFailureMessage)
        }

        let audio = try SyntheticMultiSpeakerAudio.make()
        defer { try? FileManager.default.removeItem(at: audio) }

        // Production init: the SAME `DiarizerModels.load()` path a real composition root would
        // use, with the default 30s `loadOperationTimeout` FOLLOWUPS.md gate item 5 flags as
        // chosen without a real-hardware measurement.
        let diarizer = FluidAudioMeetingDiarizer()

        let started = ContinuousClock.now
        do {
            let result = try await diarizer.diarize(fileAt: audio)
            let elapsed = started.duration(to: .now)
            MetricsSink.record(
                "REALMODEL-SMOKE diarizer-load-and-run-seconds=\(elapsed.secondsDouble) "
                    + "outcome=succeeded segments=\(result?.segments.count ?? -1)"
            )
            #expect(result != nil)
        } catch {
            // FAILS THE TEST -- deliberately, including `FluidAudioMeetingDiarizerError.loadTimedOut`.
            // A prior version of this test caught `loadTimedOut` specially and reported it as a
            // passing outcome, on the reasoning that "a real result either way is data gate item
            // 5 needs". That reasoning was wrong: it let this test PASS having loaded no model,
            // run no diarization, and produced no `DiarizationResult` -- the test's own name
            // claims the diarizer "loads and diarizes", and a future regression past the 30s
            // ceiling would leave this suite green while claiming exactly that. The elapsed time
            // and outcome are still recorded here as a diagnostic (see FOLLOWUPS.md gate item 5
            // for how that number is used), but recording it is no longer what decides pass/fail
            // -- rethrowing is.
            let elapsed = started.duration(to: .now)
            MetricsSink.record(
                "REALMODEL-SMOKE diarizer-load-and-run-seconds=\(elapsed.secondsDouble) "
                    + "outcome=failed error=\(error)"
            )
            throw error
        }
    }
}

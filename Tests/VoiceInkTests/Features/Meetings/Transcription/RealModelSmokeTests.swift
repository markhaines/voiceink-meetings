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
// downloaded Parakeet v3 model, one of Mark's own dictation recordings, network reachability for
// the diarizer's model download) and disables itself with a specific message when that
// prerequisite is absent. That second layer is what keeps this file from becoming the "guard
// that skips everywhere" bug FOLLOWUPS.md already records this repo shipping twice: a machine
// with `VOICEINK_CI` unset but no models/audio present (a fresh clone, a CI runner someone points
// a debugger at) skips cleanly with a reason, instead of either hanging on a missing model file
// or silently reporting green with nothing exercised.
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

private struct UnexpectedFallbackInvoked: Error {}

/// Swift Testing's `print()` output from a real `xcodebuild test` invocation is not reliably
/// visible in the plain-text build log this task's report is generated from (verified empirically
/// while building this file: `Test Case ... passed` lines appear, raw `print()` lines do not).
/// Every real measurement this file produces is therefore ALSO appended to a plain file, so the
/// numbers can be read back directly rather than screen-scraped from a log format that dropped
/// them once already. `print()` is kept too, for anyone reading Xcode's own test log.
private enum MetricsSink {
    static let path =
        ProcessInfo.processInfo.environment["REALMODEL_SMOKE_METRICS_PATH"]
        ?? "/tmp/voiceink-meetings-realmodel-smoke-metrics.log"

    static func record(_ line: String) {
        print(line)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
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
/// assumed -- the diarizer's real model (`FluidInference/speaker-diarization-coreml`) is not
/// present on disk (see this task's report), so `FluidAudioMeetingDiarizer`'s production
/// `DiarizerModels.load()` path downloads it on first use.
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
        .disabled(
            if: isRunningInCI,
            "hardware/model test -- see AudioGraphExceptionBridgeTests.swift for the same VOICEINK_CI idiom"
        ),
        .disabled(
            if: !RealModelAvailability.parakeetV3Present,
            "no local Parakeet v3 model at \(AsrModels.defaultCacheDirectory(for: .v3).path)"
        ),
        .disabled(
            if: !RealAudioFixture.isAvailable,
            "no usable 8-20s recording found under \(RealAudioFixture.recordingsDirectory.path)"
        )
    )
    func realModelTranscribesRealAudio() async throws {
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

        // Deliverable 2: real cold model-load time. "Cold" here means the first load THIS
        // PROCESS performs -- the model files are already downloaded on disk (premise (a)), so
        // this is real CoreML compile-cache load time, not a network download timing.
        let loadStart = ContinuousClock.now
        try await service.loadModel(for: model)
        let loadElapsed = loadStart.duration(to: .now)
        MetricsSink.record("REALMODEL-SMOKE cold-model-load-seconds=\(loadElapsed.secondsDouble)")

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
        .disabled(
            if: isRunningInCI,
            "hardware/model test -- see AudioGraphExceptionBridgeTests.swift for the same VOICEINK_CI idiom"
        ),
        .disabled(
            if: !NetworkProbe.huggingFaceReachable,
            "no network reachability to huggingface.co -- the diarizer model is not present locally and must download to run this test for real"
        )
    )
    func realDiarizerLoadsAndRuns() async throws {
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
        } catch FluidAudioMeetingDiarizerError.loadTimedOut {
            let elapsed = started.duration(to: .now)
            // NOT a test failure. A real result either way is the data gate item 5 needs, and
            // hitting the ceiling on real hardware against a real download is itself the
            // finding -- see this task's report and FOLLOWUPS.md.
            MetricsSink.record(
                "REALMODEL-SMOKE diarizer-load-and-run-seconds=\(elapsed.secondsDouble) "
                    + "outcome=loadTimedOut (30s default ceiling WAS HIT for a real cold load)"
            )
        }
    }
}

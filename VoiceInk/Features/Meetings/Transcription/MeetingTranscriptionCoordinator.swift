// Fork-owned (no donor equivalent). Not a port.
//
// The concrete `MeetingTranscriptionCoordinating` this stage (Stage 2c, per
// `MeetingTranscriptionCoordinating.swift`'s own header) exists to build, replacing
// `NullMeetingTranscriptionCoordinator`. See `DECISION-transcription-seam.md` for the design
// this implements: the coordinator sits BESIDE `TranscriptionServiceRegistry`, not on top of it
// and not via an upstream protocol change, and routes each chunk down one of two paths:
//
//   - `.fluidAudio` / `.transcribeCpp`, WHEN a segment-bearing transcriber is configured for
//     that backend: call it directly (`FluidAudioMeetingSegmentTranscriber` /
//     `TranscribeCppMeetingSegmentTranscriber`, both in this directory) for genuine per-segment
//     timing.
//   - Every other case (`.other`, or a `.fluidAudio`/`.transcribeCpp` meeting with no
//     transcriber configured): `fallbackTranscribe`, wrapped as a single zero-duration
//     `SpeechSegment`. `MicTurnNormalizer`/`SystemTurnNormalizer` (both ported verbatim,
//     unmodified) already treat that shape as "no meaningful timing" and NLTokenizer-sentence-
//     split it themselves -- this is PARITY with the donor's own shipped behavior for every
//     backend except FluidAudio (`segment-timing-design.md` §C), not a compromise invented here.
//
// `backend` and every transcriber/diarizer dependency are constructor-injected, never resolved
// from app settings inside this type. `MeetingTranscriptionCoordinating.swift`'s own header
// explains why: "backend selection has no fork equivalent ... and is a product decision this
// stage does not make. Stage 2c's real implementation owns backend selection internally" --
// "owns" here means owns the ROUTING MECHANISM (given a resolved backend, do the right thing),
// not the UI/settings policy of which model a user picked for meetings, which does not exist
// anywhere in this fork yet (no composition root constructs a non-Null coordinator today -- see
// this file's own PR description for exactly what that means for "which backends land on which
// path TODAY").
//
// Actor isolation, per `DECISION-transcription-seam.md`: `TranscriptionServiceRegistry` is
// `@MainActor`; this type is its OWN actor so per-chunk transcription (a hot path, driven off
// the capture pipeline's serial `chunkRotationQueue`) never lands on the UI executor. Only
// `fallbackTranscribe`, when it is the real registry-backed closure a composition root supplies,
// hops to `@MainActor` internally for its one call into the registry -- that hop lives in
// whoever builds that closure, not in this file, so this actor itself never touches
// `@MainActor`. No profiling was run (see `segment-timing-design.md` §D's own caveat): this is
// hygiene, not a measured win.

import FluidAudio
import Foundation

actor MeetingTranscriptionCoordinator: MeetingTranscriptionCoordinating {
    private let backend: MeetingTranscriptionBackend
    private let fluidAudioTranscriber: (any MeetingSegmentTranscribing)?
    private let transcribeCppTranscriber: (any MeetingSegmentTranscribing)?
    private let diarizer: (any MeetingSystemAudioDiarizing)?
    private let fallbackTranscribe: @Sendable (URL) async throws -> String
    private let vadManagerFactory: @Sendable () async throws -> VadManager

    private var cachedVadManager: VadManager?
    private var vadManagerLoadFailed = false

    init(
        backend: MeetingTranscriptionBackend,
        fluidAudioTranscriber: (any MeetingSegmentTranscribing)? = nil,
        transcribeCppTranscriber: (any MeetingSegmentTranscribing)? = nil,
        diarizer: (any MeetingSystemAudioDiarizing)? = nil,
        fallbackTranscribe: @escaping @Sendable (URL) async throws -> String,
        vadManagerFactory: @escaping @Sendable () async throws -> VadManager = { try await VadManager() }
    ) {
        self.backend = backend
        self.fluidAudioTranscriber = fluidAudioTranscriber
        self.transcribeCppTranscriber = transcribeCppTranscriber
        self.diarizer = diarizer
        self.fallbackTranscribe = fallbackTranscribe
        self.vadManagerFactory = vadManagerFactory
    }

    /// A nil return matches the donor's own fallback path documented on the protocol: chunk
    /// rotation then only happens at `stop()`, not mid-meeting. Failure to construct the real
    /// VAD manager (model download/load failure) is cached so every subsequent call this
    /// session returns nil immediately rather than retrying a failure per chunk.
    func getVadManager() async -> VadManager? {
        if let cachedVadManager { return cachedVadManager }
        guard !vadManagerLoadFailed else { return nil }
        do {
            let manager = try await vadManagerFactory()
            cachedVadManager = manager
            return manager
        } catch {
            vadManagerLoadFailed = true
            return nil
        }
    }

    func transcribeMeetingChunk(at url: URL) async throws -> SpeechTranscriptionResult {
        try await route(url)
    }

    func transcribeMeeting(at url: URL) async throws -> SpeechTranscriptionResult {
        try await route(url)
    }

    func diarizeSystemAudio(at url: URL) async throws -> DiarizationResult? {
        try await diarizer?.diarize(fileAt: url)
    }

    /// The two errors a segment transcriber can raise that this coordinator ROUTES on instead of
    /// propagating, both meaning "this chunk deliberately did not run":
    ///   * `.sharedModelNotLoaded` -- dictation has no model loaded, so there was nothing to
    ///     borrow (fix round 3, B1: the meeting seam cannot load one itself, because being able
    ///     to load is what let it evict dictation's model mid-transcription).
    ///   * `.dictationHasPriority` -- dictation is active or pending, so the chunk yielded rather
    ///     than making Mark's dictation queue behind its inference (fix round 4, B4.2).
    ///
    /// Both are caught BY CASE, not by type and not blanket. A real inference failure, a
    /// cancellation, or a file error still propagates: a blanket catch here would silently turn
    /// every backend fault into a plausible-looking flat transcript, which in a 90-minute
    /// recording is the hardest kind of wrong to notice.
    /// `MeetingTranscriptionCoordinatorTests.segmentTranscriberFailurePropagates` is the standing
    /// control for exactly that, and would fail if this were ever widened.
    private func route(_ url: URL) async throws -> SpeechTranscriptionResult {
        do {
            switch backend {
            case .fluidAudio:
                if let fluidAudioTranscriber {
                    return try await fluidAudioTranscriber.transcribe(chunkAt: url)
                }
            case .transcribeCpp:
                if let transcribeCppTranscriber {
                    return try await transcribeCppTranscriber.transcribe(chunkAt: url)
                }
            case .other:
                break
            }
        } catch MeetingSegmentTranscriberError.sharedModelNotLoaded {
            return try await flatFallback(url)
        } catch MeetingSegmentTranscriberError.dictationHasPriority {
            return try await flatFallback(url)
        }
        return try await flatFallback(url)
    }

    private func flatFallback(_ url: URL) async throws -> SpeechTranscriptionResult {
        let text = try await fallbackTranscribe(url)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SpeechTranscriptionResult(text: text, segments: [])
        }
        // Donor's own convention for every backend except FluidAudio (segment-timing-design.md
        // §C): a single zero-duration segment. MicTurnNormalizer/SystemTurnNormalizer both
        // treat `start == 0 && end <= start` as "no meaningful timing" and fall through to
        // their own NLTokenizer sentence-split + proportional interpolation -- not invented or
        // duplicated here.
        return SpeechTranscriptionResult(text: text, segments: [SpeechSegment(start: 0, end: 0, text: text)])
    }
}

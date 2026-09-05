// Fork-owned (no donor equivalent). Not a port.
//
// Direct transcribe-cpp integration for the meeting transcription seam
// (`DECISION-transcription-seam.md`, Option (ii)). FIX ROUND (cross-vendor review, B1/B2): the
// first version of this file loaded its own independent `Model`, permanently duplicating
// dictation's transcribe-cpp instance, AND bypassed `OfflineTranscribeCppService`'s process-wide
// `backendInitializationLock`/`modelInitializationLock` with its own separate, uncoordinated
// native construction -- two independent locks over one non-cancellable native resource, which
// is worse than none. Mark explicitly authorised an upstream touchpoint to fix both.
//
// This version instead BORROWS dictation's shared model through
// `OfflineTranscribeCppService.borrowModel(for:)` (a new, narrow, additive accessor on that file
// -- see FORK-PATCHES.md touchpoint 4), which internally reuses the exact same
// `resolveArtifact`/`getOrLoadModel`/`retainModel` path dictation's own
// `transcribe(audioURL:model:context:)` already goes through, hence the SAME locks. No second
// lock is introduced here. `OfflineTranscribeCppService` is already `@unchecked Sendable` and
// internally lock-protected (unlike `FluidAudioTranscriptionService`), so no additional
// actor-isolation discipline is needed at this call site beyond the borrow/release contract
// (release exactly once per `transcribe(chunkAt:)` call, via `defer`, matching
// `OfflineTranscribeCppService.transcribe`'s own pattern).
//
// WHICH catalog model backs meetings remains a product decision this stage does not make (see
// `MeetingSegmentTranscribing.swift`'s header) -- only the model's NAME is injected; the actual
// `TranscribeCppModel` value is looked up from `TranscriptionModelRegistry.models` (an existing
// fork file, read here, not edited), so this file never constructs a model with placeholder
// metadata of its own.
//
// transcribe-cpp's own energy-aware long-audio chunking
// (`OfflineTranscribeCppService.energyAwareChunks`) is intentionally NOT reproduced here --
// meeting chunks are already short, VAD-rotated windows (3-5s), not whole dictation files, so a
// single `session.run` per chunk is the correct scope, not a missing feature.

import FluidAudio  // AudioConverter (resampleAudioFile) -- same helper OfflineTranscribeCppService.swift uses.
import Foundation
import TranscribeCpp

enum TranscribeCppMeetingSegmentTranscriberError: Error {
    case unknownModel(String)
}

actor TranscribeCppMeetingSegmentTranscriber: MeetingSegmentTranscribing {
    private let sharedService: OfflineTranscribeCppService
    private let modelName: String
    private let audioConverter = AudioConverter()

    init(sharedService: OfflineTranscribeCppService, modelName: String) {
        self.sharedService = sharedService
        self.modelName = modelName
    }

    func transcribe(chunkAt url: URL) async throws -> SpeechTranscriptionResult {
        guard let model = TranscriptionModelRegistry.models.first(where: { $0.name == modelName }) as? TranscribeCppModel
        else {
            throw TranscribeCppMeetingSegmentTranscriberError.unknownModel(modelName)
        }

        let borrowed = try await sharedService.borrowModel(for: model)
        defer { borrowed.release() }

        let samples = try audioConverter.resampleAudioFile(url)
        let session = try borrowed.model.session()
        let options = RunOptions(
            timestamps: .segment,
            itn: borrowed.artifact.enablesInverseTextNormalization ? .on : .default
        )
        let transcript = try await session.run(samples, options: options)
        return SpeechTranscriptionResult(
            text: transcript.text,
            segments: Self.speechSegments(from: transcript)
        )
    }

    static func speechSegments(from transcript: Transcript) -> [SpeechSegment] {
        speechSegments(
            segments: transcript.segments.map { (t0Ms: $0.t0Ms, t1Ms: $0.t1Ms, text: $0.text) },
            fallbackText: transcript.text
        )
    }

    /// Pure and independently testable (Gap (i) from the cross-vendor review: `Transcript`/
    /// `Segment` themselves have no public initializer outside the `TranscribeCpp` package and
    /// are not `Codable`, so no real value can be constructed from this module -- but the actual
    /// mapping ARITHMETIC (ms -> seconds, clamping empty/negative/reversed/overflowed inputs)
    /// does not need them: it only needs primitive fields. See
    /// `TranscribeCppMeetingSegmentTranscriberTests.swift`, which exercises exactly those edge
    /// cases against this function directly. `speechSegments(from:)` above is now the only part
    /// of this file that touches the un-constructible package types, and is compilation-only
    /// coverage (proven by `xcodebuild build-for-testing`, not by a runtime test).
    static func speechSegments(
        segments: [(t0Ms: Int64, t1Ms: Int64, text: String)],
        fallbackText: String
    ) -> [SpeechSegment] {
        guard !segments.isEmpty else {
            let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [SpeechSegment(start: 0, end: 0, text: fallbackText)]
        }
        return segments.map { segment in
            let start = max(Double(segment.t0Ms) / 1000, 0)
            let end = max(Double(segment.t1Ms) / 1000, start)
            return SpeechSegment(start: start, end: end, text: segment.text)
        }
    }
}

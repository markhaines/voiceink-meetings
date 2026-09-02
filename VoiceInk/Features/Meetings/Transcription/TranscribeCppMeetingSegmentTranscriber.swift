// Fork-owned (no donor equivalent). Not a port.
//
// Direct transcribe-cpp integration for the meeting transcription seam
// (`DECISION-transcription-seam.md`, Option (ii)). Deliberately independent of
// `OfflineTranscribeCppService.swift`: this stage's brief forbids editing upstream files without
// stopping to ask first, and that file's own `timestamps: .none` (an explicit opt-out of the
// library's richer default, per `segment-timing-design.md` §B) would need to change to get
// segments out of it. Rather than touch it, this type owns its own `Model`/`Session` and asks
// for `.segment` timestamps directly. It DOES read `TranscribeCppModelCatalog.artifact(for:)` --
// an existing fork file -- to resolve the on-disk model path; that is a read, not an edit.
//
// Cost, stated plainly: a second native model instance loads if a dictation session is also
// using transcribe-cpp concurrently with a meeting. transcribe-cpp's own energy-aware long-audio
// chunking (`OfflineTranscribeCppService.energyAwareChunks`) is intentionally NOT reproduced
// here -- meeting chunks are already short, VAD-rotated windows (3-5s), not whole dictation
// files, so a single `session.run` per chunk is the correct scope, not a missing feature.
//
// WHICH catalog model backs meetings is a product decision this stage does not make (see
// `MeetingSegmentTranscribing.swift`'s header) -- the artifact is injected at construction.

import FluidAudio  // AudioConverter (resampleAudioFile) -- same helper OfflineTranscribeCppService.swift uses.
import Foundation
import TranscribeCpp

enum TranscribeCppMeetingSegmentTranscriberError: Error {
    case modelNotInstalled(String)
    case backendUnavailable
}

actor TranscribeCppMeetingSegmentTranscriber: MeetingSegmentTranscribing {
    private let artifact: TranscribeCppModelArtifact
    private let audioConverter = AudioConverter()

    private var loadedModel: Model?
    private var loadingTask: Task<Model, Error>?

    init(artifact: TranscribeCppModelArtifact) {
        self.artifact = artifact
    }

    func transcribe(chunkAt url: URL) async throws -> SpeechTranscriptionResult {
        let model = try await resolvedModel()
        let samples = try audioConverter.resampleAudioFile(url)
        let session = try model.session()
        let options = RunOptions(
            timestamps: .segment,
            itn: artifact.enablesInverseTextNormalization ? .on : .default
        )
        let transcript = try await session.run(samples, options: options)
        return SpeechTranscriptionResult(
            text: transcript.text,
            segments: Self.speechSegments(from: transcript)
        )
    }

    /// `Transcript`/`Segment` have no public initializer outside the `TranscribeCpp` package
    /// (their synthesized memberwise inits are package-internal, and neither conforms to
    /// `Codable`), so unlike the FluidAudio mapper this cannot be unit-tested against real
    /// values from this module -- see the PR description's "could not prove" list.
    static func speechSegments(from transcript: Transcript) -> [SpeechSegment] {
        guard !transcript.segments.isEmpty else {
            let trimmed = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [SpeechSegment(start: 0, end: 0, text: transcript.text)]
        }
        return transcript.segments.map { segment in
            SpeechSegment(
                start: Double(segment.t0Ms) / 1000,
                end: Double(segment.t1Ms) / 1000,
                text: segment.text
            )
        }
    }

    private func resolvedModel() async throws -> Model {
        if let loadedModel { return loadedModel }
        if let loadingTask { return try await loadingTask.value }

        guard let modelURL = artifact.installedModelFileURL else {
            throw TranscribeCppMeetingSegmentTranscriberError.modelNotInstalled(artifact.modelName)
        }

        let task = Task<Model, Error> {
            try Transcribe.initBackends()
            let backend: Backend = {
                #if arch(arm64)
                return .metal
                #else
                return .cpu
                #endif
            }()
            guard Transcribe.backendAvailable(backend) else {
                throw TranscribeCppMeetingSegmentTranscriberError.backendUnavailable
            }
            return try Model(path: modelURL.path, options: ModelOptions(backend: backend))
        }
        loadingTask = task
        do {
            let model = try await task.value
            loadedModel = model
            loadingTask = nil
            return model
        } catch {
            loadingTask = nil
            throw error
        }
    }
}

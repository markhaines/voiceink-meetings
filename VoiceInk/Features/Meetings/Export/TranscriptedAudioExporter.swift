// Fork-only file, no upstream equivalent. Sibling of `TranscriptedMarkdownExporter.swift`:
// same directory, same job (write into `~/Library/CloudStorage/OneDrive-ATEME/Transcripted/
// meetings/` in Transcripted's own on-disk shape so Mark's existing tooling and habits keep
// working), audio instead of markdown.
//
// THE REAL LAYOUT, verified against 34 real audio directories copied down read-only from
// Mark's Mac Studio (`~/Library/CloudStorage/OneDrive-ATEME/Transcripted/meetings/audio/`,
// 2026-09-06) — every directory inspected, not a sample: a meeting's audio lives at
// `meetings/audio/<transcript-file-stem>_audio/`, i.e. the SAME stem
// `TranscriptedMarkdownExporter.renderStem(date:title:)` produces for the paired `.md` file,
// plus the literal suffix `_audio`. 33 of 34 directories contained exactly three files —
// `microphone.m4a` (1 channel, 16kHz, low-bitrate voice AAC), `system_audio.m4a` (2 channel,
// 48kHz AAC), `playback.m4a` (2 channel, 48kHz AAC) — confirmed with `afinfo`, not inferred
// from filenames. The one exception, `Failed_2026-08-28_07-59-41_DBB620D5_audio/`, is a
// meeting that crashed ~4 seconds in: it has `microphone.m4a` and `system_audio.m4a` but NO
// `playback.m4a`. That is real Transcripted's own missing-channel behavior in the wild: a
// derived file that could not be produced is simply ABSENT, not replaced with silence, and its
// absence does not erase the channels that DID capture successfully.
//
// WHY `playback.m4a` IS SOMETIMES MISSING, confirmed from `~/code/transcripted`'s own source
// (Mark's separate, real Transcripted app), not guessed from the file-size/duration evidence
// alone:
// - `Sources/TranscriptedCore/Storage/RecordingAudioArchiver.swift` archives whatever the
//   capture actually produced: `microphone.<ext>` when a mic recording exists, and
//   `system_audio.<ext>` when a system recording exists AND a mic recording also exists (if
//   the mic is the one that's missing, the lone surviving file is named `recording.<ext>`
//   instead — a real rule, but not one observed in any of the 34 samples, all of which had a
//   mic track).
// - `Sources/Meeting/MeetingAudioStorageManager.swift`'s `createPlaybackMixIfNeeded` is what
//   produces `playback.wav` (later compressed to `playback.m4a` by a separate pass): it
//   requires BOTH a `microphone` file AND a `system_audio` file to already exist and each
//   independently pass `validator.isUsableAudioFile` — if either is missing or unusable, the
//   function returns `false` and writes nothing. The mix itself
//   (`AVFoundationMeetingAudioPlaybackMixer`) is a voice-activity-gated ducking mix of the two,
//   run as an ASYNC MAINTENANCE PASS after capture, not written by the capture path itself —
//   which is exactly why a meeting that crashed before that pass ran (the real `Failed_*`
//   example) has mic+system but no playback: nothing ran the mixer yet, and never will for a
//   capture that failed.
// So `playback.m4a` is not an independent capture at all — it is DERIVED from the other two,
// and real Transcripted's rule for "channel missing" is unambiguous: omit the file that
// cannot be produced, never write silence, never refuse the rest of the directory.
//
// THIS FORK'S OWN CAPTURE HAS NO ISOLATED CHANNELS TO GIVE THIS EXPORTER, and that shapes the
// design below. `MeetingRecordingWriter.swift` (`Capture/MeetingRecordingWriter.swift`) is the
// only place this fork retains meeting audio, and it produces exactly ONE file per meeting: a
// single mono 16kHz WAV built by averaging mic and system PCM samples together AS THEY ARRIVE
// (`mix(mic:system:)`), optionally transcoded to M4A by `persistTemporaryRecordingAsync`.
// Nothing under `Capture/` ever writes a mic-only or system-only file to permanent storage —
// confirmed by reading every file in that directory that touches audio persistence. So the one
// thing a caller of this exporter can honestly hand it TODAY is a single already-combined
// recording, not isolated per-channel captures.
//
// THE DESIGN THIS DRIVES: `AudioSources` below offers the SAME THREE SLOTS real Transcripted
// uses (`microphoneURL`, `systemAudioURL`, `playbackURL`), so this exporter is ready for a
// future capture pipeline that DOES retain isolated channels without needing a redesign. But
// today's single mixed recording is mapped to `playbackURL`, NEVER to `microphoneURL` or
// `systemAudioURL`: writing the same combined bytes under a `microphone.m4a` or
// `system_audio.m4a` name would claim an isolated capture that was never actually made — worse
// than an honest gap, because Mark's tooling (and this fork's own markdown exporter, which
// tags each transcript utterance `Mic` or `System`) treats those names as meaning one channel
// only. `playback.m4a` is the only slot that means "already-combined audio", which is what
// this fork actually has. A fork-produced audio directory therefore contains ONLY
// `playback.m4a` today — a combination never observed in the 34 real directories (there,
// `playback.m4a` never appears without both of its sources) — and that mismatch is a known,
// documented limitation of this integration, not a hidden one: it should be revisited once (if
// ever) this fork's capture layer retains mic and system separately, which
// `MeetingRecordingWriter` does not do today and is not this file's job to change. See
// `FOLLOWUPS.md`'s "`retainRecording` stays `false`" entry: wiring up an actual caller for this
// exporter (turning `retainRecording` on, threading a promoted recording through) is
// deliberately out of scope here too — this is only the pure export leg, additive and unwired,
// exactly like `TranscriptedMarkdownExporter` was before something else wired it in.
//
// MISSING-CHANNEL POLICY (mirrors real Transcripted's own, established above): a `nil` source
// in `AudioSources` means that channel is OMITTED from the written directory — no silence, no
// placeholder, no refusal — as long as at least one source is present. All three absent is
// refused outright (`ExportError.noAudioSources`): an audio directory with nothing in it would
// be worse than no directory at all, and `RecordingAudioArchiver.archive` enforces the same
// "at least one source" guard in the real app.
//
// TRANSCODE-FAILURE POLICY, the established precedent this file follows rather than invents:
// `MeetingRecordingWriter.persistTemporaryRecordingAsync`'s M4A path already answers "what
// happens when a transcode of audio nobody can re-record fails" for this fork — throw, remove
// the partial destination file, and never touch the source. This exporter's `writeAudioFile`
// below does exactly that, per file, and never deletes a source URL under any circumstance
// (unlike `persistTemporaryRecordingAsync`, which deletes ITS OWN disposable temp file only
// after a successful transcode) — this exporter does not own the sources it is given, so
// lifecycle decisions about them belong to whatever caller eventually wires this in.

import AVFoundation
import Foundation

/// Thin planning + file-writing shell around Transcripted's audio layout. The planning half
/// (`plan(meeting:sources:)`) is pure — no filesystem access, no I/O — exactly like
/// `TranscriptedMarkdownExporter.render(meeting:segments:)`; only `export(meeting:sources:to:)`
/// touches disk.
enum TranscriptedAudioExporter {
    /// Whatever audio this fork's capture actually produced for a meeting. Any subset may be
    /// present; see this file's header for why only `playbackURL` is populated today, and why
    /// `microphoneURL`/`systemAudioURL` exist at all despite that.
    struct AudioSources: Equatable {
        var microphoneURL: URL?
        var systemAudioURL: URL?
        var playbackURL: URL?

        init(microphoneURL: URL? = nil, systemAudioURL: URL? = nil, playbackURL: URL? = nil) {
            self.microphoneURL = microphoneURL
            self.systemAudioURL = systemAudioURL
            self.playbackURL = playbackURL
        }
    }

    /// One of the three fixed slots in Transcripted's audio directory. `rawValue` is the
    /// on-disk stem; `destinationFilename` always adds `.m4a`, matching every native-capture
    /// example found in the real library (WAV sources are transcoded, never written verbatim).
    enum Channel: String, Equatable, CaseIterable {
        case microphone
        case systemAudio = "system_audio"
        case playback

        var destinationFilename: String { "\(rawValue).m4a" }
    }

    /// A plan to write one channel's audio into the audio directory. Pure data: `sourceURL` is
    /// whatever `AudioSources` was given, unread and unvalidated at this stage.
    struct PlannedItem: Equatable {
        let channel: Channel
        let sourceURL: URL
        var destinationFilename: String { channel.destinationFilename }
    }

    /// The fully-resolved plan for one meeting: where its audio directory goes, and which
    /// files to write into it. `items` is always ordered `[.microphone, .systemAudio,
    /// .playback]` (channels absent from `sources` are simply skipped), matching real
    /// Transcripted's own `managedAudioStems` ordering
    /// (`~/code/transcripted/Sources/Meeting/MeetingAudioStorageManager.swift`).
    struct ExportPlan: Equatable {
        let audioDirectoryName: String
        let items: [PlannedItem]
    }

    enum ExportError: Error, Equatable {
        /// `AudioSources` had every field `nil` — nothing to write. Mirrors real
        /// Transcripted's own `RecordingAudioArchiver.archive` guard (`micURL != nil ||
        /// systemURL != nil`): an audio directory with zero files would be a worse signal than
        /// no directory at all.
        case noAudioSources
        case exportSessionUnavailable
        case transcodeFailed
    }

    /// Pure: decides the audio directory's name and which files it will contain, without
    /// touching the filesystem or reading `sources`' URLs. Reuses
    /// `TranscriptedMarkdownExporter.renderStem(date:title:)` for the directory's stem rather
    /// than re-deriving it — see that function's doc comment for why an independent
    /// re-implementation here would risk the markdown file and its audio directory silently
    /// pointing at different names.
    static func plan(meeting: Meeting, sources: AudioSources) throws -> ExportPlan {
        var items: [PlannedItem] = []
        if let url = sources.microphoneURL {
            items.append(PlannedItem(channel: .microphone, sourceURL: url))
        }
        if let url = sources.systemAudioURL {
            items.append(PlannedItem(channel: .systemAudio, sourceURL: url))
        }
        if let url = sources.playbackURL {
            items.append(PlannedItem(channel: .playback, sourceURL: url))
        }
        guard !items.isEmpty else { throw ExportError.noAudioSources }

        let stem = TranscriptedMarkdownExporter.renderStem(date: meeting.startDate, title: meeting.title)
        return ExportPlan(audioDirectoryName: "\(stem)_audio", items: items)
    }

    /// Writes `sources` into `<directory>/<stem>_audio/` per `plan(meeting:sources:)`, creating
    /// the audio directory if needed, and returns its URL. Each planned item is written
    /// independently by `writeAudioFile` — a failure partway through leaves earlier items'
    /// files in place (this exporter does not roll back siblings) but guarantees the failing
    /// item itself leaves no partial file and never touches its own source; see this file's
    /// header for why that is the deliberate, established policy rather than a gap.
    @discardableResult
    static func export(meeting: Meeting, sources: AudioSources, to directory: URL) async throws -> URL {
        let resolvedPlan = try plan(meeting: meeting, sources: sources)
        let audioDirectory = directory.appendingPathComponent(resolvedPlan.audioDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        for item in resolvedPlan.items {
            let destinationURL = audioDirectory.appendingPathComponent(item.destinationFilename)
            try await writeAudioFile(from: item.sourceURL, to: destinationURL)
        }

        return audioDirectory
    }

    // MARK: - Per-file write

    /// Writes one source into `destinationURL`: a plain copy when the source is already
    /// `.m4a`, otherwise a transcode via `AVAssetExportSession`. Any existing file at
    /// `destinationURL` is removed first (an idempotent re-export replaces it cleanly rather
    /// than failing on `copyItem`/`AVAssetExportSession`'s own "file already exists" error).
    /// On ANY failure, removes whatever partial file may have been left at `destinationURL`
    /// and rethrows without touching `sourceURL` — see this file's header,
    /// "TRANSCODE-FAILURE POLICY".
    private static func writeAudioFile(from sourceURL: URL, to destinationURL: URL) async throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        do {
            if sourceURL.pathExtension.lowercased() == "m4a" {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            } else {
                try await transcodeToM4A(sourceURL: sourceURL, destinationURL: destinationURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    /// `AVAssetExportSession`'s completion-handler API wrapped as `async throws`, the same
    /// shape `MeetingRecordingWriter.transcodeWAVToM4AAsync` already uses in this codebase (not
    /// the newer `session.export(to:as:)` the real Transcripted app's own converter uses,
    /// which needs a higher deployment target than this project's).
    private final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }

    private static func transcodeToM4A(sourceURL: URL, destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ExportError.exportSessionUnavailable
        }

        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .m4a
        let exportSessionBox = ExportSessionBox(exportSession)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSessionBox.session.exportAsynchronously {
                guard exportSessionBox.session.status == .completed else {
                    continuation.resume(throwing: exportSessionBox.session.error ?? ExportError.transcodeFailed)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }
}

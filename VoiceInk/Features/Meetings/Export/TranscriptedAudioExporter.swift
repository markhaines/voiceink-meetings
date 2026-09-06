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
//   `system_audio.<ext>` when a system recording exists AND a mic recording also exists. **If
//   the mic is the one that's missing, the lone surviving file is named `recording.<ext>`
//   instead** — not observed in any of the 34 real samples (all had a mic track), but a real,
//   IMPLEMENTED rule here (fix round: this was documented but not implemented in the first
//   version of this file — see "DESTINATION NAMING DEPENDS ON THE WHOLE SOURCE SET" below).
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
// this fork actually has. **A fork-produced audio directory therefore contains ONLY
// `playback.m4a` today — a combination never observed in ANY of the 34 real directories (there,
// `playback.m4a` never appears without both of its sources). This is a known, exceptionally
// prominent, documented limitation of this integration (also called out in `FOLLOWUPS.md`), not
// a hidden one: nothing here claims full parity with real Transcripted, and this mismatch should
// be revisited only if (ever) this fork's capture layer retains mic and system separately, which
// `MeetingRecordingWriter` does not do today and is not this file's job to change.** See
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
// DESTINATION NAMING DEPENDS ON THE WHOLE SOURCE SET, NOT ON EACH CHANNEL IN ISOLATION (fix
// round). `microphone` and `playback` always write under their own fixed stem when present.
// `systemAudio` does NOT: per `RecordingAudioArchiver.archive`'s real rule, it writes as
// `system_audio.m4a` only when a microphone source is ALSO present; when the microphone is
// absent, the lone surviving capture writes as `recording.m4a` instead, because the name
// "system_audio" implies a sibling microphone track that, in that shape, was never captured.
// `destinationFilename(for:sources:)` below is a function of the COMPLETE `AudioSources`, not
// of one field read in isolation, so this can never be computed correctly per-channel.
//
// ATOMICITY (fix round): this exporter's earlier version wrote each planned item directly into
// the final `<stem>_audio/` directory, one at a time. That has two failure modes that matter a
// great deal for audio nobody can re-record: (1) if an earlier item succeeded and a later one
// failed, the earlier item's file was left behind alongside a freshly-created but incomplete
// final directory; (2) a RE-export first deleted any file already at a destination path before
// writing its replacement, so a re-export that failed partway could destroy a good, pre-existing
// export while producing nothing usable in its place. `export(meeting:sources:to:)` now stages
// every item in a throwaway sibling directory OUTSIDE the final directory's own path, and only
// after every single item has succeeded does `commit(stagingDirectory:to:)` swap the staging
// directory into place. That commit is a single `FileManager.moveItem` (a `rename(2)` at the
// filesystem level, atomic, because the staging directory is created as a sibling of the final
// directory under the SAME parent — guaranteed same volume, never a cross-volume copy) when no
// prior export exists, or a rename-aside / rename-in / remove-backup sequence when one does,
// with the aside copy restored if the final rename itself fails. Either way: if any item fails
// during staging, the final directory (existing or not) is never touched at all, and the failed
// staging directory is deleted — no partial output, anywhere, ever reaches the destination path.
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

    /// One of the three fixed slots in Transcripted's audio directory. This identifies which
    /// `AudioSources` field an item came from; it does NOT by itself determine the destination
    /// filename — see `destinationFilename(for:sources:)`, since `systemAudio`'s name depends
    /// on whether a microphone source is also present.
    enum Channel: String, Equatable, CaseIterable {
        case microphone
        case systemAudio = "system_audio"
        case playback

        /// The stem this channel writes under when its name does NOT depend on the rest of the
        /// source set (true for `microphone` and `playback`; NOT true for `systemAudio`, which
        /// must go through `destinationFilename(for:sources:)` instead).
        fileprivate var defaultDestinationFilename: String { "\(rawValue).m4a" }
    }

    /// A plan to write one channel's audio into the audio directory. Pure data: `sourceURL` is
    /// whatever `AudioSources` was given, unread and unvalidated at this stage.
    /// `destinationFilename` is already resolved against the complete source set (see
    /// `destinationFilename(for:sources:)`) — it is not recomputed from `channel` alone.
    struct PlannedItem: Equatable {
        let channel: Channel
        let sourceURL: URL
        let destinationFilename: String
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
            items.append(PlannedItem(
                channel: .microphone,
                sourceURL: url,
                destinationFilename: destinationFilename(for: .microphone, sources: sources)
            ))
        }
        if let url = sources.systemAudioURL {
            items.append(PlannedItem(
                channel: .systemAudio,
                sourceURL: url,
                destinationFilename: destinationFilename(for: .systemAudio, sources: sources)
            ))
        }
        if let url = sources.playbackURL {
            items.append(PlannedItem(
                channel: .playback,
                sourceURL: url,
                destinationFilename: destinationFilename(for: .playback, sources: sources)
            ))
        }
        guard !items.isEmpty else { throw ExportError.noAudioSources }

        let stem = TranscriptedMarkdownExporter.renderStem(date: meeting.startDate, title: meeting.title)
        return ExportPlan(audioDirectoryName: "\(stem)_audio", items: items)
    }

    /// The destination filename for `channel`, given the COMPLETE source set — deliberately not
    /// a function of `channel` alone. See this file's header, "DESTINATION NAMING DEPENDS ON THE
    /// WHOLE SOURCE SET": `systemAudio` writes as `system_audio.m4a` only when a microphone
    /// source is also present, and as `recording.m4a` when it is the lone surviving capture,
    /// matching real Transcripted's `RecordingAudioArchiver.archive`. `microphone` and
    /// `playback` are unaffected by this rule, in the real app and here.
    private static func destinationFilename(for channel: Channel, sources: AudioSources) -> String {
        switch channel {
        case .microphone, .playback:
            return channel.defaultDestinationFilename
        case .systemAudio:
            return sources.microphoneURL == nil ? "recording.m4a" : channel.defaultDestinationFilename
        }
    }

    /// Writes `sources` into `<directory>/<stem>_audio/` per `plan(meeting:sources:)` and
    /// returns its URL. Every item is staged into a throwaway sibling directory first; only
    /// once ALL of them have succeeded is that staging directory atomically swapped into the
    /// final path by `commit(stagingDirectory:to:)` — see this file's header, "ATOMICITY", for
    /// why this is the only shape that can never leave a partial or destroyed destination behind
    /// for audio nobody can re-record. On any item failure, the staging directory is removed and
    /// the final directory (existing or not) is left byte-for-byte as it was.
    @discardableResult
    static func export(meeting: Meeting, sources: AudioSources, to directory: URL) async throws -> URL {
        let resolvedPlan = try plan(meeting: meeting, sources: sources)
        let fileManager = FileManager.default
        let finalDirectory = directory.appendingPathComponent(resolvedPlan.audioDirectoryName, isDirectory: true)
        let stagingDirectory = directory.appendingPathComponent(
            ".TranscriptedAudioExporter-staging-\(UUID().uuidString)", isDirectory: true
        )

        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        do {
            for item in resolvedPlan.items {
                let destinationURL = stagingDirectory.appendingPathComponent(item.destinationFilename)
                try await writeAudioFile(from: item.sourceURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }

        try commit(stagingDirectory: stagingDirectory, to: finalDirectory)
        return finalDirectory
    }

    /// Atomically swaps a fully-populated `stagingDirectory` into `finalDirectory`'s place.
    /// `stagingDirectory` is a sibling of `finalDirectory` (same parent, guaranteed same
    /// volume), so every `moveItem` here is a single `rename(2)`, not a cross-volume copy+
    /// delete — that is what makes each step atomic at the filesystem level.
    ///
    /// - No prior export exists: one rename, done.
    /// - A prior export exists (a re-export): the existing directory is renamed aside first,
    ///   the staging directory is renamed into the now-empty final path, and only THEN is the
    ///   aside copy removed. If the second rename fails for any reason, the aside copy is
    ///   renamed back into place and the failure propagates — so a failed re-export can never
    ///   leave neither the old nor the new audio in place, which is the exact defect this
    ///   function exists to close.
    private static func commit(stagingDirectory: URL, to finalDirectory: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: finalDirectory.path) else {
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
            return
        }

        let backupDirectory = finalDirectory.deletingLastPathComponent().appendingPathComponent(
            ".TranscriptedAudioExporter-backup-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.moveItem(at: finalDirectory, to: backupDirectory)
        do {
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
        } catch {
            try? fileManager.removeItem(at: finalDirectory)
            try? fileManager.moveItem(at: backupDirectory, to: finalDirectory)
            throw error
        }
        try? fileManager.removeItem(at: backupDirectory)
    }

    // MARK: - Per-file write

    /// Writes one source into `destinationURL`: a plain copy when the source is already
    /// `.m4a`, otherwise a transcode via `AVAssetExportSession`. `destinationURL` always lives
    /// inside a just-created staging directory (see `export`), so it never pre-exists here. On
    /// ANY failure, removes whatever partial file may have resulted and rethrows without
    /// touching `sourceURL` — see this file's header, "TRANSCODE-FAILURE POLICY".
    private static func writeAudioFile(from sourceURL: URL, to destinationURL: URL) async throws {
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

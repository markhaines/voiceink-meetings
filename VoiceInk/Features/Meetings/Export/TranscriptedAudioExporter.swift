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
// ============================================================================================
// ATOMICITY, AND ITS EXACT LIMITS
// ============================================================================================
//
// This exporter's first version wrote each planned item directly into the final `<stem>_audio/`
// directory, one at a time. That had two failure modes that matter a great deal for audio
// nobody can re-record: (1) an earlier item succeeding and a later one failing left the earlier
// item's file behind alongside a freshly-created but incomplete final directory; (2) a RE-export
// DELETED whatever was already at a destination path BEFORE writing its replacement, so a
// re-export that failed partway destroyed a good, pre-existing export while producing nothing
// usable in its place. `export(meeting:sources:to:)` now stages every item in a throwaway
// sibling directory OUTSIDE the final directory's own path, and only after every single item
// has succeeded does `commit(stagingDirectory:to:)` swap staging into place.
//
// Each individual step of that commit is one `FileManager.moveItem` — a `rename(2)` at the
// filesystem level, atomic, because the staging, backup and final directories are all siblings
// under the SAME parent, guaranteed the same volume, never a cross-volume copy+delete. Where no
// prior export exists that is a single rename, and the commit as a whole is genuinely atomic.
//
// **A RE-EXPORT IS TWO RENAMES, AND TWO RENAMES ARE NOT ONE ATOMIC UNIT.** That is the honest
// limit of this design, and it is stated here, in the code, rather than only in a review report,
// because a future reader gets this file and not that report. The sequence is `old -> backup`,
// then `staging -> final`, then remove `backup`. Between the first and the second there is a
// window in which the process can die outright — SIGKILL, kernel panic, power loss — leaving the
// original audio at the `.TranscriptedAudioExporter-backup-<uuid>` path and NOTHING at the
// documented `<stem>_audio/` path. No `catch` closes that window, because after a SIGKILL no
// code in this process runs at all.
//
// Darwin does offer `renameatx_np` with `RENAME_SWAP`, which would exchange staging and final in
// ONE atomic syscall and close the window entirely. It is deliberately NOT used here: the real
// destination is inside `~/Library/CloudStorage/OneDrive-ATEME/`, a File Provider volume whose
// `RENAME_SWAP` support cannot be verified from this fork's test environment, and an
// unsupported volume returns `ENOTSUP` — so shipping it would mean shipping BOTH it and this
// two-rename fallback, and the window would still exist on precisely the volume that matters.
// One reviewed path with a documented limit beats two paths where the limit merely moves. See
// FOLLOWUPS.md, "Stale staging and backup directories are never swept".
//
// WHAT THIS GUARANTEES, PRECISELY:
// - A partial or failed export NEVER reaches the destination path `<stem>_audio/`. Content
//   becomes visible there only by renaming an already-complete directory into place.
// - A pre-existing good export is NEVER deleted to make room for a replacement. It is renamed
//   aside, and removed only once the replacement rename has already succeeded.
// - If the replacement cannot be installed AND the original cannot be put back at the documented
//   path, the original is still intact under the backup name, and the error thrown to the caller
//   NAMES that path (`ExportError.rollbackFailed`, whose `errorDescription` spells out the
//   recovery `mv`). That failure is never swallowed.
// - The exporter never deletes, moves or modifies any source URL it was given, under any
//   circumstance.
//
// WHAT IT DOES NOT GUARANTEE — RESIDUE. It does NOT guarantee that no leftover directory exists
// anywhere. Removing a staging or backup directory is a best-effort `removeItem` that can itself
// fail (a permissions change, a vanished volume), and per the kill window above may never be
// reached at all. Such leftovers are inert debris, not data loss: they are dot-prefixed, carry
// this type's name, are uniquely suffixed, and are never at the destination path, so nothing
// reading Transcripted's layout ever sees them. When a cleanup does fail the path is LOGGED, so
// the residue is observable instead of invisible. An earlier version of this header claimed "no
// partial output, anywhere, ever" — that claim was stronger than the code and is corrected here;
// a sweep for the debris is deliberately out of scope and recorded in FOLLOWUPS.md.
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
import OSLog

/// Thin planning + file-writing shell around Transcripted's audio layout. The planning half
/// (`plan(meeting:sources:)`) is pure — no filesystem access, no I/O — exactly like
/// `TranscriptedMarkdownExporter.render(meeting:segments:)`; only `export(meeting:sources:to:)`
/// touches disk.
enum TranscriptedAudioExporter {
    /// Same `Logger(subsystem: "com.hainesy.voiceinkmeetings", category:)` convention as
    /// `MeetingSummaryService` and `MeetingEngine`. Used for exactly one thing: reporting a
    /// best-effort cleanup that failed, so leftover scratch directories are observable rather
    /// than invisible. See this file's header, "WHAT IT DOES NOT GUARANTEE — RESIDUE".
    private static let logger = Logger(
        subsystem: "com.hainesy.voiceinkmeetings",
        category: "TranscriptedAudioExporter"
    )

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

    // MARK: - Errors

    /// Everything a human needs to get their audio back BY HAND after the one failure this
    /// exporter cannot recover from itself: a re-export that could neither install its
    /// replacement nor put the original back where it belongs.
    ///
    /// The original audio is NOT lost in this state — it is complete, unmodified, and sitting at
    /// `originalAudioDirectory` under a dot-prefixed UUID name that nothing else on the system
    /// knows to look for. That is the entire reason this type exists: an earlier version of
    /// `commit` swallowed this failure with `try?`, so the caller saw only the unrelated
    /// replacement error while a complete recording sat under an unguessable name and the
    /// documented destination was empty. A caller that can only say "export failed" would strand
    /// audio nobody can re-record, so the recovery path is carried IN the error, and repeated in
    /// `errorDescription` as a literal `mv` command.
    struct RollbackFailure: Equatable, Sendable {
        /// Where the original, complete, pre-export audio directory ACTUALLY is right now.
        let originalAudioDirectory: URL
        /// Where it is supposed to be, and currently is not.
        let intendedDirectory: URL
        /// Why recovery could not finish.
        let reason: Reason
        /// Description of the failure that stopped the replacement being installed in the first
        /// place — kept alongside the recovery information rather than replaced by it, so the
        /// caller still learns why the export failed as well as what to do about it.
        let commitFailure: String

        enum Reason: Equatable, Sendable {
            /// Renaming the original back to `intendedDirectory` was attempted and failed. The
            /// payload is the underlying error's description.
            case restoreFailed(String)
            /// The restore was NOT attempted, deliberately. Something already existed at
            /// `intendedDirectory` when recovery reached it — this function had just emptied
            /// that path itself, so anything there was created by something outside this
            /// process. Deleting it to make room would destroy a stranger's data on the
            /// strength of a guess, so the original is left at `originalAudioDirectory` and the
            /// caller is told where it is. See `commit(stagingDirectory:to:using:)`.
            case destinationOccupied
        }

        /// Human-readable, actionable, and safe to show verbatim: names both paths and the exact
        /// command that completes the recovery.
        var message: String {
            let obstruction: String
            switch reason {
            case .destinationOccupied:
                obstruction = "something else had already created a file or folder at the "
                    + "destination, and it was left untouched rather than deleted"
            case .restoreFailed(let underlying):
                obstruction = "moving it back failed: \(underlying)"
            }
            return """
                The previous audio export could not be replaced, and could not be put back where \
                it belongs. THE ORIGINAL AUDIO IS SAFE AND COMPLETE — it is at:
                    \(originalAudioDirectory.path)
                instead of:
                    \(intendedDirectory.path)
                Restore it by hand with:
                    mv "\(originalAudioDirectory.path)" "\(intendedDirectory.path)"
                The replacement failed because: \(commitFailure)
                Recovery could not finish because \(obstruction).
                """
        }
    }

    enum ExportError: Error, Equatable, Sendable {
        /// `AudioSources` had every field `nil` — nothing to write. Mirrors real
        /// Transcripted's own `RecordingAudioArchiver.archive` guard (`micURL != nil ||
        /// systemURL != nil`): an audio directory with zero files would be a worse signal than
        /// no directory at all.
        case noAudioSources
        case exportSessionUnavailable
        case transcodeFailed
        /// A re-export left the original audio somewhere other than its documented path. Never
        /// data loss, always recoverable by hand — see `RollbackFailure`.
        case rollbackFailed(RollbackFailure)
    }

    // MARK: - Filesystem seam

    /// The directory-level filesystem operations `export` and `commit` perform, injected rather
    /// than called directly on `FileManager`.
    ///
    /// This exists for ONE reason: the recovery paths in `commit` must be proven by tests that
    /// FORCE the failure, not by tests that describe it — and the two failures that matter
    /// (`staging -> final` fails, then `backup -> final` also fails, or the destination is
    /// occupied when recovery reaches it) cannot be provoked through the real `FileManager`.
    /// Both live strictly BETWEEN two renames inside a single synchronous call, so a test has no
    /// moment at which to intervene: there is no permission bit, flag or path shape that makes
    /// the second rename of a sibling directory fail while the first, structurally identical
    /// one succeeds. Injecting the operation is the only way to exercise the branch that exists
    /// to protect audio nobody can re-record, and untested recovery code is how this exporter
    /// shipped a swallowed rollback failure in the first place.
    ///
    /// The same `@Sendable`-closure seam this feature area already uses for exactly this purpose
    /// — see `StreamingVadController.processStreamChunk` and
    /// `FluidAudioMeetingDiarizer.loadModels`. Production always uses `.live`, which is the
    /// parameter's default, so no caller passes anything and no production behaviour changes.
    /// Per-FILE writes (`writeAudioFile`) deliberately do NOT go through this seam: their
    /// failure modes are provokable for real with a corrupt source, and the existing tests do
    /// exactly that.
    struct FileOperations: Sendable {
        var exists: @Sendable (URL) -> Bool
        var createDirectory: @Sendable (URL) throws -> Void
        var move: @Sendable (URL, URL) throws -> Void
        var remove: @Sendable (URL) throws -> Void

        static let live = FileOperations(
            exists: { FileManager.default.fileExists(atPath: $0.path) },
            createDirectory: {
                try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
            },
            move: { try FileManager.default.moveItem(at: $0, to: $1) },
            remove: { try FileManager.default.removeItem(at: $0) }
        )
    }

    // MARK: - Planning

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

    // MARK: - Export

    /// Writes `sources` into `<directory>/<stem>_audio/` per `plan(meeting:sources:)` and
    /// returns its URL. Every item is staged into a throwaway sibling directory first; only once
    /// ALL of them have succeeded is that staging directory swapped into the final path by
    /// `commit(stagingDirectory:to:using:)`.
    ///
    /// See this file's header, "ATOMICITY, AND ITS EXACT LIMITS", for what that does and does not
    /// guarantee. In short, for the failures this function can actually observe: nothing partial
    /// ever appears at the destination path, and a pre-existing export there is never destroyed —
    /// on any item failure the final directory (existing or not) is left byte-for-byte as it was,
    /// and the staging directory is discarded on a best-effort basis, its path logged if that
    /// removal itself fails. `fileOperations` defaults to the real filesystem and exists so the
    /// recovery paths can be tested by forcing their failures; see `FileOperations`.
    @discardableResult
    static func export(
        meeting: Meeting,
        sources: AudioSources,
        to directory: URL,
        fileOperations: FileOperations = .live
    ) async throws -> URL {
        let resolvedPlan = try plan(meeting: meeting, sources: sources)
        let finalDirectory = directory.appendingPathComponent(resolvedPlan.audioDirectoryName, isDirectory: true)
        let stagingDirectory = directory.appendingPathComponent(
            ".TranscriptedAudioExporter-staging-\(UUID().uuidString)", isDirectory: true
        )

        try fileOperations.createDirectory(stagingDirectory)
        do {
            for item in resolvedPlan.items {
                let destinationURL = stagingDirectory.appendingPathComponent(item.destinationFilename)
                try await writeAudioFile(from: item.sourceURL, to: destinationURL)
            }
        } catch {
            discardScratchDirectory(stagingDirectory, using: fileOperations)
            throw error
        }

        do {
            try commit(stagingDirectory: stagingDirectory, to: finalDirectory, using: fileOperations)
        } catch {
            // `commit` can throw from its OWN renames, which leaves the complete staging
            // directory orphaned next to the destination. Discarding it here is three lines and
            // cannot introduce a new failure mode: the directory was created by this call, is
            // uniquely named, is referenced by nothing else, and `commit` either consumed it (in
            // which case it did not throw) or left it exactly as staged — `rename(2)` moves
            // everything or nothing. The removal is best-effort and never replaces the caller's
            // error with a housekeeping complaint.
            //
            // The ONE exception is a rollback failure. There the destination is in a state a
            // human has to sort out by hand, guided by the path in the error, and this staging
            // directory is a complete assembled copy of the new export sitting right next to it.
            // Deleting evidence out from under that recovery is precisely the reflex this whole
            // change exists to remove, so the directory is kept and its path logged instead.
            if isRollbackFailure(error) {
                logger.error(
                    """
                    Kept staged export at \(stagingDirectory.lastPathComponent, privacy: .public) \
                    under \(directory.path, privacy: .public): a rollback failure needs manual \
                    recovery and this is the assembled replacement.
                    """
                )
            } else {
                discardScratchDirectory(stagingDirectory, using: fileOperations)
            }
            throw error
        }
        return finalDirectory
    }

    /// Swaps a fully-populated `stagingDirectory` into `finalDirectory`'s place. `stagingDirectory`
    /// and the backup directory are both siblings of `finalDirectory` (same parent, guaranteed
    /// same volume), so every move here is a single `rename(2)`, not a cross-volume copy+delete —
    /// that is what makes each INDIVIDUAL step atomic at the filesystem level. The pair is not one
    /// atomic unit; see this file's header, "ATOMICITY, AND ITS EXACT LIMITS", for the kill window
    /// that leaves and why it is not closed with `renameatx_np`.
    ///
    /// - No prior export exists: one rename, done, genuinely atomic.
    /// - A prior export exists (a re-export): the existing directory is renamed ASIDE first (never
    ///   deleted), the staging directory is renamed into the now-empty final path, and only THEN is
    ///   the aside copy removed.
    ///
    /// If that second rename fails, recovery runs and there are exactly three outcomes, none of
    /// which loses the original audio and none of which is silent:
    /// 1. The aside copy is renamed back and the ORIGINAL commit error propagates — the caller
    ///    learns the re-export failed, and the destination is byte-for-byte as it was.
    /// 2. Renaming it back fails: `ExportError.rollbackFailed(.restoreFailed)`, carrying the path
    ///    the original is actually at.
    /// 3. Something has appeared at `finalDirectory` in the meantime: the delete is REFUSED, not
    ///    performed. This function emptied that path itself moments earlier, so anything there now
    ///    was created by something outside this process, and a recursive delete would destroy a
    ///    stranger's data on the strength of a guess that it is our own debris. The original stays
    ///    at the backup path and `ExportError.rollbackFailed(.destinationOccupied)` names it.
    ///
    /// An earlier version did `try? remove(final)` then `try? move(backup, final)` here, which got
    /// both of those wrong at once: it blind-deleted whatever it found, and it discarded the result
    /// of the restore, so a failed restore surfaced as the unrelated commit error while a complete
    /// recording sat under an unguessable UUID name.
    private static func commit(
        stagingDirectory: URL,
        to finalDirectory: URL,
        using fileOperations: FileOperations
    ) throws {
        guard fileOperations.exists(finalDirectory) else {
            try fileOperations.move(stagingDirectory, finalDirectory)
            return
        }

        let backupDirectory = finalDirectory.deletingLastPathComponent().appendingPathComponent(
            ".TranscriptedAudioExporter-backup-\(UUID().uuidString)", isDirectory: true
        )
        try fileOperations.move(finalDirectory, backupDirectory)

        do {
            try fileOperations.move(stagingDirectory, finalDirectory)
        } catch {
            guard !fileOperations.exists(finalDirectory) else {
                throw ExportError.rollbackFailed(RollbackFailure(
                    originalAudioDirectory: backupDirectory,
                    intendedDirectory: finalDirectory,
                    reason: .destinationOccupied,
                    commitFailure: String(describing: error)
                ))
            }
            do {
                try fileOperations.move(backupDirectory, finalDirectory)
            } catch let restoreError {
                throw ExportError.rollbackFailed(RollbackFailure(
                    originalAudioDirectory: backupDirectory,
                    intendedDirectory: finalDirectory,
                    reason: .restoreFailed(String(describing: restoreError)),
                    commitFailure: String(describing: error)
                ))
            }
            throw error
        }

        discardScratchDirectory(backupDirectory, using: fileOperations)
    }

    /// Best-effort removal of a staging or backup directory this exporter itself created, with
    /// the failure LOGGED rather than swallowed. A cleanup that fails here is debris, never data
    /// loss — by the time this is called the audio is already exactly where it belongs — so it is
    /// reported rather than escalated into the caller's error, which would replace a useful
    /// diagnosis with a housekeeping complaint, or worse, fail an export that actually succeeded.
    ///
    /// Only scratch paths are logged, and only as a public parent + dot-prefixed UUID name: those
    /// carry no meeting title. The final directory's name does carry one, so it is never logged —
    /// it reaches the user through `RollbackFailure.message` instead, where it is needed to act on.
    private static func discardScratchDirectory(_ url: URL, using fileOperations: FileOperations) {
        do {
            try fileOperations.remove(url)
        } catch {
            logger.error(
                """
                Failed to remove leftover scratch directory \
                \(url.lastPathComponent, privacy: .public) under \
                \(url.deletingLastPathComponent().path, privacy: .public): \
                \(String(describing: error), privacy: .public). It is inert — dot-prefixed, \
                uniquely named, and not at any Transcripted destination path — but it will not \
                clean itself up.
                """
            )
        }
    }

    private static func isRollbackFailure(_ error: any Error) -> Bool {
        guard let exportError = error as? ExportError else { return false }
        if case .rollbackFailed = exportError { return true }
        return false
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

/// Makes `rollbackFailed`'s recovery instructions reach anything that shows an error to a
/// person — an `NSAlert`, a `Text(error.localizedDescription)`, a log line — without that
/// caller needing to know this enum exists. The whole point of `RollbackFailure` is that the
/// path to the audio survives the trip out of this type; a default `Error` description
/// ("The operation couldn't be completed") would throw it away at the last step.
extension TranscriptedAudioExporter.ExportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noAudioSources:
            return "This meeting has no audio to export."
        case .exportSessionUnavailable:
            return "Could not start an audio export session for this meeting."
        case .transcodeFailed:
            return "This meeting's audio could not be converted to M4A."
        case .rollbackFailed(let failure):
            return failure.message
        }
    }
}

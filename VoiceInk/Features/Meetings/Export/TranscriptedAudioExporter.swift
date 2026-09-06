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
//   circumstance. That is now enforced rather than merely intended: a source living INSIDE the
//   destination tree (or inside one of this exporter's own scratch directories under the same
//   root) would be carried aside with the old export and then deleted with the backup by a
//   SUCCESSFUL re-export — losing a WAV original and leaving only the lossy M4A derived from it.
//   Such a source is rejected up front with `ExportError.sourceInsideDestination`, before
//   anything is created or moved. See `validateSourcesAreOutside`.
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
        /// A supplied source lives inside the directory tree this export is about to replace, or
        /// inside one of this exporter's own scratch directories under the same root — both places
        /// a SUCCESSFUL export moves or deletes. Rejected before anything is created or moved, so
        /// nothing has happened when this is thrown. See `validateSourcesAreOutside`.
        case sourceInsideDestination(source: URL, container: URL)
    }

    // MARK: - Scratch naming

    /// Every scratch directory this exporter creates is a sibling of the destination whose name
    /// begins with this. Hoisted to one constant because three separate things have to agree on
    /// it exactly: the names created below, the source-containment guard, and the fault
    /// injector's prefix match.
    static let scratchPrefix = ".TranscriptedAudioExporter-"
    private static let stagingPrefix = scratchPrefix + "staging-"
    private static let backupPrefix = scratchPrefix + "backup-"

    // MARK: - Fault injection

    /// A closed, declarative description of failures this exporter can be asked to simulate. It is
    /// the ONLY thing a caller may inject, and it exists because the recovery branches in `commit`
    /// must be proven by tests that FORCE the failure rather than describe it: those branches live
    /// strictly BETWEEN two renames inside one synchronous call, so a test has no moment at which
    /// to intervene, and no permission bit, `chflags` flag or path shape makes the second rename of
    /// a sibling directory fail while the first, structurally identical one succeeds.
    ///
    /// **THIS TYPE DELIBERATELY CARRIES NO CODE, AND THAT IS THE WHOLE POINT.** The previous design
    /// was a struct of `@Sendable` closures, and review defeated it in one line three different
    /// ways — a `move` that returned success without moving anything, a `move` that deleted the
    /// source and reported success, and a copy-then-delete substituted for `rename(2)` — each of
    /// which let `export` return SUCCESS with the previous export silently destroyed. That was the
    /// fourth time on this project that a test-only seam was defended as safe-by-convention and
    /// then broken, so the capability is removed rather than documented away: a value of this type
    /// is pure data, so it cannot perform, skip, substitute, reorder or observe a filesystem
    /// operation, and it cannot report that a rename happened when it did not. Those three attacks
    /// are no longer things nobody writes; they are things that do not compile, which is asserted
    /// on every CI run by `scripts/negative-controls/TranscriptedAudioExportSeamAttacks.swift`.
    ///
    /// **The residual capability, stated rather than glossed:** a caller passing a non-`.none`
    /// value can make an export FAIL that would have succeeded, and can cause the simulated
    /// concurrent writer below to create a marker directory and a marker file at the destination on
    /// a path that is already failing. Neither can lose audio: nothing here deletes, the marker
    /// write is create-only (`.withoutOverwriting`, so it cannot replace a file that is already
    /// there — an earlier version used plain `Data.write(to:)` and could), and a failing export
    /// leaves the original either at its own path or at the backup path named in the thrown error.
    /// That is a bug a caller could cause, not the data-loss class this guard exists to close, and
    /// it is bounded by the type rather than by a comment.
    ///
    /// **ONE SHAPE OF CLOSURE CANNOT BE ADDED BACK, and the compiler says so — but it is one
    /// shape, not the class.** The `Equatable` conformance below is SYNTHESISED, and Swift only
    /// synthesises it when every stored property is itself `Equatable`. A closure is not. So a
    /// DIRECTLY STORED closure-typed property fails to build today, under any name, with `type
    /// 'TranscriptedAudioExporter.FaultInjection' does not conform to protocol 'Equatable'`.
    /// Verified empirically by planting `var operationOverride: (() -> Void)?` and running a full
    /// `xcodebuild`, not by reasoning about it.
    ///
    /// **WHAT THAT DOES NOT COVER.** An earlier version of this comment claimed the barrier held
    /// for "any closure-bearing stored field" and that a hand-written `==` was the only way past
    /// it. That was broader than what was tested, and review named four ways through it that leave
    /// synthesis intact and both barrier controls green:
    /// 1. a stored field whose type is an `Equatable`, `@unchecked Sendable` WRAPPER that itself
    ///    contains a closure — the stored property is `Equatable`, so synthesis is untroubled;
    /// 2. a property wrapper whose stored backing type is `Equatable` while its `wrappedValue` is
    ///    a closure — same reason, one level of indirection further;
    /// 3. a COMPUTED closure property or a method, including one added in an extension — no stored
    ///    property is involved at all, so synthesis never looks at it;
    /// 4. a hand-written `static func ==`, which suppresses synthesis outright.
    /// The first two restore a fully executable `operationOverride`-equivalent seam. So the honest
    /// statement is: synthesised `Equatable` blocks the OBVIOUS re-introduction, and nothing here
    /// blocks a determined one. Detecting the rest needs source-signature or AST machinery whose
    /// own correctness would then need verifying and which rots when the source layout changes;
    /// that is deliberately not built. See FOLLOWUPS.md, "the barrier covers directly stored
    /// closures only".
    ///
    /// `Equatable` is still load-bearing for what it does cover and must not be removed or
    /// hand-implemented; `TranscriptedAudioExportSeamEquatableBarrierAttack.swift` fails the build
    /// if the conformance is dropped. `Sendable` is NOT a barrier in this build: the project
    /// compiles at `SWIFT_VERSION 5.0` with no strict concurrency, so a non-`Sendable` stored
    /// closure only WARNS here. Its control pins a barrier that becomes real under the Swift 6
    /// language mode, and enforces nothing today.
    struct FaultInjection: Equatable, Sendable {
        /// Make any directory rename whose SOURCE directory name begins with one of these prefixes
        /// throw `SimulatedRenameFailure` instead of running. It cannot make a rename succeed, and
        /// cannot change what a rename that does run actually does.
        var failRenamesOfDirectoriesPrefixed: [String] = []

        /// Simulate ANOTHER PROCESS claiming the destination path in the window between a
        /// re-export's two renames. This is the one condition `.destinationOccupied` exists to
        /// handle and the only one a test cannot produce for itself, for the reason above. It only
        /// ever runs on an already-failing path, and it creates WITHOUT OVERWRITING — enforced by
        /// `.withoutOverwriting` in `simulateConcurrentWriterClaiming`, not by this sentence.
        var simulateConcurrentWriterAtDestination = false

        /// Production. Every caller gets this by default and no caller passes anything else.
        static let none = FaultInjection()

        /// What the simulated concurrent writer leaves behind, so a test can assert those exact
        /// bytes survived a recovery that must never delete what it finds.
        static let concurrentWriterFilename = "written-by-another-process.txt"
        static let concurrentWriterContents = "simulated concurrent writer"

        /// Thrown by a rename this value declared should fail. A distinct type, so a test can tell
        /// "the fault fired" apart from "something genuinely went wrong", and so it can never be
        /// mistaken for one of `ExportError`'s real cases.
        struct SimulatedRenameFailure: Error, Equatable {
            let source: URL
        }

        fileprivate func shouldFailRename(of source: URL) -> Bool {
            failRenamesOfDirectoriesPrefixed.contains { source.lastPathComponent.hasPrefix($0) }
        }
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
    /// removal itself fails.
    ///
    /// Throws `ExportError.sourceInsideDestination` before touching anything if a source lives
    /// where a SUCCESSFUL export would consume it; see `validateSourcesAreOutside`. `faults`
    /// defaults to `.none` and exists so the recovery paths can be tested by forcing their
    /// failures; it is pure data and cannot alter what any filesystem operation does. See
    /// `FaultInjection`.
    @discardableResult
    static func export(
        meeting: Meeting,
        sources: AudioSources,
        to directory: URL,
        faults: FaultInjection = .none
    ) async throws -> URL {
        let resolvedPlan = try plan(meeting: meeting, sources: sources)
        let fileManager = FileManager.default
        let finalDirectory = directory.appendingPathComponent(resolvedPlan.audioDirectoryName, isDirectory: true)

        // BEFORE anything is created or moved. A source inside the destination tree is consumed by
        // a SUCCESSFUL export, and nothing after this point could undo that, so nothing before it
        // is allowed to have happened.
        try validateSourcesAreOutside(resolvedPlan, destinationRoot: directory, finalDirectory: finalDirectory)

        let stagingDirectory = directory.appendingPathComponent(
            stagingPrefix + UUID().uuidString, isDirectory: true
        )

        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        do {
            for item in resolvedPlan.items {
                let destinationURL = stagingDirectory.appendingPathComponent(item.destinationFilename)
                try await writeAudioFile(from: item.sourceURL, to: destinationURL)
            }
        } catch {
            discardScratchDirectory(stagingDirectory)
            throw error
        }

        do {
            try commit(stagingDirectory: stagingDirectory, to: finalDirectory, faults: faults)
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
                discardScratchDirectory(stagingDirectory)
            }
            throw error
        }
        return finalDirectory
    }

    // MARK: - Source containment guard

    /// Rejects any source that lives inside the directory tree this export is about to replace, or
    /// inside one of this exporter's own scratch directories under the same root.
    ///
    /// This guard exists because the promise in this file's header — that the exporter never
    /// deletes, moves or modifies a supplied source, under ANY circumstance — was not true for such
    /// a source, and the way it failed was both silent and unrecoverable. A SUCCESSFUL re-export
    /// renames the old destination aside to the backup, taking anything living inside it along, and
    /// then removes that backup once the replacement is in place. For a WAV source that leaves the
    /// user holding only the lossy M4A this exporter derived from it, with the original gone and
    /// the export reporting success. That is the worst outcome available here: not a failure, not a
    /// partial write, but a clean "done" over the top of the only copy of a recording.
    ///
    /// It is rejected rather than tolerated because it is a caller error with no legitimate shape:
    /// nothing sensible stores a capture inside the very directory that capture is exported into.
    /// The claim in the header is kept true by making the case impossible, not by narrowing it.
    ///
    /// Containment is decided on RESOLVED, STANDARDISED paths, so `/tmp` against `/private/tmp`, a
    /// symlinked parent, or a `..` segment cannot walk a source past the guard; and COMPONENT-WISE,
    /// so a sibling directory named `<stem>_audio-old` is never mistaken for something inside
    /// `<stem>_audio`.
    private static func validateSourcesAreOutside(
        _ resolvedPlan: ExportPlan,
        destinationRoot: URL,
        finalDirectory: URL
    ) throws {
        let rootComponents = resolvedComponents(destinationRoot)
        let finalComponents = resolvedComponents(finalDirectory)

        for item in resolvedPlan.items {
            let sourceComponents = resolvedComponents(item.sourceURL)

            if isContained(sourceComponents, in: finalComponents) {
                throw ExportError.sourceInsideDestination(source: item.sourceURL, container: finalDirectory)
            }

            // The scratch directories are siblings of the destination under the same root, and this
            // exporter DELETES them. A source inside one — a caller reaching into a leftover backup
            // to recover audio after a rollback failure, which is exactly what that error tells
            // them to do — must not then be exported from the one place it can be swept away.
            guard isContained(sourceComponents, in: rootComponents) else { continue }
            for depth in rootComponents.count..<sourceComponents.count
            where sourceComponents[depth].hasPrefix(scratchPrefix) {
                var container = URL(fileURLWithPath: "/", isDirectory: true)
                for component in sourceComponents[1...depth] {
                    container.appendPathComponent(component)
                }
                throw ExportError.sourceInsideDestination(source: item.sourceURL, container: container)
            }
        }
    }

    /// Path components after standardising, resolving symlinks, and standardising again — the
    /// second pass matters because resolving can reintroduce a `..` from a symlink's target.
    private static func resolvedComponents(_ url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    }

    /// True when `candidate` IS `container` or lies beneath it. Compared component-wise, never as a
    /// string prefix, so `/a/bc` is not treated as inside `/a/b`.
    private static func isContained(_ candidate: [String], in container: [String]) -> Bool {
        candidate.count >= container.count && Array(candidate.prefix(container.count)) == container
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
        faults: FaultInjection
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: finalDirectory.path) else {
            try moveDirectory(from: stagingDirectory, to: finalDirectory, faults: faults)
            return
        }

        let backupDirectory = finalDirectory.deletingLastPathComponent().appendingPathComponent(
            backupPrefix + UUID().uuidString, isDirectory: true
        )
        try moveDirectory(from: finalDirectory, to: backupDirectory, faults: faults)

        do {
            try moveDirectory(from: stagingDirectory, to: finalDirectory, faults: faults)
        } catch {
            // TEST FAULT, and the ONLY filesystem mutation `FaultInjection` can cause. It stands in
            // for another process creating something at the destination in the window between the
            // two renames -- the single condition `.destinationOccupied` exists to handle, and the
            // only one a test cannot produce for itself. It runs only on an already-failing path,
            // and it CREATES WITHOUT EVER OVERWRITING: see `simulateConcurrentWriterClaiming`.
            if faults.simulateConcurrentWriterAtDestination {
                simulateConcurrentWriterClaiming(finalDirectory)
            }
            guard !fileManager.fileExists(atPath: finalDirectory.path) else {
                throw ExportError.rollbackFailed(RollbackFailure(
                    originalAudioDirectory: backupDirectory,
                    intendedDirectory: finalDirectory,
                    reason: .destinationOccupied,
                    commitFailure: String(describing: error)
                ))
            }
            do {
                try moveDirectory(from: backupDirectory, to: finalDirectory, faults: faults)
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

        discardScratchDirectory(backupDirectory)
    }

    /// The ONE place a directory rename happens. `FaultInjection` can do exactly one thing to it:
    /// decide that a rename which would otherwise have run throws instead. It cannot perform the
    /// rename itself, skip it, substitute a non-atomic copy-then-delete for `rename(2)`, or report
    /// that it happened when it did not — because it is a value carrying no code. That is what
    /// makes "production always does the real thing" a property of the types rather than a claim
    /// about today's call sites.
    private static func moveDirectory(from source: URL, to destination: URL, faults: FaultInjection) throws {
        if faults.shouldFailRename(of: source) {
            throw FaultInjection.SimulatedRenameFailure(source: source)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    /// The simulated concurrent writer's entire effect on disk. Factored out so its create-only
    /// guarantee can be tested directly, and INTERNAL rather than private for that reason.
    ///
    /// Testing it directly is deliberate, not convenient: through `export` the collision is
    /// UNREACHABLE. `commit` renames the destination aside before this ever runs, so the path is
    /// always empty by the time it does, and the only way a file of this name is already there is
    /// the genuine race this stands in for. A test driving `export` cannot produce the collision at
    /// all, so one that claimed to would be asserting nothing.
    ///
    /// `.withoutOverwriting` is the load-bearing part, and it is the fix for a real overclaim.
    /// `Data.write(to:)` alone REPLACES an existing file, so a real concurrent writer that had
    /// already put a file of this name at the destination would have had it silently clobbered —
    /// while the doc two paragraphs up said this "only ever CREATES" and therefore could not lose
    /// audio. The destination is an audio directory, so the file destroyed could have been
    /// somebody's recording. What `.withoutOverwriting` guarantees is the property this needs and
    /// only that: the write ATOMICALLY REFUSES an existing destination rather than replacing it.
    /// (An earlier version of this comment promised one `O_CREAT|O_EXCL` syscall. Foundation
    /// documents the refusal, not the mechanism, so that was a claim about a presumed
    /// implementation.) Checking `fileExists` first and then writing is not an alternative: that
    /// re-opens the same race with more steps, which is exactly what the atomic refusal closes.
    ///
    /// A failure here is deliberately NOT propagated. This function's only purpose is to make the
    /// destination occupied, and if the write failed because a file was already there then it IS
    /// occupied and `commit`'s guard reports exactly that. Throwing would replace the
    /// `rollbackFailed` error — the one thing that tells the user where their audio actually is —
    /// with a complaint about a test fixture. It is logged instead, and logged WITHOUT the path:
    /// the destination's name carries the meeting title, and this file never logs that (see
    /// `discardScratchDirectory`), which is also why the underlying error's own description is not
    /// logged — a Cocoa file error embeds the path it failed on.
    static func simulateConcurrentWriterClaiming(_ directory: URL) {
        do {
            // Succeeds silently when the directory already exists, and never touches its contents.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(FaultInjection.concurrentWriterContents.utf8).write(
                to: directory.appendingPathComponent(FaultInjection.concurrentWriterFilename),
                options: .withoutOverwriting
            )
        } catch {
            let nsError = error as NSError
            logger.error(
                """
                Simulated concurrent writer did not place \
                \(FaultInjection.concurrentWriterFilename, privacy: .public): \
                \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public). Something \
                was already at that path, which is the condition being simulated anyway, so the \
                rollback error stands rather than being replaced by this.
                """
            )
        }
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
    private static func discardScratchDirectory(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
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
        case .sourceInsideDestination(let source, let container):
            return """
                This meeting's audio cannot be exported from inside the folder it is being \
                exported into — a successful export would move or delete the original. Move it \
                somewhere else first, then export again.
                    Source: \(source.path)
                    Inside: \(container.path)
                Nothing was created, moved or deleted.
                """
        }
    }
}

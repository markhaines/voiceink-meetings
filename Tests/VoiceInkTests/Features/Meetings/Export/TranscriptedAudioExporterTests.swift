// Fork-only file, no upstream equivalent. Sibling of `TranscriptedMarkdownExporterTests.swift`
// for `TranscriptedAudioExporter.swift` — see that file's header for the real-directory
// evidence (`~/Library/CloudStorage/OneDrive-ATEME/Transcripted/meetings/audio/` on Mark's Mac
// Studio) and the real Transcripted source (`~/code/transcripted`) this exporter's design is
// based on.
//
// No real Transcripted audio is used or committed here — every source file these tests export
// is synthesized on the fly with `MeetingRecordingWriter`, this fork's own audio writer, which
// is already fully covered by `MeetingRecordingWriterTests.swift`. That keeps this suite
// self-contained (no external binary, no gate-running mode needed — unlike
// `TranscriptedIndexerAcceptanceTests.swift`, there is no real-app dependency to gate on here)
// and keeps every byte this suite touches disposable: nothing here ever reads, writes, or
// resembles a real meeting recording.
//
// FIX ROUND: `final class` (was `struct`) so `deinit` can remove every temporary directory this
// suite creates -- Swift Testing instantiates a fresh instance per test function, so `deinit`
// runs once per test, pass or fail, exactly like an XCTest `tearDown`.

import AVFoundation
import Foundation
import Testing
@testable import VoiceInk

@Suite("TranscriptedAudioExporter")
final class TranscriptedAudioExporterTests {
    // MARK: - Fixtures / teardown

    private static var referenceDate: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 31
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private static func makeMeeting(title: String = "Meeting at 4:00 pm") -> Meeting {
        Meeting(title: title, startDate: referenceDate, audioDirectoryPath: "/tmp/unused")
    }

    private var createdDirectories: [URL] = []

    deinit {
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripted-audio-exporter-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        createdDirectories.append(url)
        return url
    }

    /// A real, valid WAV file this fork's own writer produced — not hand-crafted bytes and not
    /// a real meeting recording. `samples` defaults to something long enough that
    /// `AVAssetExportSession` won't reject it as degenerate.
    private func makeWAVFile(in directory: URL, samples: [Int16] = Array(repeating: 1200, count: 16_000)) throws -> URL {
        let writer = try MeetingRecordingWriter()
        writer.appendMic(samples)
        let tempURL = try #require(writer.stop())
        let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    /// A real, valid M4A file, transcoded by this fork's own writer from a synthesized WAV —
    /// used to exercise the "source is already M4A" copy path without a real recording.
    private func makeM4AFile(in directory: URL) async throws -> URL {
        let wavURL = try makeWAVFile(in: directory)
        return try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: wavURL,
            meetingTitle: "synthetic fixture",
            startedAt: Date(timeIntervalSince1970: 1_711_000_000),
            supportDirectory: makeTemporaryDirectory()
        )
    }

    // MARK: - plan(meeting:sources:) — pure, no filesystem

    /// The load-bearing cross-file contract: the audio directory's stem MUST be byte-identical
    /// to `TranscriptedMarkdownExporter`'s own filename stem for the same meeting, or the two
    /// halves silently point at different names. Same date/title as that suite's
    /// `filenameSanitizesColon` test, so both suites are pinned to the same real evidence.
    @Test("audio directory name reuses the markdown exporter's exact stem, plus '_audio'")
    func audioDirectoryNameMatchesMarkdownExporterStem() throws {
        let meeting = Self.makeMeeting(title: "Meeting at 4:00 pm")
        let sources = TranscriptedAudioExporter.AudioSources(playbackURL: URL(fileURLWithPath: "/tmp/playback.wav"))

        let plan = try TranscriptedAudioExporter.plan(meeting: meeting, sources: sources)

        #expect(plan.audioDirectoryName == "2026-07-31 Meeting at 4 00 pm_audio")
        #expect(
            plan.audioDirectoryName
                == TranscriptedMarkdownExporter.renderStem(date: meeting.startDate, title: meeting.title) + "_audio"
        )
    }

    @Test("only a playback source plans a single playback.m4a item")
    func playbackOnlyPlansSingleItem() throws {
        let sources = TranscriptedAudioExporter.AudioSources(playbackURL: URL(fileURLWithPath: "/tmp/playback.wav"))
        let plan = try TranscriptedAudioExporter.plan(meeting: Self.makeMeeting(), sources: sources)

        #expect(plan.items.map(\.channel) == [.playback])
        #expect(plan.items.map(\.destinationFilename) == ["playback.m4a"])
    }

    @Test("only a microphone source plans a single microphone.m4a item")
    func microphoneOnlyPlansSingleItem() throws {
        let sources = TranscriptedAudioExporter.AudioSources(microphoneURL: URL(fileURLWithPath: "/tmp/mic.wav"))
        let plan = try TranscriptedAudioExporter.plan(meeting: Self.makeMeeting(), sources: sources)

        #expect(plan.items.map(\.channel) == [.microphone])
        #expect(plan.items.map(\.destinationFilename) == ["microphone.m4a"])
    }

    /// FIX ROUND (BLOCKING 1): a system-only source must plan `recording.m4a`, NOT
    /// `system_audio.m4a` -- real Transcripted's `RecordingAudioArchiver.archive` only uses the
    /// `system_audio` stem when a microphone source is ALSO present; the lone surviving capture
    /// is named `recording` instead, because "system_audio" implies a sibling mic track that,
    /// in this shape, was never captured. The first version of this file documented that rule
    /// and then did not implement it -- this test's expected value was wrong before this fix and
    /// is corrected here, not weakened: it is still a single exact-match assertion, now checked
    /// against the behavior the file's own header always claimed.
    @Test("a system-audio-only source plans as recording.m4a, not system_audio.m4a, when no microphone is present")
    func systemAudioOnlyPlansAsRecordingWhenMicrophoneAbsent() throws {
        let sources = TranscriptedAudioExporter.AudioSources(systemAudioURL: URL(fileURLWithPath: "/tmp/sys.wav"))
        let plan = try TranscriptedAudioExporter.plan(meeting: Self.makeMeeting(), sources: sources)

        #expect(plan.items.map(\.channel) == [.systemAudio])
        #expect(plan.items.map(\.destinationFilename) == ["recording.m4a"])
    }

    /// Mirrors the real `Failed_2026-08-28_07-59-41_DBB620D5_audio/` capture found on Mark's
    /// Mac Studio: mic + system present, playback absent (never derived because the mix never
    /// ran). This exporter has no equivalent "mix" step, but the missing-channel shape — omit
    /// the absent one, keep the present ones — must still hold. Mic is present here, so the
    /// system item keeps its `system_audio.m4a` name (the `recording.m4a` rename only applies
    /// when mic is absent) -- see `exportMicAndSystemWithoutPlaybackWritesExactlyThoseTwoFiles`
    /// for the filesystem-level proof of this same shape.
    @Test("mic and system present, playback absent, plans exactly those two in a fixed order")
    func micAndSystemPresentPlaybackAbsent() throws {
        let sources = TranscriptedAudioExporter.AudioSources(
            microphoneURL: URL(fileURLWithPath: "/tmp/mic.wav"),
            systemAudioURL: URL(fileURLWithPath: "/tmp/sys.wav")
        )
        let plan = try TranscriptedAudioExporter.plan(meeting: Self.makeMeeting(), sources: sources)

        #expect(plan.items.map(\.channel) == [.microphone, .systemAudio])
        #expect(plan.items.map(\.destinationFilename) == ["microphone.m4a", "system_audio.m4a"])
    }

    @Test("all three sources present plan all three items in microphone/system/playback order")
    func allThreeSourcesPlanAllThreeItemsInFixedOrder() throws {
        let sources = TranscriptedAudioExporter.AudioSources(
            microphoneURL: URL(fileURLWithPath: "/tmp/mic.wav"),
            systemAudioURL: URL(fileURLWithPath: "/tmp/sys.wav"),
            playbackURL: URL(fileURLWithPath: "/tmp/playback.wav")
        )
        let plan = try TranscriptedAudioExporter.plan(meeting: Self.makeMeeting(), sources: sources)

        #expect(plan.items.map(\.channel) == [.microphone, .systemAudio, .playback])
        #expect(plan.items.map(\.destinationFilename) == ["microphone.m4a", "system_audio.m4a", "playback.m4a"])
    }

    @Test("no sources at all refuses to plan anything")
    func noSourcesThrowsNoAudioSources() {
        #expect(throws: TranscriptedAudioExporter.ExportError.noAudioSources) {
            try TranscriptedAudioExporter.plan(meeting: Self.makeMeeting(), sources: TranscriptedAudioExporter.AudioSources())
        }
    }

    // MARK: - export(meeting:sources:to:) — real filesystem, temporary directories only

    @Test("export transcodes a WAV source to the correct destination filename")
    func exportTranscodesWAVSource() async throws {
        let scratch = makeTemporaryDirectory()
        let wavURL = try makeWAVFile(in: scratch)
        let sources = TranscriptedAudioExporter.AudioSources(playbackURL: wavURL)
        let destinationRoot = makeTemporaryDirectory()

        let audioDirectory = try await TranscriptedAudioExporter.export(
            meeting: Self.makeMeeting(),
            sources: sources,
            to: destinationRoot
        )

        #expect(audioDirectory.lastPathComponent == "2026-07-31 Meeting at 4 00 pm_audio")
        let destination = audioDirectory.appendingPathComponent("playback.m4a")
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let file = try AVAudioFile(forReading: destination)
        #expect(file.length > 0)

        // The source WAV must survive: this exporter never deletes what it was given.
        #expect(FileManager.default.fileExists(atPath: wavURL.path))
    }

    @Test("export copies an already-M4A source verbatim rather than re-transcoding it")
    func exportCopiesExistingM4ASourceVerbatim() async throws {
        let scratch = makeTemporaryDirectory()
        let m4aURL = try await makeM4AFile(in: scratch)
        let sourceData = try Data(contentsOf: m4aURL)
        let sources = TranscriptedAudioExporter.AudioSources(microphoneURL: m4aURL)
        let destinationRoot = makeTemporaryDirectory()

        let audioDirectory = try await TranscriptedAudioExporter.export(
            meeting: Self.makeMeeting(),
            sources: sources,
            to: destinationRoot
        )

        let destination = audioDirectory.appendingPathComponent("microphone.m4a")
        let destinationData = try Data(contentsOf: destination)
        #expect(destinationData == sourceData)
        #expect(FileManager.default.fileExists(atPath: m4aURL.path))
    }

    @Test("export omits files for absent channels")
    func exportOmitsFilesForAbsentChannels() async throws {
        let scratch = makeTemporaryDirectory()
        let wavURL = try makeWAVFile(in: scratch)
        let sources = TranscriptedAudioExporter.AudioSources(playbackURL: wavURL)
        let destinationRoot = makeTemporaryDirectory()

        let audioDirectory = try await TranscriptedAudioExporter.export(
            meeting: Self.makeMeeting(),
            sources: sources,
            to: destinationRoot
        )

        let contents = try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path)
        #expect(Set(contents) == ["playback.m4a"])
    }

    /// FIX ROUND (BLOCKING 1), filesystem-level proof: a mic-only export was previously covered
    /// only by a pure `plan()` test (`microphoneOnlyPlansSingleItem`), which proves what would be
    /// planned but not what actually lands on disk. This asserts the real directory contents.
    @Test("export with only a microphone source writes exactly microphone.m4a")
    func exportMicOnlyWritesExactlyMicrophoneM4A() async throws {
        let scratch = makeTemporaryDirectory()
        let wavURL = try makeWAVFile(in: scratch)
        let sources = TranscriptedAudioExporter.AudioSources(microphoneURL: wavURL)
        let destinationRoot = makeTemporaryDirectory()

        let audioDirectory = try await TranscriptedAudioExporter.export(
            meeting: Self.makeMeeting(),
            sources: sources,
            to: destinationRoot
        )

        let contents = try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path)
        #expect(Set(contents) == ["microphone.m4a"])
    }

    /// FIX ROUND (BLOCKING 1), the core regression proof: a system-only export must write
    /// `recording.m4a`, never `system_audio.m4a` -- asserted against the actual directory
    /// contents, not just the plan. This is the exact shape the review flagged as a layout real
    /// Transcripted would never write.
    @Test("export with only a system-audio source writes exactly recording.m4a")
    func exportSystemOnlyWritesExactlyRecordingM4A() async throws {
        let scratch = makeTemporaryDirectory()
        let wavURL = try makeWAVFile(in: scratch)
        let sources = TranscriptedAudioExporter.AudioSources(systemAudioURL: wavURL)
        let destinationRoot = makeTemporaryDirectory()

        let audioDirectory = try await TranscriptedAudioExporter.export(
            meeting: Self.makeMeeting(),
            sources: sources,
            to: destinationRoot
        )

        let contents = try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path)
        #expect(Set(contents) == ["recording.m4a"])
    }

    /// FIX ROUND (BLOCKING 1), filesystem-level proof of the real `Failed_*` shape: mic + system
    /// present, playback absent. Mic is present, so the system item keeps `system_audio.m4a`
    /// (the `recording.m4a` rename is only for a system-only source, proven separately above).
    @Test("export with microphone and system-audio but no playback writes exactly those two files")
    func exportMicAndSystemWithoutPlaybackWritesExactlyThoseTwoFiles() async throws {
        let scratch = makeTemporaryDirectory()
        let micURL = try makeWAVFile(in: scratch)
        let systemURL = try makeWAVFile(in: scratch)
        let sources = TranscriptedAudioExporter.AudioSources(microphoneURL: micURL, systemAudioURL: systemURL)
        let destinationRoot = makeTemporaryDirectory()

        let audioDirectory = try await TranscriptedAudioExporter.export(
            meeting: Self.makeMeeting(),
            sources: sources,
            to: destinationRoot
        )

        let contents = try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path)
        #expect(Set(contents) == ["microphone.m4a", "system_audio.m4a"])
    }

    @Test("export throws, leaves no partial file, and preserves the source when the transcode fails")
    func exportSurfacesTranscodeFailureWithoutDestroyingSource() async throws {
        let scratch = makeTemporaryDirectory()
        let brokenWAVURL = scratch.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try Data("not a real wav file".utf8).write(to: brokenWAVURL)
        let brokenWAVBytes = try Data(contentsOf: brokenWAVURL)
        let sources = TranscriptedAudioExporter.AudioSources(playbackURL: brokenWAVURL)
        let destinationRoot = makeTemporaryDirectory()

        await #expect(throws: (any Error).self) {
            _ = try await TranscriptedAudioExporter.export(
                meeting: Self.makeMeeting(),
                sources: sources,
                to: destinationRoot
            )
        }

        // The source must survive -- it is the only copy of this channel's audio. FIX ROUND 2:
        // compared BYTE-FOR-BYTE, not merely by existence, so the assertion actually checks what
        // its own wording claims. A source that had been truncated, rewritten or transcoded in
        // place would still "exist".
        let brokenWAVBytesAfter = try Data(contentsOf: brokenWAVURL)
        #expect(brokenWAVBytesAfter == brokenWAVBytes)

        // FIX ROUND (BLOCKING 2): a failed export must leave no directory at the final path at
        // all (nothing had ever existed there before this attempt) -- not an empty directory,
        // not a staging leftover anywhere under destinationRoot.
        let audioDirectory = destinationRoot.appendingPathComponent("2026-07-31 Meeting at 4 00 pm_audio")
        #expect(FileManager.default.fileExists(atPath: audioDirectory.path) == false)
        let rootContents = try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path)
        #expect(rootContents.isEmpty)
    }

    @Test("re-exporting replaces a stale destination file instead of failing")
    func reExportReplacesStaleDestinationFile() async throws {
        let scratch = makeTemporaryDirectory()
        let wavURL = try makeWAVFile(in: scratch)
        let sources = TranscriptedAudioExporter.AudioSources(playbackURL: wavURL)
        let destinationRoot = makeTemporaryDirectory()

        let audioDirectory = try await TranscriptedAudioExporter.export(
            meeting: Self.makeMeeting(),
            sources: sources,
            to: destinationRoot
        )
        let destination = audioDirectory.appendingPathComponent("playback.m4a")

        // Simulate a stale leftover from a previous, different-content export -- deliberately
        // not valid audio, so a re-export that failed to overwrite it would fail to open below.
        try Data("stale leftover bytes".utf8).write(to: destination)

        _ = try await TranscriptedAudioExporter.export(
            meeting: Self.makeMeeting(),
            sources: sources,
            to: destinationRoot
        )

        let file = try AVAudioFile(forReading: destination)
        #expect(file.length > 0)
    }

    /// FIX ROUND (BLOCKING 2), the required proof. This is the scenario the review specified
    /// exactly: an earlier VALID source (microphone) and a later BROKEN one (system-audio) in
    /// the SAME export call, attempted as a RE-export over an ALREADY-GOOD existing directory.
    ///
    /// Before the fix, this failed two ways at once: (a) the microphone item, having already
    /// been written directly into the final directory before the system item failed, was left
    /// behind next to a now-incomplete final directory; (b) because this is a re-export, the
    /// prior good `playback.m4a` export had already been deleted from the destination before
    /// the replacement's first item was even attempted, so the failure left NEITHER the old nor
    /// the new audio in place. Both are exactly the "destroys a good artefact" failure mode that
    /// matters most for audio nobody can re-record.
    ///
    /// This test's own header comment on `TranscriptedAudioExporterTests.swift` records the
    /// verbatim before/after run; see this task's report
    /// (`.tandem/884f6ef6905c4e2aa4e2ca28c34ea629/phase3-audio-export.md`, "Fix round") for the
    /// full quoted proof, since a source file is the wrong place for a multi-paragraph log.
    @Test("a failed re-export leaves the prior good export, all sources, and no staged output behind")
    func reExportFailureLeavesPriorGoodExportAndSourcesUntouched() async throws {
        let destinationRoot = makeTemporaryDirectory()
        let meeting = Self.makeMeeting()

        // Establish a genuinely successful prior export: this is the "good artefact" that must
        // survive a later failed re-export attempt untouched.
        let originalScratch = makeTemporaryDirectory()
        let originalWAVURL = try makeWAVFile(in: originalScratch, samples: Array(repeating: 4321, count: 16_000))
        let originalSources = TranscriptedAudioExporter.AudioSources(playbackURL: originalWAVURL)
        let audioDirectory = try await TranscriptedAudioExporter.export(
            meeting: meeting,
            sources: originalSources,
            to: destinationRoot
        )
        let originalDestination = audioDirectory.appendingPathComponent("playback.m4a")
        let originalBytes = try Data(contentsOf: originalDestination)
        #expect(!originalBytes.isEmpty)

        // Attempt a re-export: microphone (earlier in plan order, valid) succeeds, system-audio
        // (later, broken) fails.
        let retryScratch = makeTemporaryDirectory()
        let validMicURL = try makeWAVFile(in: retryScratch, samples: Array(repeating: 999, count: 16_000))
        let brokenSystemURL = retryScratch.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try Data("not a real wav file".utf8).write(to: brokenSystemURL)
        let validMicBytes = try Data(contentsOf: validMicURL)
        let brokenSystemBytes = try Data(contentsOf: brokenSystemURL)
        let retrySources = TranscriptedAudioExporter.AudioSources(
            microphoneURL: validMicURL,
            systemAudioURL: brokenSystemURL
        )

        await #expect(throws: (any Error).self) {
            _ = try await TranscriptedAudioExporter.export(meeting: meeting, sources: retrySources, to: destinationRoot)
        }

        // Both sources of the failed retry survive, unmodified. FIX ROUND 2: "unmodified" is now
        // asserted BYTE-FOR-BYTE rather than by existence alone, so the check matches the claim --
        // a source read, rewritten or truncated in place would have passed the old assertion.
        let validMicBytesAfter = try Data(contentsOf: validMicURL)
        let brokenSystemBytesAfter = try Data(contentsOf: brokenSystemURL)
        #expect(validMicBytesAfter == validMicBytes)
        #expect(brokenSystemBytesAfter == brokenSystemBytes)

        // The prior good export is EXACTLY as it was: same single file, same bytes -- not
        // deleted, not replaced with a partial microphone-only directory, not left empty.
        #expect(FileManager.default.fileExists(atPath: audioDirectory.path))
        let contentsAfterFailure = try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path)
        #expect(Set(contentsAfterFailure) == ["playback.m4a"])
        let bytesAfterFailure = try Data(contentsOf: originalDestination)
        #expect(bytesAfterFailure == originalBytes)

        // No staging or backup directory was left behind anywhere under the destination root --
        // the only thing there is the one real, complete audio directory.
        let rootContents = try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path)
        #expect(rootContents == [audioDirectory.lastPathComponent])
    }

    // MARK: - commit() recovery paths — FORCED failures, not described ones
    //
    // Every test below drives the REAL `export(...)` entry point over the REAL filesystem and
    // declares that exactly one directory rename should fail. The declaration goes through
    // `FaultInjection`, which is pure data: it can say a rename throws, and nothing else. It
    // cannot perform, skip, substitute or fake a filesystem operation, so no test here can make
    // `export` report success without every real rename having actually happened.
    //
    // The faults are needed because these branches cannot be provoked any other way: both live
    // strictly BETWEEN two renames inside one synchronous call, so a test has no moment at which
    // to intervene, and there is no permission bit, `chflags` flag or path shape that makes the
    // second rename of a sibling directory fail while the first, structurally identical one
    // succeeds -- anything that blocks the second blocks the first, and the function then never
    // reaches recovery at all. Everything else in each test is real: real audio written by this
    // fork's own writer, a real prior export, real bytes compared afterwards.
    //
    // HONEST LIMIT, stated rather than glossed: these four tests cannot be run against the
    // PRE-FIX implementation to show them failing first, because the parameter they declare
    // faults through did not exist there and the file would not compile. What was done instead is
    // recorded in this task's report: each fix was reverted IN PLACE, one at a time, and the
    // corresponding test observed to fail, with the failure messages quoted.

    /// ROUND 2. These tests used to inject a struct of `@Sendable` closures, which review defeated
    /// three ways in one line each (a no-op successful move, a destructive successful move, and a
    /// copy-then-delete substituted for `rename(2)`), each letting `export` return SUCCESS with the
    /// previous export destroyed. The seam is now `FaultInjection`, a value carrying NO CODE: it
    /// can only declare that a rename throws, never say what a rename does. Those three attacks are
    /// compile errors, asserted on every CI run by
    /// `scripts/negative-controls/TranscriptedAudioExportSeamAttacks.swift`.
    private static let stagingDirectoryPrefix = TranscriptedAudioExporter.scratchPrefix + "staging-"
    private static let backupDirectoryPrefix = TranscriptedAudioExporter.scratchPrefix + "backup-"

    /// Fail only the replacement rename, `staging -> final`. Everything else runs for real.
    private static var failCommitRename: TranscriptedAudioExporter.FaultInjection {
        TranscriptedAudioExporter.FaultInjection(
            failRenamesOfDirectoriesPrefixed: [stagingDirectoryPrefix]
        )
    }

    /// Fail the replacement rename AND the restoring `backup -> final` rename. `old -> backup`
    /// still runs for real, so the original really is under the backup name when this resolves.
    private static var failCommitAndRestoreRenames: TranscriptedAudioExporter.FaultInjection {
        TranscriptedAudioExporter.FaultInjection(
            failRenamesOfDirectoriesPrefixed: [stagingDirectoryPrefix, backupDirectoryPrefix]
        )
    }

    /// A prior good export at the destination, plus its exact bytes, so every test below can
    /// prove the ORIGINAL audio survived rather than merely that a directory exists.
    private func makePriorGoodExport(
        in destinationRoot: URL,
        meeting: Meeting
    ) async throws -> (directory: URL, playbackURL: URL, bytes: Data) {
        let scratch = makeTemporaryDirectory()
        let wavURL = try makeWAVFile(in: scratch, samples: Array(repeating: 4321, count: 16_000))
        let directory = try await TranscriptedAudioExporter.export(
            meeting: meeting,
            sources: TranscriptedAudioExporter.AudioSources(playbackURL: wavURL),
            to: destinationRoot
        )
        let playbackURL = directory.appendingPathComponent("playback.m4a")
        let bytes = try Data(contentsOf: playbackURL)
        #expect(!bytes.isEmpty)
        return (directory, playbackURL, bytes)
    }

    /// Sources for a re-export over that prior good export. Valid, so the staging half succeeds
    /// for real and the failure under test is genuinely the COMMIT, not a transcode.
    private func makeValidReExportSources(scratch: URL) throws -> TranscriptedAudioExporter.AudioSources {
        TranscriptedAudioExporter.AudioSources(
            playbackURL: try makeWAVFile(in: scratch, samples: Array(repeating: 999, count: 16_000))
        )
    }

    private func stagingLeftovers(under root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(Self.stagingDirectoryPrefix) }
    }

    /// Outcome 1 of three: the replacement rename fails, the aside copy IS successfully renamed
    /// back, and the caller therefore gets the ORIGINAL commit error rather than a rollback error.
    /// The destination must end up byte-for-byte as it was — this is the ordinary, expected shape
    /// of a failed re-export, and the one the other two tests are the fallbacks for.
    @Test("a failed commit whose rollback succeeds restores the original bytes and surfaces the commit error")
    func commitFailureWithSuccessfulRollbackRestoresTheOriginalAndSurfacesTheCommitError() async throws {
        let destinationRoot = makeTemporaryDirectory()
        let meeting = Self.makeMeeting()
        let prior = try await makePriorGoodExport(in: destinationRoot, meeting: meeting)
        let sources = try makeValidReExportSources(scratch: makeTemporaryDirectory())

        // Only `staging -> final` fails. `old -> backup` and the restoring `backup -> final` both
        // run for real against the real filesystem.
        var caught: (any Error)?
        do {
            _ = try await TranscriptedAudioExporter.export(
                meeting: meeting, sources: sources, to: destinationRoot, faults: Self.failCommitRename
            )
            Issue.record("export unexpectedly succeeded despite an injected commit-rename failure")
        } catch {
            caught = error
        }

        // The caller sees the real cause, NOT a rollback error: recovery worked, so there is
        // nothing extra to tell them.
        let simulated = try #require(caught as? TranscriptedAudioExporter.FaultInjection.SimulatedRenameFailure)
        #expect(simulated.source.lastPathComponent.hasPrefix(Self.stagingDirectoryPrefix))

        // The prior good export is back at its documented path, byte for byte.
        #expect(FileManager.default.fileExists(atPath: prior.directory.path))
        let restoredBytes = try Data(contentsOf: prior.playbackURL)
        #expect(restoredBytes == prior.bytes)
        let contents = try FileManager.default.contentsOfDirectory(atPath: prior.directory.path)
        #expect(Set(contents) == ["playback.m4a"])

        // Nothing left behind: the backup was consumed by the restore, and the staging directory
        // was discarded because this was NOT a rollback failure.
        let rootContents = try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path)
        #expect(rootContents == [prior.directory.lastPathComponent])
    }

    /// Outcome 2 of three, and the proof the escalation asked for by name: the RESTORING rename
    /// fails. The caller must receive an error that NAMES WHERE THE ORIGINAL AUDIO ACTUALLY IS.
    ///
    /// This is the exact defect being closed. The previous implementation wrote
    /// `try? removeItem(final)` then `try? moveItem(backup, final)`, so this failure was
    /// swallowed whole: the caller saw only the unrelated commit error while a complete, unplayed
    /// recording sat under a `.TranscriptedAudioExporter-backup-<uuid>` name nobody could guess
    /// and the documented destination was empty. Lines of prose two above it claimed restoration
    /// was guaranteed and that neither version could be absent.
    @Test("when the restoring rename fails, the caller gets an error naming where the original audio is")
    func restoreFailureSurfacesRollbackFailedNamingTheBackupLocation() async throws {
        let destinationRoot = makeTemporaryDirectory()
        let meeting = Self.makeMeeting()
        let prior = try await makePriorGoodExport(in: destinationRoot, meeting: meeting)
        let sources = try makeValidReExportSources(scratch: makeTemporaryDirectory())

        var caught: (any Error)?
        do {
            _ = try await TranscriptedAudioExporter.export(
                meeting: meeting, sources: sources, to: destinationRoot,
                faults: Self.failCommitAndRestoreRenames
            )
            Issue.record("export unexpectedly succeeded despite injected commit and restore failures")
        } catch {
            caught = error
        }

        let exportError = try #require(caught as? TranscriptedAudioExporter.ExportError)
        guard case .rollbackFailed(let failure) = exportError else {
            Issue.record("expected .rollbackFailed, got \(exportError)")
            return
        }
        // The reason names the restoring rename's own failure, keyed to the very directory the
        // error says the audio is in -- so this cannot pass by naming some other path.
        #expect(failure.reason == .restoreFailed(String(describing:
            TranscriptedAudioExporter.FaultInjection.SimulatedRenameFailure(
                source: failure.originalAudioDirectory
            )
        )))
        #expect(failure.intendedDirectory == prior.directory)
        #expect(failure.commitFailure.contains(Self.stagingDirectoryPrefix))

        // THE LOAD-BEARING ASSERTION: the path in the error is not decoration. The original audio
        // is really there, complete and byte-identical, and a human following this error recovers
        // it. Nothing is lost -- it is only in the wrong place, and the error says which place.
        #expect(FileManager.default.fileExists(atPath: failure.originalAudioDirectory.path))
        let rescuedBytes = try Data(contentsOf: failure.originalAudioDirectory.appendingPathComponent("playback.m4a"))
        #expect(rescuedBytes == prior.bytes)
        let rescuedContents = try FileManager.default.contentsOfDirectory(
            atPath: failure.originalAudioDirectory.path
        )
        #expect(Set(rescuedContents) == ["playback.m4a"])

        // The documented destination really is empty -- i.e. this test is checking the state the
        // old code left silently, not a state that happened to look fine anyway.
        #expect(FileManager.default.fileExists(atPath: prior.directory.path) == false)

        // The message a person actually sees carries the recovery path verbatim. An error that
        // only said "export failed" would strand audio nobody can re-record.
        let description = try #require(exportError.errorDescription)
        #expect(description.contains(failure.originalAudioDirectory.path))
        #expect(description.contains(prior.directory.path))

        // Deliberate: the assembled replacement is KEPT, not deleted, while a human is recovering.
        let keptStaging = try stagingLeftovers(under: destinationRoot)
        #expect(keptStaging.count == 1)
    }

    /// Outcome 3 of three: something else has created a directory at the destination in the window
    /// between the two renames. The recovery must REFUSE to delete it and surface a distinct error
    /// naming the backup, rather than recursively destroying a stranger's data on the assumption
    /// that anything at that path is our own debris.
    ///
    /// The previous implementation did exactly that: `try? removeItem(at: finalDirectory)`,
    /// unconditionally, as the first act of its recovery path.
    @Test("an unexpected directory at the destination is never deleted, and the error names the backup")
    func unexpectedDirectoryAtDestinationIsNotDeletedAndErrorNamesTheBackup() async throws {
        let destinationRoot = makeTemporaryDirectory()
        let meeting = Self.makeMeeting()
        let prior = try await makePriorGoodExport(in: destinationRoot, meeting: meeting)
        let sources = try makeValidReExportSources(scratch: makeTemporaryDirectory())

        let strangerFilename = TranscriptedAudioExporter.FaultInjection.concurrentWriterFilename
        let strangerBytes = Data(TranscriptedAudioExporter.FaultInjection.concurrentWriterContents.utf8)

        // The replacement rename fails, and a simulated concurrent writer claims the destination
        // in the window between the two renames -- the only condition a test cannot produce for
        // itself, because it happens strictly between two renames inside one synchronous call.
        var faults = Self.failCommitRename
        faults.simulateConcurrentWriterAtDestination = true

        var caught: (any Error)?
        do {
            _ = try await TranscriptedAudioExporter.export(
                meeting: meeting, sources: sources, to: destinationRoot, faults: faults
            )
            Issue.record("export unexpectedly succeeded despite an occupied destination")
        } catch {
            caught = error
        }

        let exportError = try #require(caught as? TranscriptedAudioExporter.ExportError)
        guard case .rollbackFailed(let failure) = exportError else {
            Issue.record("expected .rollbackFailed, got \(exportError)")
            return
        }
        #expect(failure.reason == .destinationOccupied)

        // THE LOAD-BEARING ASSERTION: the stranger's directory is untouched. A blind
        // `removeItem(at: finalDirectory)` would have recursively deleted it and its contents.
        let strangerURL = prior.directory.appendingPathComponent(strangerFilename)
        let strangerBytesAfter = try Data(contentsOf: strangerURL)
        #expect(strangerBytesAfter == strangerBytes)
        let occupiedContents = try FileManager.default.contentsOfDirectory(atPath: prior.directory.path)
        #expect(Set(occupiedContents) == [strangerFilename])

        // And the original audio is still whole, at the path the error names.
        let preservedOriginalBytes = try Data(
            contentsOf: failure.originalAudioDirectory.appendingPathComponent("playback.m4a")
        )
        #expect(preservedOriginalBytes == prior.bytes)
        let description = try #require(exportError.errorDescription)
        #expect(description.contains(failure.originalAudioDirectory.path))
    }

    /// FIX ROUND 2 (BLOCKING 3). `commit` throwing from its own rename with NO prior export at the
    /// destination used to orphan the complete staging directory: `export` did not wrap the call,
    /// so nothing removed it, while the file's header claimed no residue was left "anywhere, ever".
    /// The claim is now narrowed to what the code delivers AND the cleanup is actually done here.
    @Test("a commit rename failure with no prior export leaves no staging directory behind")
    func commitRenameFailureWithNoPriorExportDiscardsTheStagingDirectory() async throws {
        let destinationRoot = makeTemporaryDirectory()
        let sources = try makeValidReExportSources(scratch: makeTemporaryDirectory())

        // Nothing at the destination, so `commit` takes its single-rename path -- and that one
        // rename fails.
        var caught: (any Error)?
        do {
            _ = try await TranscriptedAudioExporter.export(
                meeting: Self.makeMeeting(), sources: sources, to: destinationRoot,
                faults: Self.failCommitRename
            )
            Issue.record("export unexpectedly succeeded despite an injected commit-rename failure")
        } catch {
            caught = error
        }
        let orphanFailure = try #require(caught as? TranscriptedAudioExporter.FaultInjection.SimulatedRenameFailure)
        #expect(orphanFailure.source.lastPathComponent.hasPrefix(Self.stagingDirectoryPrefix))

        // No destination directory was created, and no staging directory survives.
        let rootContents = try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path)
        #expect(rootContents.isEmpty)
    }

    // MARK: - Sources inside the destination — ROUND 2 (BLOCKING 2)
    //
    // The header promises this exporter never deletes, moves or modifies a supplied source under
    // ANY circumstance. Nothing enforced that for a source living INSIDE the destination tree, and
    // the way it broke was the worst shape available: a SUCCESSFUL re-export renames the old
    // destination aside to the backup, carrying such a source with it, and then deletes that backup
    // once the replacement is in place. For a WAV source the user is left with only the lossy M4A
    // derived from it, the original gone, and the export reporting success.

    /// FAIL-FIRST, and the irreversible case: a WAV inside the destination. Against the pre-guard
    /// implementation this export SUCCEEDS and the WAV is destroyed; the only surviving copy of
    /// that audio is the lossy M4A transcoded from it.
    @Test("a WAV source inside the destination is rejected, not consumed by a successful re-export")
    func wavSourceInsideTheDestinationIsRejectedRatherThanConsumed() async throws {
        let destinationRoot = makeTemporaryDirectory()
        let meeting = Self.makeMeeting()
        let prior = try await makePriorGoodExport(in: destinationRoot, meeting: meeting)

        // The source now lives inside the very directory the re-export will replace.
        let trappedWAV = try makeWAVFile(in: prior.directory, samples: Array(repeating: 777, count: 16_000))
        let trappedBytes = try Data(contentsOf: trappedWAV)

        var caught: (any Error)?
        do {
            _ = try await TranscriptedAudioExporter.export(
                meeting: meeting,
                sources: TranscriptedAudioExporter.AudioSources(playbackURL: trappedWAV),
                to: destinationRoot
            )
            Issue.record("export unexpectedly succeeded with a source inside the destination")
        } catch {
            caught = error
        }

        let exportError = try #require(caught as? TranscriptedAudioExporter.ExportError)
        guard case .sourceInsideDestination(let source, let container) = exportError else {
            Issue.record("expected .sourceInsideDestination, got \(exportError)")
            return
        }
        #expect(source == trappedWAV)
        #expect(container == prior.directory)

        // THE LOAD-BEARING ASSERTION: the user's original WAV is still there, byte for byte.
        let trappedBytesAfter = try Data(contentsOf: trappedWAV)
        #expect(trappedBytesAfter == trappedBytes)

        // And the prior export is untouched, because the guard runs before anything happens.
        let priorBytesAfter = try Data(contentsOf: prior.playbackURL)
        #expect(priorBytesAfter == prior.bytes)

        // The message a person sees names both paths and says nothing was touched.
        let description = try #require(exportError.errorDescription)
        #expect(description.contains(trappedWAV.path))
        #expect(description.contains(prior.directory.path))
    }

    /// FAIL-FIRST: rejection happens BEFORE anything is created or moved. Nothing after the guard
    /// could undo the loss, so nothing before it is allowed to have happened — asserted by the
    /// absence of any staging directory, not merely by the export having thrown.
    @Test("a source inside the destination is rejected before any staging directory is created")
    func sourceInsideTheDestinationIsRejectedBeforeAnythingIsCreated() async throws {
        let destinationRoot = makeTemporaryDirectory()
        let meeting = Self.makeMeeting()
        let prior = try await makePriorGoodExport(in: destinationRoot, meeting: meeting)

        var caught: (any Error)?
        do {
            _ = try await TranscriptedAudioExporter.export(
                meeting: meeting,
                // The prior export's OWN m4a, exported back over itself.
                sources: TranscriptedAudioExporter.AudioSources(microphoneURL: prior.playbackURL),
                to: destinationRoot
            )
            Issue.record("export unexpectedly succeeded with a source inside the destination")
        } catch {
            caught = error
        }
        #expect((caught as? TranscriptedAudioExporter.ExportError).map { error in
            if case .sourceInsideDestination = error { return true } else { return false }
        } == true)

        // Nothing was created: the destination root holds the prior export and nothing else, so
        // there is no staging directory, no backup, and no residue to clean up.
        let rootContents = try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path)
        #expect(rootContents == [prior.directory.lastPathComponent])
        let priorContents = try FileManager.default.contentsOfDirectory(atPath: prior.directory.path)
        #expect(Set(priorContents) == ["playback.m4a"])
        let priorBytesAfter = try Data(contentsOf: prior.playbackURL)
        #expect(priorBytesAfter == prior.bytes)
    }

    /// FAIL-FIRST: the scratch trees count too. A rollback failure tells the user their audio is in
    /// a `.TranscriptedAudioExporter-backup-<uuid>` directory, so a caller reaching in there to
    /// re-export it is a REALISTIC path, not a contrived one — and this exporter deletes those
    /// directories, so exporting from inside one must be refused just as firmly.
    @Test("a source inside a leftover scratch directory under the destination root is rejected")
    func sourceInsideALeftoverScratchDirectoryIsRejected() async throws {
        let destinationRoot = makeTemporaryDirectory()

        // Exactly the shape a failed rollback leaves behind.
        let leftoverBackup = destinationRoot.appendingPathComponent(
            TranscriptedAudioExporter.scratchPrefix + "backup-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: leftoverBackup, withIntermediateDirectories: true)
        let strandedWAV = try makeWAVFile(in: leftoverBackup)

        var caught: (any Error)?
        do {
            _ = try await TranscriptedAudioExporter.export(
                meeting: Self.makeMeeting(),
                sources: TranscriptedAudioExporter.AudioSources(playbackURL: strandedWAV),
                to: destinationRoot
            )
            Issue.record("export unexpectedly succeeded with a source inside a scratch directory")
        } catch {
            caught = error
        }

        let exportError = try #require(caught as? TranscriptedAudioExporter.ExportError)
        guard case .sourceInsideDestination(let source, let container) = exportError else {
            Issue.record("expected .sourceInsideDestination, got \(exportError)")
            return
        }
        #expect(source == strandedWAV)
        #expect(container.lastPathComponent == leftoverBackup.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: strandedWAV.path))
    }

    /// REGRESSION GUARD, not proof. This passes against the pre-guard implementation too — sources
    /// outside the destination were always safe — and is here so the containment check can never be
    /// widened into rejecting or consuming ordinary sources. It is the counterpart the guard needs:
    /// the three tests above prove what is now refused, this one pins what must still work.
    @Test("REGRESSION GUARD: a WAV source outside the destination survives a successful re-export byte-for-byte")
    func wavSourceOutsideTheDestinationSurvivesASuccessfulReExport() async throws {
        let destinationRoot = makeTemporaryDirectory()
        let meeting = Self.makeMeeting()
        let prior = try await makePriorGoodExport(in: destinationRoot, meeting: meeting)

        let scratch = makeTemporaryDirectory()
        let replacementWAV = try makeWAVFile(in: scratch, samples: Array(repeating: 555, count: 16_000))
        let replacementBytes = try Data(contentsOf: replacementWAV)

        let audioDirectory = try await TranscriptedAudioExporter.export(
            meeting: meeting,
            sources: TranscriptedAudioExporter.AudioSources(playbackURL: replacementWAV),
            to: destinationRoot
        )

        // The re-export really happened: same path, different bytes from the prior export.
        #expect(audioDirectory == prior.directory)
        let newBytes = try Data(contentsOf: audioDirectory.appendingPathComponent("playback.m4a"))
        #expect(newBytes != prior.bytes)

        // And the source WAV is untouched, byte for byte -- the thing the guard must not break.
        let replacementBytesAfter = try Data(contentsOf: replacementWAV)
        #expect(replacementBytesAfter == replacementBytes)

        // No residue: the backup was consumed once the replacement landed.
        let rootContents = try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path)
        #expect(rootContents == [audioDirectory.lastPathComponent])
    }
}

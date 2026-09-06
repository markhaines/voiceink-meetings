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
        let sources = TranscriptedAudioExporter.AudioSources(playbackURL: brokenWAVURL)
        let destinationRoot = makeTemporaryDirectory()

        await #expect(throws: (any Error).self) {
            _ = try await TranscriptedAudioExporter.export(
                meeting: Self.makeMeeting(),
                sources: sources,
                to: destinationRoot
            )
        }

        // The source must survive -- it is the only copy of this channel's audio.
        #expect(FileManager.default.fileExists(atPath: brokenWAVURL.path))

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
        let retrySources = TranscriptedAudioExporter.AudioSources(
            microphoneURL: validMicURL,
            systemAudioURL: brokenSystemURL
        )

        await #expect(throws: (any Error).self) {
            _ = try await TranscriptedAudioExporter.export(meeting: meeting, sources: retrySources, to: destinationRoot)
        }

        // Both sources of the failed retry survive, unmodified.
        #expect(FileManager.default.fileExists(atPath: validMicURL.path))
        #expect(FileManager.default.fileExists(atPath: brokenSystemURL.path))

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
}

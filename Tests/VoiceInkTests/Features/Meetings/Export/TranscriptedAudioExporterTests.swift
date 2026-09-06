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

import AVFoundation
import Foundation
import Testing
@testable import VoiceInk

@Suite("TranscriptedAudioExporter")
struct TranscriptedAudioExporterTests {
    // MARK: - Fixtures

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

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripted-audio-exporter-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

    @Test("only a system-audio source plans a single system_audio.m4a item")
    func systemAudioOnlyPlansSingleItem() throws {
        let sources = TranscriptedAudioExporter.AudioSources(systemAudioURL: URL(fileURLWithPath: "/tmp/sys.wav"))
        let plan = try TranscriptedAudioExporter.plan(meeting: Self.makeMeeting(), sources: sources)

        #expect(plan.items.map(\.channel) == [.systemAudio])
        #expect(plan.items.map(\.destinationFilename) == ["system_audio.m4a"])
    }

    /// Mirrors the real `Failed_2026-08-28_07-59-41_DBB620D5_audio/` capture found on Mark's
    /// Mac Studio: mic + system present, playback absent (never derived because the mix never
    /// ran). This exporter has no equivalent "mix" step, but the missing-channel shape — omit
    /// the absent one, keep the present ones — must still hold.
    @Test("mic and system present, playback absent, plans exactly those two in a fixed order")
    func micAndSystemPresentPlaybackAbsent() throws {
        let sources = TranscriptedAudioExporter.AudioSources(
            microphoneURL: URL(fileURLWithPath: "/tmp/mic.wav"),
            systemAudioURL: URL(fileURLWithPath: "/tmp/sys.wav")
        )
        let plan = try TranscriptedAudioExporter.plan(meeting: Self.makeMeeting(), sources: sources)

        #expect(plan.items.map(\.channel) == [.microphone, .systemAudio])
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

        let audioDirectory = destinationRoot.appendingPathComponent("2026-07-31 Meeting at 4 00 pm_audio")
        let leftoverFiles = (try? FileManager.default.contentsOfDirectory(atPath: audioDirectory.path)) ?? []
        #expect(leftoverFiles.filter { $0.hasSuffix(".m4a") }.isEmpty)
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
}

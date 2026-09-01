// SHARED FOUNDATION TYPE — four parallel Stage-1 agents (capture core, mic+route, AEC,
// transcription-support) compile against this. Do not edit without coordinating across all
// of them; a signature or behavior change here can silently break work landing in parallel.
//
// This is a fork-owned equivalent of Muesli-HQ/muesli's RuntimePaths
// (native/MuesliNative/Sources/MuesliNativeApp/RuntimePaths.swift), NOT a verbatim port —
// the donor's RuntimePaths is actually about app-bundle resource resolution (icons, repo
// root for dev builds), which VoiceInk doesn't need. What Stage-1 capture code actually needs
// is what the donor calls chunk-scratch directories (PCMChunkRecorder's temp WAV chunks,
// donor: MeetingSession.swift's "muesli-meeting-mic-chunks" / "-system-chunks") and a
// permanent meeting-audio directory (donor: MeetingRecordingWriter.swift's
// `<AppSupport>/meeting-recordings/`), so this fork-local type covers those two concerns
// under the fork's own naming instead.
//
// The permanent directory is deliberately a SIBLING of VoiceInkEngine's own `Recordings/`
// directory (`~/Library/Application Support/com.hainesy.VoiceInkMeetings/Recordings/`), not
// nested inside it. AudioCleanupManager sweeps files by walking `Transcription.audioFileURL`
// records in SwiftData, not by scanning a directory, so the exemption meeting audio needs is
// structural rather than a filter to remember: as long as no `Transcription` record is ever
// created for a meeting recording, AudioCleanupManager can never reach it regardless of which
// directory it lives in. Using a separate, distinctly-named directory just makes that
// separation legible on disk too, for anyone debugging with Finder or `ls`.

import Foundation

enum MeetingRuntimePaths {
    /// Directory name handed to `PCMChunkRecorder(directoryName:)` for the raw microphone
    /// chunk stream. Mirrors the donor's "muesli-meeting-mic-chunks" under this fork's own
    /// temp-directory namespace.
    static let micChunkDirectoryName = "voiceink-meeting-mic-chunks"

    /// Directory name handed to `PCMChunkRecorder(directoryName:)` for the system-audio chunk
    /// stream. Mirrors the donor's "muesli-meeting-system-chunks".
    static let systemChunkDirectoryName = "voiceink-meeting-system-chunks"

    /// Where finalized meeting recordings live permanently, created on first access.
    /// `~/Library/Application Support/com.hainesy.VoiceInkMeetings/MeetingRecordings/`
    static func meetingAudioDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hainesy.VoiceInkMeetings")
        let directory = appSupport.appendingPathComponent("MeetingRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

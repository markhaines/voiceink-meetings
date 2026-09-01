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
// directory (`~/Library/Application Support/<bundle-id>/Recordings/`), not nested inside it,
// and it is exempt from BOTH of VoiceInk's existing audio-cleanup mechanisms structurally,
// not by a filter anyone has to remember:
//   1. `AudioCleanupManager` deletes only paths it reads out of `Transcription.audioFileURL`
//      in SwiftData — it never scans a directory at all. As long as no `Transcription` record
//      is ever created for a meeting recording (true today; meetings have no store yet), it
//      cannot reach `MeetingRecordings/` regardless of where that directory lives.
//   2. `TranscriptionAutoCleanupService.cleanupOrphanAudioFiles()` (the *second*, easy-to-miss
//      mechanism — it also deletes files with no matching `Transcription` record) only ever
//      lists its own hardcoded `recordingsDirectory` computed property, which is fixed at
//      `.../Recordings` and never varies. A sibling `MeetingRecordings/` is outside that scan
//      by construction, not because of any check either cleanup path performs on the file
//      itself. Verified by reading both call sites
//      (`VoiceInk/Infrastructure/Persistence/Cleanup/AudioCleanupManager.swift` and
//      `.../TranscriptionAutoCleanupService.swift`) rather than assumed.
// Using a separate, distinctly-named directory also just makes the separation legible on disk
// for anyone debugging with Finder or `ls`.
//
// The directory is scoped by `Bundle.main.bundleIdentifier`, not a hardcoded literal, because
// the Debug build ships as "VoiceInk Dev.app" under `com.hainesy.VoiceInkMeetings.dev` and is
// designed to coexist on the same Mac as the Release build under `com.hainesy.VoiceInkMeetings`
// (confirmed in `VoiceInk.xcodeproj/project.pbxproj`'s Debug/Release `PRODUCT_BUNDLE_IDENTIFIER`
// settings for the `VoiceInk` target). A literal here would make the Dev build write meeting
// recordings into the Release app's Application Support tree — the two builds would read and
// modify each other's meeting audio, silently. `Bundle.main.bundleIdentifier` is `Optional`
// only in unusual hosting environments (no proper bundle); this function throws rather than
// falling back to a guessed literal in that case, deliberately, because a silent fallback could
// put meeting audio — audio of other people's conversations — somewhere neither build owns,
// and nobody would notice until they went looking for a "missing" recording.

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
    /// `~/Library/Application Support/<Bundle.main.bundleIdentifier>/MeetingRecordings/` —
    /// see the file header for why this must be bundle-identifier-scoped, not a literal.
    static func meetingAudioDirectory() throws -> URL {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw NSError(
                domain: "MeetingRuntimePaths",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not resolve Bundle.main.bundleIdentifier; refusing to guess a meeting-audio directory."
                ]
            )
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier)
        let directory = appSupport.appendingPathComponent("MeetingRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

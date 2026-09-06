// Fork-only file, no upstream equivalent.
//
// This is Phase 3's acceptance gate: it drives the REAL `transcripted-mcp` binary — Mark's
// own separate "Transcripted" app's indexer, not a reimplementation or a mock — against a
// meeting file this fork's OWN `TranscriptedMarkdownExporter` actually wrote, and checks the
// real numbers the real indexer produced (word_count, speaker_count, action items with
// owners). A fork-produced file that scores `word_count: 0` here is a genuine defect in this
// exporter's output; a file that scores real numbers is the only proof that matters that this
// exporter's format isn't just self-consistent but actually legible to the tool it exists to
// feed.
//
// SAFETY, matching the investigation this test is built from
// (`transcripted-indexer-acceptance.md`, read via `~/code/transcripted`'s own source — see
// `TranscriptedMarkdownExporter.swift`'s header for the exact functions cited):
//   - Every directory this test touches is created fresh under `NSTemporaryDirectory()` and
//     removed afterward. Nothing is ever written to, read from destructively, or created
//     under any `OneDrive-ATEME` path.
//   - `TRANSCRIPTED_MEETINGS_DIR`/`TRANSCRIPTED_DICTATIONS_DIR`/`TRANSCRIPTED_INDEX_DIR`
//     environment variables sit ABOVE the app's real manifest in the real binary's own
//     directory-resolution order (confirmed by reading
//     `Tools/TranscriptedCaptureKit/Sources/TranscriptedCaptureKit/
//     CaptureLibraryResolver.swift`'s `resolve()` body), so a scratch-scoped run never
//     touches `~/Library/Application Support/Transcripted/mcp-directories.json` or the real
//     `~/Library/Application Support/Transcripted/cache` — this is a brand-new, separate
//     process using its own scratch state, not a client of the real running server.
//   - `--self-test` (a real flag on the shipped binary, confirmed via `--help`) resolves
//     directories, builds the scratch SQLite index, prints one JSON summary line, and exits —
//     no long-lived process, no MCP stdio protocol to drive.
//
// Guarded, not required: this test only runs on a Mac that actually has Mark's Transcripted
// app installed at its default location (`.enabled(if:)` below). On CI, or any other clone of
// this fork, the binary doesn't exist, so the test is reported as skipped, not failed or
// silently green — this is the honest state for a real cross-project dependency this fork
// cannot vendor or fake.

import Foundation
import Testing

@testable import VoiceInk

@Suite("Transcripted indexer acceptance (real binary, scratch dirs)")
struct TranscriptedIndexerAcceptanceTests {
    private static let binaryPath = "/Users/mark/Library/Application Support/Transcripted/mcp/transcripted-mcp"
    private static let sqlite3Path = "/usr/bin/sqlite3"

    private static var binaryIsAvailable: Bool {
        FileManager.default.fileExists(atPath: binaryPath) && FileManager.default.fileExists(atPath: sqlite3Path)
    }

    @Test(
        "a fork-produced meeting file, with multiple speakers and action items, indexes with real word/speaker/action-item counts",
        .enabled(if: Self.binaryIsAvailable)
    )
    func exportedMeetingIndexesWithRealCounts() throws {
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-transcripted-acceptance-\(UUID().uuidString)", isDirectory: true)
        let meetingsDir = scratchRoot.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = scratchRoot.appendingPathComponent("dictations", isDirectory: true)
        let indexDir = scratchRoot.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        // A realistic multi-speaker meeting with action items, one of which names an owner
        // ("Mark") the way the real `actionItem(from:)` heuristic
        // (`CaptureSummaryParser.swift:149`) expects: a short Title-Case leading segment
        // before ": ".
        let meeting = Meeting(title: "Acceptance Test Meeting", audioDirectoryPath: "/tmp/irrelevant")
        meeting.actionItems = [
            "Mark: follow up with the vendor on pricing",
            "Send the revised proposal by Friday",
        ]
        let segments = [
            MeetingSegment(startOffset: 0, endOffset: 0, speakerLabel: "You", text: "Let's get started on the quarterly review.", sourceChannel: .mic, orderIndex: 0),
            MeetingSegment(startOffset: 5, endOffset: 5, speakerLabel: "Jane Doe", text: "Thanks for setting this up. I have the numbers ready.", sourceChannel: .system, orderIndex: 1),
            MeetingSegment(startOffset: 12, endOffset: 12, speakerLabel: "You", text: "Great, let's walk through them one by one.", sourceChannel: .mic, orderIndex: 2),
            MeetingSegment(startOffset: 18, endOffset: 18, speakerLabel: "Sam Lee", text: "I can cover the vendor pricing side once Jane is done.", sourceChannel: .system, orderIndex: 3),
            MeetingSegment(startOffset: 25, endOffset: 25, speakerLabel: "Jane Doe", text: "Sounds good, I'll go first then.", sourceChannel: .system, orderIndex: 4),
        ]

        let destination = try TranscriptedMarkdownExporter.write(meeting: meeting, segments: segments, to: meetingsDir)
        #expect(FileManager.default.fileExists(atPath: destination.path))

        let selfTest = try Self.runSelfTest(meetingsDir: meetingsDir, dictationsDir: dictationsDir, indexDir: indexDir)
        #expect(selfTest.ok == true)
        #expect(selfTest.meetingFileCount == 1)

        let row = try Self.queryMeetingRow(indexDir: indexDir, filenameLike: "Acceptance Test Meeting")
        let expectedWordCount = segments.reduce(0) { $0 + $1.text.split(separator: " ").count }

        // THE central assertion: a fork-produced file must not score zero. `word_count` from
        // the real SQLite index must reflect the real transcript, not come back empty because
        // this exporter's format didn't parse.
        #expect(row.wordCount > 0)
        #expect(row.wordCount == expectedWordCount)
        #expect(row.speakerCount == 3)  // You, Jane Doe, Sam Lee

        let actionItems = try Self.queryActionItems(indexDir: indexDir, filenameLike: "Acceptance Test Meeting")
        #expect(actionItems.count == 2)
        #expect(actionItems.contains { $0.owner == "Mark" && $0.text.contains("vendor on pricing") })
        #expect(actionItems.contains { $0.owner == nil && $0.text.contains("revised proposal") })
    }

    // MARK: - Harness plumbing

    private struct SelfTestResult {
        let ok: Bool
        let meetingFileCount: Int
    }

    private static func runSelfTest(meetingsDir: URL, dictationsDir: URL, indexDir: URL) throws -> SelfTestResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--self-test"]
        process.environment = [
            "TRANSCRIPTED_MEETINGS_DIR": meetingsDir.path,
            "TRANSCRIPTED_DICTATIONS_DIR": dictationsDir.path,
            "TRANSCRIPTED_INDEX_DIR": indexDir.path,
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let ok = json["ok"] as? Bool,
            let meetingFileCount = json["meeting_file_count"] as? Int
        else {
            Issue.record("--self-test did not produce the expected JSON: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
            return SelfTestResult(ok: false, meetingFileCount: 0)
        }
        return SelfTestResult(ok: ok, meetingFileCount: meetingFileCount)
    }

    private struct MeetingRow {
        let wordCount: Int
        let speakerCount: Int
    }

    private static func queryMeetingRow(indexDir: URL, filenameLike: String) throws -> MeetingRow {
        let sql = "SELECT word_count, speaker_count FROM meetings WHERE filename LIKE '%\(filenameLike)%';"
        let output = try Self.runSQLite(dbPath: indexDir.appendingPathComponent("mcp_index.sqlite").path, sql: sql)
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard fields.count == 2, let wordCount = Int(fields[0]), let speakerCount = Int(fields[1]) else {
            Issue.record("unexpected meetings row shape: \(output)")
            return MeetingRow(wordCount: 0, speakerCount: 0)
        }
        return MeetingRow(wordCount: wordCount, speakerCount: speakerCount)
    }

    private struct ActionItemRow {
        let owner: String?
        let text: String
    }

    private static func queryActionItems(indexDir: URL, filenameLike: String) throws -> [ActionItemRow] {
        let sql = """
        SELECT owner, text FROM meeting_summary_items
        WHERE kind = 'action_item' AND filename LIKE '%\(filenameLike)%';
        """
        let output = try Self.runSQLite(dbPath: indexDir.appendingPathComponent("mcp_index.sqlite").path, sql: sql)
        return output
            .split(separator: "\n")
            .map { line -> ActionItemRow in
                let fields = line.components(separatedBy: "|")
                let owner = fields.first.flatMap { $0.isEmpty ? nil : $0 }
                let text = fields.count > 1 ? fields[1...].joined(separator: "|") : ""
                return ActionItemRow(owner: owner, text: text)
            }
    }

    private static func runSQLite(dbPath: String, sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlite3Path)
        process.arguments = ["-separator", "|", dbPath, sql]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

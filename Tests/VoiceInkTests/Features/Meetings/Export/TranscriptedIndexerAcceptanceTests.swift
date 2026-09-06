// Fork-only file, no upstream equivalent.
//
// This is the REAL-INDEXER ACCEPTANCE CHECK, not yet a proven gate — read
// `TRANSCRIPTED_ACCEPTANCE.md` for the distinction before trusting a green CI run to mean
// anything about this file. It drives the REAL `transcripted-mcp` binary — Mark's own
// separate "Transcripted" app's indexer, not a reimplementation or a mock — against a meeting
// file this fork's OWN `TranscriptedMarkdownExporter` actually wrote, and checks the real
// numbers the real indexer produced (word_count, speaker_count, action items with owners). A
// fork-produced file that scores `word_count: 0` here is a genuine defect in this exporter's
// output; a file that scores real numbers is the only proof that matters that this exporter's
// format isn't just self-consistent but actually legible to the tool it exists to feed.
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
// ROUND 3, BLOCKING 2 — READ THIS BEFORE CHANGING THE GATING BELOW. `.enabled(if:)` used to mean
// CI (and any machine without the real Transcripted app installed) SKIPPED this test — a skip
// reports as passing, indistinguishable in `xcodebuild`'s summary from a real pass. A green CI
// run therefore proved NOTHING about whether the real indexer ever actually ran.
//
// ROUND 5 — CLOSED, by adopting PR #19's (`phase2-realmodel-smoke`, merged to `main`) exact
// gate-running-mode idiom rather than inventing a second one: same shape
// (`.disabled(if: <prerequisite missing> && !isGateRunningMode, "...")`), same two-name split,
// same failure behavior. See `RealModelSmokeTests.swift` for the sibling this was copied from,
// and FOLLOWUPS.md's "Gate-running modes" central list for the repo-wide registry of these flags.
//
// THE COMMAND TO RUN, copy it exactly — this is the ONLY form that actually engages gate mode
// from outside the test process:
//
//     TEST_RUNNER_TRANSCRIPTED_ACCEPTANCE_GATE_MODE=1 xcodebuild test \
//       -project VoiceInk.xcodeproj -scheme VoiceInk -destination 'platform=macOS' \
//       -only-testing:VoiceInkTests/TranscriptedIndexerAcceptanceTests
//
// TWO DIFFERENT NAMES, ON PURPOSE, and getting this wrong silently defeats the whole mechanism —
// this was itself a BLOCKING review finding against PR #19, so it is spelled out again here
// rather than assumed carried over: `TEST_RUNNER_TRANSCRIPTED_ACCEPTANCE_GATE_MODE` is the
// EXTERNAL environment variable you set on the `xcodebuild` invocation above. `xcodebuild test`
// launches the actual test host through a LaunchServices-mediated path that does not inherit
// that shell's environment at all — except for variables prefixed `TEST_RUNNER_`, which it
// forwards into the test host process WITH THE PREFIX STRIPPED.
// `TRANSCRIPTED_ACCEPTANCE_GATE_MODE` (no `TEST_RUNNER_` prefix) is the UNPREFIXED name
// `isGateRunningMode` below reads via `ProcessInfo.processInfo.environment` INSIDE that
// already-launched test process — it is NOT something an external caller sets directly. Setting
// the unprefixed form on `xcodebuild`'s own invocation
// (`TRANSCRIPTED_ACCEPTANCE_GATE_MODE=1 xcodebuild test ...`) does NOTHING: it never crosses the
// LaunchServices boundary, `isGateRunningMode` reads `nil` inside the test host exactly as if
// gate mode were never requested, a missing prerequisite quietly SKIPS, and the run reports
// green — the exact false assurance this mechanism exists to prevent, reintroduced by a reader
// following an unprefixed instruction.
//
// What gate mode DOES guarantee, once engaged with the command above: with
// `TEST_RUNNER_TRANSCRIPTED_ACCEPTANCE_GATE_MODE=1` set on the `xcodebuild` invocation, this
// test passing means the real `transcripted-mcp` binary actually ran against a file this
// exporter wrote and produced real counts — a missing binary fails the run instead of skipping
// it. What it does NOT guarantee: it does not change ordinary runs where gate mode is NOT
// engaged (every CI run, every plain local `xcodebuild test`) — a machine without Mark's
// Transcripted app installed still skips cleanly there, which remains correct, desired
// convenience behavior for a fresh clone or CI runner, not a new guarantee. CI has never had the
// binary and is not expected to gain it, so CI never sets this flag — gate mode is for a real
// Mac with the binary present (the mini, so far), run by hand when the point is to prove nothing
// was skipped.

import Foundation
import Testing

@testable import VoiceInk

@Suite("Transcripted indexer acceptance (real binary, scratch dirs)")
struct TranscriptedIndexerAcceptanceTests {
    private static let binaryPath = "/Users/mark/Library/Application Support/Transcripted/mcp/transcripted-mcp"
    private static let sqlite3Path = "/usr/bin/sqlite3"

    /// Durable artefact path this test writes its actual measured output to, every time it
    /// runs (overwritten, not appended — this is "the last real result", not a log).
    /// `NSTemporaryDirectory()`-scoped scratch state (`scratchRoot` below) is deleted in
    /// `defer` before the test returns, so without this a reader has only the prose in
    /// `TRANSCRIPTED_ACCEPTANCE.md` to trust. Named in that file so a future reader can check
    /// the numbers directly instead.
    static let lastResultArtifactPath = "/tmp/voiceink-transcripted-acceptance-last-result.txt"

    private static var binaryIsAvailable: Bool {
        FileManager.default.fileExists(atPath: binaryPath) && FileManager.default.fileExists(atPath: sqlite3Path)
    }

    /// See this file's header, "THE COMMAND TO RUN", for the full mechanism. When set, a missing
    /// `transcripted-mcp` binary is no longer grounds to skip — the test runs anyway and fails
    /// for real (the `Process().run()` call throws) if the binary truly is not present.
    ///
    /// READ THIS BEFORE SETTING ANYTHING: the string below, `TRANSCRIPTED_ACCEPTANCE_GATE_MODE`,
    /// is the UNPREFIXED name this already-launched test process reads its own environment for —
    /// it is NOT what an external caller sets. Engaging this from outside requires the EXTERNAL,
    /// `TEST_RUNNER_`-prefixed form on the `xcodebuild` invocation instead:
    /// `TEST_RUNNER_TRANSCRIPTED_ACCEPTANCE_GATE_MODE=1 xcodebuild test ...` — xcodebuild strips
    /// the `TEST_RUNNER_` prefix when it forwards a variable into the test host, which is the
    /// ONLY way anything set on the outer `xcodebuild` command reaches this `ProcessInfo` lookup
    /// at all.
    private static var isGateRunningMode: Bool {
        ProcessInfo.processInfo.environment["TRANSCRIPTED_ACCEPTANCE_GATE_MODE"] != nil
    }

    @Test(
        "a fork-produced meeting file, with multiple speakers and action items, indexes with real word/speaker/action-item counts",
        .disabled(
            if: !Self.binaryIsAvailable && !Self.isGateRunningMode,
            "no real transcripted-mcp binary at \(Self.binaryPath)"
        )
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
        let actionItems = try Self.queryActionItems(indexDir: indexDir, filenameLike: "Acceptance Test Meeting")
        let expectedWordCount = segments.reduce(0) { $0 + $1.text.split(separator: " ").count }

        // Persisted BEFORE the assertions below, not after: if an assertion fails, the
        // artifact still reflects what was actually measured, not a result the test never
        // reached. `scratchRoot` (containing the real .md file and the real SQLite db this
        // ran against) is deleted in `defer` above regardless of pass/fail, so this plain-text
        // summary is the only durable record of the real query output.
        Self.persistResult(
            selfTest: selfTest, row: row, actionItems: actionItems,
            expectedWordCount: expectedWordCount, exportedFile: destination
        )

        // THE central assertion: a fork-produced file must not score zero. `word_count` from
        // the real SQLite index must reflect the real transcript, not come back empty because
        // this exporter's format didn't parse.
        #expect(row.wordCount > 0)
        #expect(row.wordCount == expectedWordCount)
        #expect(row.speakerCount == 3)  // You, Jane Doe, Sam Lee

        #expect(actionItems.count == 2)
        #expect(actionItems.contains { $0.owner == "Mark" && $0.text.contains("vendor on pricing") })
        #expect(actionItems.contains { $0.owner == nil && $0.text.contains("revised proposal") })
    }

    private static func persistResult(
        selfTest: SelfTestResult, row: MeetingRow, actionItems: [ActionItemRow],
        expectedWordCount: Int, exportedFile: URL
    ) {
        var lines = [
            "TranscriptedIndexerAcceptanceTests.exportedMeetingIndexesWithRealCounts()",
            "run at: \(ISO8601DateFormatter().string(from: Date()))",
            "exported file: \(exportedFile.path)",
            "--self-test: ok=\(selfTest.ok) meeting_file_count=\(selfTest.meetingFileCount)",
            "meetings row: word_count=\(row.wordCount) (independently-counted expected=\(expectedWordCount)) speaker_count=\(row.speakerCount)",
            "action items (\(actionItems.count)):",
        ]
        for item in actionItems {
            lines.append("  owner=\(item.owner ?? "<none>") text=\(item.text)")
        }
        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(toFile: lastResultArtifactPath, atomically: true, encoding: .utf8)
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

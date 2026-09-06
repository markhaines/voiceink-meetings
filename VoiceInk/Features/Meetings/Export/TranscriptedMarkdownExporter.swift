// Fork-only file, no upstream equivalent (Beingpax/VoiceInk has no meeting export at all).
//
// Renders a `Meeting` + `[MeetingSegment]` into the exact markdown shape Mark's existing
// Transcripted app writes into `~/Library/CloudStorage/OneDrive-ATEME/Transcripted/meetings/`,
// so his existing tooling (the Transcripted MCP server, the Anytype meeting sync, his Claude
// tooling) can index a file this exporter writes without any changes on their side.
//
// The shape below was reverse-engineered from 30 real, native-capture Transcripted files
// (`sources: [mic, system_audio]`, i.e. files Transcripted itself produced from a live
// recording, not its separate Anytype-import path) copied down from Mark's Mac Studio on
// 2026-09-06 and inspected byte-for-byte (`cat -vet`, `hexdump -C`) — not written from memory
// or belief. See `transcripted-exporter.md` (this task's report) for the verified byte
// evidence, the full frontmatter key inventory, and every field this exporter cannot populate
// yet because the fork's `Meeting`/`MeetingSegment` models don't carry that data (per-speaker
// db identity/confidence, the transcription/diarization engine identity, processing time,
// audio-gap/device-switch counts, and every `auto_summary_*` field the not-yet-built
// meeting-intelligence pass would produce beyond `actionItems`/`summary`). This exporter never
// fabricates those — it omits them.
//
// Two verified findings that contradicted this task's starting assumptions, so recorded here
// rather than left implicit in the code: utterance timestamps are `M+:SS` (total minutes,
// never fewer than 2 digits, never wrapping to `HH:MM:SS`) even past 99 minutes; and the
// native transcript body never renders a `## Summary` section in the body even when the
// frontmatter carries a full `auto_summary` — only Transcripted's separate Anytype-import path
// does that. Both were confirmed against the real files, not assumed.

import Foundation

/// Pure formatter over `Meeting` + `[MeetingSegment]`, plus a thin file-writing shell.
/// Everything except `write(meeting:segments:to:)` is filesystem-free and unit-testable.
enum TranscriptedMarkdownExporter {
    /// A rendered meeting, ready to write to disk.
    struct RenderedMeeting: Equatable {
        let filename: String
        let markdown: String
    }

    /// Renders `meeting` + `segments` into Transcripted's markdown shape. Pure: no I/O, no
    /// clock reads beyond what `meeting`/`segments` already carry.
    static func render(meeting: Meeting, segments: [MeetingSegment]) -> RenderedMeeting {
        let ordered = segments.sorted { lhs, rhs in
            if lhs.startOffset != rhs.startOffset { return lhs.startOffset < rhs.startOffset }
            return lhs.orderIndex < rhs.orderIndex
        }
        return RenderedMeeting(
            filename: renderFilename(date: meeting.startDate, title: meeting.title),
            markdown: renderMarkdown(meeting: meeting, segments: ordered)
        )
    }

    /// Writes the rendered meeting into `directory` (created if it doesn't exist yet) and
    /// returns the destination file URL. The only part of this exporter that touches the
    /// filesystem — callers own deciding *which* directory that is; this never assumes or
    /// hardcodes a path, real-library or otherwise.
    @discardableResult
    static func write(meeting: Meeting, segments: [MeetingSegment], to directory: URL) throws -> URL {
        let rendered = render(meeting: meeting, segments: segments)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(rendered.filename)
        try rendered.markdown.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    // MARK: - Filename

    /// `YYYY-MM-DD <Title>.md`. Transcripted's own filenames never contain a literal `:` —
    /// confirmed by comparing a real title's frontmatter/H1 form ("Meeting at 2:00 pm")
    /// against its on-disk filename ("2026-07-31 Meeting at 2 00 pm.md"): the colon becomes a
    /// single space, nothing else about the title changes (brackets, apostrophes, commas, and
    /// an en dash all appear verbatim in other real filenames). `/` is never observed in a
    /// real title — replacing it is a defensive addition, not a verified rule, since an
    /// unescaped `/` would otherwise split the path.
    static func renderFilename(date: Date, title: String) -> String {
        "\(Self.dateStampFormatter.string(from: date)) \(filenameSafe(title)).md"
    }

    private static func filenameSafe(_ title: String) -> String {
        title
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "/", with: "-")
    }

    // MARK: - Markdown body

    private static func renderMarkdown(meeting: Meeting, segments: [MeetingSegment]) -> String {
        var out = "---\n"
        out += frontmatter(meeting: meeting, segments: segments)
        out += "---\n\n"
        out += "# \(meeting.title)\n\n"
        out += recordedLine(meeting: meeting, segments: segments)
        out += "\n\n"
        out += "## Transcript\n\n"
        out += transcriptBody(segments: segments)
        out += "\n"
        return out
    }

    private static func recordedLine(meeting: Meeting, segments: [MeetingSegment]) -> String {
        let totalWordCount = segments.reduce(0) { $0 + wordCount(in: $1.text) }
        let turnCount = segments.count
        return "Recorded \(recordedDateFormatter.string(from: meeting.startDate)) at "
            + "\(recordedTimeFormatter.string(from: meeting.startDate))\(bullet)"
            + "\(durationPhrase(meeting.duration))\(bullet)"
            + "\(totalWordCount) word\(totalWordCount == 1 ? "" : "s")\(bullet)"
            + "\(turnCount) turn\(turnCount == 1 ? "" : "s")"
    }

    private static func transcriptBody(segments: [MeetingSegment]) -> String {
        segments
            .map { segment in
                let channelWord = segment.sourceChannel == .mic ? "Mic" : "System"
                return "**\(timestamp(segment.startOffset))**  [\(channelWord)/\(segment.speakerLabel)]\n\(segment.text)"
            }
            .joined(separator: "\n\n")
    }

    // MARK: - Frontmatter

    private static func frontmatter(meeting: Meeting, segments: [MeetingSegment]) -> String {
        let micSegments = segments.filter { $0.sourceChannel == .mic }
        let systemSegments = segments.filter { $0.sourceChannel == .system }
        let micSpeakers = Set(micSegments.map(\.speakerLabel))
        let systemSpeakers = orderedUnique(systemSegments.map(\.speakerLabel))
        let totalWordCount = segments.reduce(0) { $0 + wordCount(in: $1.text) }

        var sources: [String] = []
        if !micSegments.isEmpty { sources.append("mic") }
        if !systemSegments.isEmpty { sources.append("system_audio") }

        var lines: [String] = []
        lines.append("title: \(yamlQuoted(meeting.title))")
        lines.append("capture_id: \(yamlQuoted(meeting.id.uuidString))")
        lines.append("capture_type: meeting")
        lines.append("format_version: 1")
        lines.append("transcript_id: \(yamlQuoted(meeting.id.uuidString))")
        lines.append("date: \(dateStampFormatter.string(from: meeting.startDate))")
        lines.append("time: \(frontmatterTimeFormatter.string(from: meeting.startDate))")
        lines.append("duration: \(yamlQuoted(timestamp(meeting.duration)))")
        lines.append("sources: [\(sources.joined(separator: ", "))]")
        lines.append("mic_utterances: \(micSegments.count)")
        lines.append("system_utterances: \(systemSegments.count)")
        lines.append("mic_speakers: \(micSpeakers.count)")
        lines.append("system_speakers: \(systemSpeakers.count)")
        lines.append("total_word_count: \(totalWordCount)")

        if !systemSpeakers.isEmpty {
            lines.append("speakers:")
            for (index, name) in systemSpeakers.enumerated() {
                lines.append("  - id: \(yamlQuoted(String(index + 1)))")
                lines.append("    channel: system")
                lines.append("    name: \(yamlQuoted(name))")
            }
        }

        lines.append("auto_summary_action_items: \(yamlQuoted(actionItemsField(meeting.actionItems)))")
        lines.append("auto_summary: \(yamlQuoted(summaryField(meeting.summary)))")

        return lines.map { $0 + "\n" }.joined()
    }

    private static func actionItemsField(_ items: [String]) -> String {
        guard !items.isEmpty else { return "None found." }
        return items.map { "- \($0)" }.joined(separator: " | ")
    }

    private static func summaryField(_ summary: String?) -> String {
        guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "None found."
        }
        return summary
    }

    private static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: - Timestamp / duration formatting

    /// `M+:SS` — total minutes (never fewer than 2 digits, never wrapping to hours) and
    /// zero-padded seconds. Verified against a real 132-minute meeting: `**68:28**`, not
    /// `**01:08:28**`.
    private static func timestamp(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// The "Recorded ..." line's duration phrase. Verified quirks kept deliberately, not
    /// "fixed": `min` never pluralizes to `mins` in any real native-capture file regardless of
    /// count (only Transcripted's separate, older Anytype-import renderer does that), while
    /// `sec`/`hr` do pluralize normally. Seconds are dropped entirely once the duration reaches
    /// an hour. The zero-minutes-with-an-hour case ("1 hr, 0 min") is not attested in any real
    /// sample; this falls out of the same rule rather than being special-cased.
    private static func durationPhrase(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes >= 60 {
            let hours = minutes / 60
            let remainderMinutes = minutes % 60
            return "\(hours) hr\(hours == 1 ? "" : "s"), \(remainderMinutes) min"
        }

        var phrase = "\(minutes) min"
        if seconds > 0 {
            phrase += ", \(seconds) sec\(seconds == 1 ? "" : "s")"
        }
        return phrase
    }

    private static let bullet = "  \u{2022}  "

    private static let dateStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let frontmatterTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let recordedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    private static let recordedTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

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
//
// ROUND 2 — verified against the real INDEXER's source, not just its output files.
// `~/code/transcripted` is Mark's own separate project (the "Transcripted" app); its MCP
// server shares parsing logic with the CLI via
// `Tools/TranscriptedCaptureKit/Sources/TranscriptedCaptureKit/CaptureMarkdownParser.swift`.
// Reading `parseTranscriptEntries`/`parseStyledTranscriptEntry` there (confirmed by grep +
// `sed`, not assumed) settles two things this file used to get slightly wrong:
//
// 1. The two-space separator below (`**MM:SS**  [Channel/Label]`) is BYTE-PARITY with what
//    Transcripted itself writes — nothing more. The indexer's own header regex is
//    `^([0-9:]+)\s+\[(.+?)\]$` (`\s+`, one-or-more whitespace, not two literal spaces), so a
//    single space would index identically. Two spaces earns its place here only because
//    matching Transcripted's own byte output was this exporter's Round 1 mandate.
// 2. The ACTUAL fail-silent invariants the indexer enforces are: (a) each utterance's header,
//    after stripping `**`, must be a single physical line matching that regex; (b) the
//    bracketed content must contain a `/` (there is no fallback source/label separator); and
//    (c) `## Transcript\n\n` splits the rest of the document into chunks on blank lines
//    (`\n\n`) BEFORE the header regex ever runs — a chunk whose header doesn't match is
//    dropped by `compactMap` with no error, no warning, and the file still looks correct to a
//    human. See `TranscriptSanitizer` below for what that means for two fields this exporter
//    doesn't control the content of.

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
    ///
    /// Every segment is passed through `TranscriptSanitizer` exactly once, here, before
    /// anything downstream (the transcript header, the `speakers:` block, the mic/system
    /// speaker counts, the word count) ever sees it — see that type's doc comment for why. A
    /// single choke point means there is no second code path that could read the raw,
    /// unsanitized `speakerLabel`/`text` and reintroduce the fail-silent case.
    static func render(meeting: Meeting, segments: [MeetingSegment]) -> RenderedMeeting {
        let ordered = segments.sorted { lhs, rhs in
            if lhs.startOffset != rhs.startOffset { return lhs.startOffset < rhs.startOffset }
            return lhs.orderIndex < rhs.orderIndex
        }
        let sanitized = ordered.map(SanitizedSegment.init)
        return RenderedMeeting(
            filename: renderFilename(date: meeting.startDate, title: meeting.title),
            markdown: renderMarkdown(meeting: meeting, segments: sanitized)
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

    /// `YYYY-MM-DD <Title>`, with no extension — the shared identity between this exporter's
    /// `.md` file and `TranscriptedAudioExporter`'s `<stem>_audio/` directory. Pulled out of
    /// `renderFilename` (Phase 3 audio export) so the audio exporter reuses this exact
    /// derivation instead of re-implementing the colon/slash rule independently, which would
    /// silently break the pairing between a meeting's markdown file and its audio directory if
    /// the two rules ever drifted. Behaviorally identical to what `renderFilename` computed
    /// before this split: same `dateStampFormatter`, same `filenameSafe`, same argument order.
    static func renderStem(date: Date, title: String) -> String {
        "\(Self.dateStampFormatter.string(from: date)) \(filenameSafe(title))"
    }

    /// `YYYY-MM-DD <Title>.md`. Transcripted's own filenames never contain a literal `:` —
    /// confirmed by comparing a real title's frontmatter/H1 form ("Meeting at 2:00 pm")
    /// against its on-disk filename ("2026-07-31 Meeting at 2 00 pm.md"): the colon becomes a
    /// single space, nothing else about the title changes (brackets, apostrophes, commas, and
    /// an en dash all appear verbatim in other real filenames). `/` is never observed in a
    /// real title — replacing it is a defensive addition, not a verified rule, since an
    /// unescaped `/` would otherwise split the path.
    static func renderFilename(date: Date, title: String) -> String {
        "\(renderStem(date: date, title: title)).md"
    }

    private static func filenameSafe(_ title: String) -> String {
        title
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "/", with: "-")
    }

    // MARK: - Markdown body

    private static func renderMarkdown(meeting: Meeting, segments: [SanitizedSegment]) -> String {
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

    private static func recordedLine(meeting: Meeting, segments: [SanitizedSegment]) -> String {
        let totalWordCount = segments.reduce(0) { $0 + wordCount(in: $1.text) }
        let turnCount = segments.count
        return "Recorded \(recordedDateFormatter.string(from: meeting.startDate)) at "
            + "\(recordedTimeFormatter.string(from: meeting.startDate))\(bullet)"
            + "\(durationPhrase(meeting.duration))\(bullet)"
            + "\(totalWordCount) word\(totalWordCount == 1 ? "" : "s")\(bullet)"
            + "\(turnCount) turn\(turnCount == 1 ? "" : "s")"
    }

    private static func transcriptBody(segments: [SanitizedSegment]) -> String {
        segments
            .map { segment in
                let channelWord = segment.channel == .mic ? "Mic" : "System"
                return "**\(timestamp(segment.startOffset))**  [\(channelWord)/\(segment.speakerLabel)]\n\(segment.text)"
            }
            .joined(separator: "\n\n")
    }

    // MARK: - Frontmatter

    private static func frontmatter(meeting: Meeting, segments: [SanitizedSegment]) -> String {
        let micSegments = segments.filter { $0.channel == .mic }
        let systemSegments = segments.filter { $0.channel == .system }
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

        // `auto_summary_version` is not merely another gap-filled field: the real indexer's
        // `CaptureSummaryParser.parse` (`~/code/transcripted/Tools/TranscriptedCaptureKit/
        // Sources/TranscriptedCaptureKit/CaptureSummaryParser.swift:72`) only reads
        // `auto_summary_action_items`/`auto_summary` at all when
        // `values["auto_summary_version"] != nil` — every real native-capture file always
        // carries this key (verified across all 30). Omitting it, as Round 1 did, means the
        // action items below are syntactically well-formed but the indexer never looks at
        // them: `read_meeting`/`list_action_items` would silently return nothing, for a
        // reason invisible from the file's own action-items line. Round 2 found this by
        // tracing the real parser source for deliverable 3, not by observation of a symptom.
        lines.append("auto_summary_version: \"1\"")
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
    ///
    /// Clamped to a non-negative offset: the indexer's own timestamp character class is
    /// `[0-9:]+` (see the header regex cited at the top of this file) with no `-`, so a
    /// negative offset — which should never occur, but nothing upstream of this formatter is
    /// typed to make it impossible — would otherwise render a leading `-` that fails the
    /// header regex outright and silently drops the utterance, the same class of failure
    /// `TranscriptSanitizer` exists to close off for `speakerLabel`/`text`.
    private static func timestamp(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
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

/// A `MeetingSegment` with `speakerLabel`/`text` already passed through
/// `TranscriptSanitizer`. Built exactly once, in `render(meeting:segments:)` — every renderer
/// below consumes this type, never `MeetingSegment` directly, so there is no path from a raw
/// segment to the output markdown that skips sanitization.
private struct SanitizedSegment {
    let startOffset: TimeInterval
    let channel: MeetingSegmentChannel
    let speakerLabel: String
    let text: String

    init(_ segment: MeetingSegment) {
        self.startOffset = segment.startOffset
        self.channel = segment.sourceChannel
        self.speakerLabel = TranscriptSanitizer.speakerLabel(segment.speakerLabel)
        self.text = TranscriptSanitizer.utteranceText(segment.text)
    }
}

/// Sanitization boundary for the two user/transcriber-supplied strings that flow into
/// Transcripted's fail-silent utterance format: `MeetingSegment.speakerLabel` and `.text`.
///
/// WHY THIS EXISTS, traced from the real indexer's source
/// (`~/code/transcripted/Tools/TranscriptedCaptureKit/Sources/TranscriptedCaptureKit/
/// CaptureMarkdownParser.swift`, `parseTranscriptEntries`/`parseStyledTranscriptEntry`,
/// confirmed by reading the function bodies, not inferred from behavior):
///
/// - `## Transcript\n\n` splits everything after it into chunks on blank lines (`\n\n`)
///   BEFORE any per-utterance parsing happens (`components(separatedBy: "\n\n")`, line 434).
/// - Each chunk's first physical line, after stripping `**`, must match
///   `^([0-9:]+)\s+\[(.+?)\]$` (line 477) and the bracket content must contain a `/` (line
///   483) or the ENTIRE chunk is dropped by `compactMap` — silently: no error, no warning,
///   the file still looks correct to a human, `word_count`/`speaker_count` just come back low
///   or zero.
///
/// Two fields this exporter renders into that scaffold are not under this exporter's control:
///
/// - `speakerLabel` becomes user-editable once the Phase 2 speaker-rename UI lands. A
///   newline inside it breaks the header across two physical lines — the regex's `$` anchor
///   then never sees a closing `]` on the SAME line as the timestamp, the whole utterance is
///   dropped. `]`, `[`, and `/` inside a label were checked against the actual regex
///   (non-greedy `.+?` anchored to end-of-line via `$`, and a `firstIndex(of: "/")` split
///   against a bracket that always starts with a slash-free `Mic`/`System` constant) and do
///   NOT trigger this failure — they are deliberately left untouched here rather than
///   sanitized away, so a legitimate name (`"D'Angelo"`, a label someone chose to bracket)
///   isn't mangled for a risk that isn't real. Newlines and other control characters are
///   removed/collapsed, because those are the only inputs that can put a line break inside a
///   single-line header.
///   A RUN OF TWO OR MORE consecutive `*` is a DIFFERENT, SILENT failure, not a
///   dropped-utterance one: before the header regex ever runs, `parseStyledTranscriptEntry`
///   does `header.replacingOccurrences(of: "**", with: "")` on the WHOLE header line — the
///   timestamp's own `**MM:SS**` markup relies on exactly this to get stripped away. That
///   same call strips ANY `**` inside the label too: `"Jo**hn"` resolves to `"John"`,
///   `"**Mark**"` resolves to `"Mark"`, a label that is just `"**"` resolves to an EMPTY
///   string. The utterance survives (the regex still matches), but the resolved identity
///   silently differs from what this exporter wrote — which is worse than dropping the
///   utterance, because there is no signal anywhere that anything changed.
///   A LONE `*` IS NOT AFFECTED and is deliberately left alone: `replacingOccurrences` only
///   matches the literal two-character substring, so `"a*b"`, `"*Mark*"` and `"* *"` already
///   resolve back byte-identically. Verified directly against the real rule, not assumed —
///   see `speakerLabel(_:)` for the policy applied to the runs that genuinely cannot survive.
/// - `text` is transcription output. A literal blank line inside it (`\n\n`) IS the exact
///   chunk boundary above — it silently truncates the utterance: everything up to the blank
///   line survives as one dropped-looking-fine chunk, everything after becomes an orphaned
///   chunk with no valid header, which fails the regex and vanishes from the index while
///   still sitting, visibly, in the `.md` file on disk. Collapsing blank lines makes a
///   mid-utterance chunk split structurally impossible, not just unlikely — there is no
///   longer any string this function can produce that contains `\n\n`.
enum TranscriptSanitizer {
    /// Replaces every newline (and other whitespace-ish control character, e.g. tab) with a
    /// single space — never removes the label's content entirely, a two-line label becomes
    /// one line, not nothing — drops genuinely non-whitespace control characters (NUL and
    /// friends) outright, and collapses runs of whitespace so the result reads the same as
    /// the original to a person. `[`, `]`, `/` pass through untouched; see this type's doc
    /// comment for why those are safe.
    ///
    /// THE INVARIANT, and the whole reason this function touches `*` at all: the label this
    /// exporter WRITES and the label the real indexer RESOLVES must be the same string, and it
    /// must be a string a human would recognise as the name they typed.
    ///
    /// The indexer strips every literal `**` from the whole header line unconditionally (see
    /// this type's doc comment). That is not a bug to route around — it is the mechanism that
    /// removes the timestamp's own bold markup, and this exporter cannot change it. It matches
    /// the literal two-character substring only, so the hazard is EXACTLY "a run of two or more
    /// consecutive asterisks", and nothing else:
    ///
    /// - Losslessly representable AS FAR AS THE ASTERISK PASS IS CONCERNED: no asterisk at all
    ///   (`"Jane Doe"`, `"D'Angelo"`), and any lone asterisk (`"a*b"`, `"*Mark*"`, `"* *"`). Each
    ///   of these round-trips byte-identically through the real rule ONCE the normalization
    ///   above has run — named exactly, not just described, so the claim is falsifiable: (1)
    ///   every Unicode scalar for which `CharacterSet.whitespacesAndNewlines.contains(scalar)`
    ///   is true becomes a single ASCII space (U+0020); this check runs BEFORE the
    ///   control-character check, so a scalar in both sets (TAB, LF, CR, NEL U+0085 are in
    ///   both `whitespacesAndNewlines` and `controlCharacters`) is normalized to a space here,
    ///   never dropped by step (2); `whitespacesAndNewlines` also covers non-ASCII space
    ///   separators (verified directly, not assumed from documentation: NO-BREAK SPACE U+00A0,
    ///   LINE SEPARATOR U+2028, and IDEOGRAPHIC SPACE U+3000 all test `true` and are each
    ///   normalized to a plain space exactly like ASCII whitespace — see
    ///   `nonASCIIUnicodeWhitespaceNormalizesLikeASCIIWhitespace` for the pinned cases). (2) any
    ///   scalar step (1) did not already consume for which
    ///   `CharacterSet.controlCharacters.contains(scalar)` is true — genuinely non-whitespace
    ///   controls such as NUL — is dropped outright. (3) the result of (1)+(2), which now
    ///   contains only U+0020 as whitespace, is split on `CharacterSet.whitespaces`, empty
    ///   components are filtered out, and the parts are rejoined with a single `" "` — this
    ///   collapses any run (including one step (1) just created) and strips leading/trailing
    ///   whitespace. Each of `" Jane  Doe "`, `"*\u{0000}a"`, `"Jane\u{00A0}Doe"`, `"*\u{2028}*"`
    ///   and `"*\u{3000}*"` is changed by steps (1)-(3) and is NOT returned byte-identical to
    ///   what was typed — the guarantee is byte-identical to the value steps (1)-(3) produce,
    ///   never to the raw input. Transforming that already-normalized value further would
    ///   corrupt input that was never at risk, so the asterisk pass (4) makes no additional
    ///   change to it — enforced by the early return below, not merely intended.
    /// - Not representable at all: a run of 2+ asterisks. Whatever is written, the indexer
    ///   deletes pairs from it, so no run of 2+ can survive. There is no encoding that fixes
    ///   this, because the indexer performs NO unescaping of any kind — not Markdown, not
    ///   backslashes (confirmed by reading `parseStyledTranscriptEntry`, and
    ///   `parseFrontmatterSpeakers`, which only strips surrounding `"` characters). Writing
    ///   `\*` therefore stores literal backslashes that the reader then SEES, in both the
    ///   transcript header and the `speakers:` names — a persistent visible corruption, and the
    ///   reason that approach was withdrawn.
    ///
    /// THE POLICY for that unrepresentable case: collapse each run of 2+ asterisks to a single
    /// `*`. Deterministic, idempotent, and provably safe for any run length — the output can
    /// contain no `**` substring at all, so the indexer's strip step has nothing to remove and
    /// the resolved label is byte-identical to the exported one. It is LOSSY, deliberately and
    /// visibly: `"**Mark**"` exports and indexes as `"*Mark*"`, `"Jo**hn"` as `"Jo*hn"`, and
    /// `"**"` / `"****"` alike as `"*"`. Run length is not recoverable. That is the price of a
    /// consumer with no escape syntax, and it is preferred to the alternatives:
    /// - REJECTING the export would fail (or silently skip) a whole meeting because a speaker
    ///   name has two asterisks in it — disproportionate, and there is no UI on this path to
    ///   surface the rejection to anyone.
    /// - SUBSTITUTING a Unicode lookalike (`∗`, U+2217) would round-trip, but stores a
    ///   character the user never typed and cannot type back, and reads as a different name
    ///   everywhere the label is later displayed or matched.
    /// - MIRRORING the indexer and deleting the pairs ourselves would agree with the indexer
    ///   while erasing the asterisks entirely, turning a bare `"**"` label into an empty
    ///   string. Collapsing keeps the evidence that an asterisk was there.
    ///
    /// THIS IS A LAST LINE OF DEFENCE, NOT THE DURABLE FIX. The durable fix is input validation
    /// at the Phase 2 speaker-rename UI, where a person can be told "that name cannot be stored
    /// exactly" while they still have the keyboard in their hands. That UI does not exist yet.
    /// Until it does, this function's job is to guarantee the invariant no matter what reaches
    /// it, and to be lossy in a way that is documented and predictable rather than silent.
    static func speakerLabel(_ raw: String) -> String {
        // Whitespace and control normalization runs FIRST, and the asterisk pass runs on its
        // result — never the other way round. Dropping a control character can join two
        // previously separated asterisks into a new run (`"*\u{0000}*"` becomes `"**"`), so an
        // asterisk pass over the raw input would miss exactly the case it exists to catch.
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                scalars.append(" ")
            } else if CharacterSet.controlCharacters.contains(scalar) {
                continue
            } else {
                scalars.append(scalar)
            }
        }

        let whitespaceCollapsed = String(scalars)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return collapsingAsteriskRuns(whitespaceCollapsed)
    }

    /// Collapses every run of two or more consecutive `*` to a single `*`. Everything else,
    /// lone asterisks included, is returned untouched — the `contains("**")` early return makes
    /// that a structural guarantee rather than a property of the loop below.
    ///
    /// The output can never contain `**`: every run becomes exactly one asterisk, and two runs
    /// cannot merge because a non-asterisk always separated them in the input.
    private static func collapsingAsteriskRuns(_ value: String) -> String {
        guard value.contains("**") else { return value }

        var result = ""
        result.reserveCapacity(value.count)
        var asteriskRun = 0
        for character in value {
            if character == "*" {
                asteriskRun += 1
                continue
            }
            if asteriskRun > 0 {
                result.append("*")
                asteriskRun = 0
            }
            result.append(character)
        }
        if asteriskRun > 0 {
            result.append("*")
        }
        return result
    }

    /// Collapses every blank line (any line that is empty after trimming) out of the text —
    /// not just "\n\n" literally, so "\n \n" (whitespace-only line) and longer runs of blank
    /// lines are caught too — while preserving single line breaks between otherwise non-empty
    /// lines, and trims leading/trailing whitespace so the sanitized text can never itself
    /// begin or end with a newline that could recombine with this exporter's own `\n\n`
    /// block separator into a new blank line at a chunk boundary.
    static func utteranceText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

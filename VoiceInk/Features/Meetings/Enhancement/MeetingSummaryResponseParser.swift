// New for this fork (Phase 3). Not a port.
//
// Parses the plain-text response `MeetingSummaryPrompt` asks the model for into a
// `MeetingSummary`-shaped set of raw sections, or reports that the response could not be parsed
// at all. Pure and synchronous: no networking, no model access, so it is testable directly
// against fixed strings without a fake provider in the loop.
//
// PARSING PHILOSOPHY: lenient about formatting noise a real model can plausibly add despite the
// prompt's instructions (a wrapping code fence, blank lines, a missing "- " bullet marker,
// inconsistent header casing), strict about the one thing that actually matters -- never
// inventing content. A section the model left out, or explicitly marked "None", comes back
// empty; nothing here fills a missing section with a guess.
import Foundation

/// The raw, unattributed parse of a model response: four sections, matching
/// `MeetingSummaryPrompt`'s required headers, before `MeetingSummaryService` adds the
/// independently-computed `participants` and `wasTruncated` fields `MeetingSummary` also needs.
struct ParsedMeetingSummarySections: Equatable {
    let purpose: String
    let questions: [String]
    let conclusions: [String]
    let actionItems: [MeetingActionItem]
}

enum MeetingSummaryResponseParser {
    private enum Section: String, CaseIterable {
        case purpose = "PURPOSE"
        case questions = "QUESTIONS"
        case conclusions = "CONCLUSIONS"
        case actionItems = "ACTION_ITEMS"
    }

    /// An action-item line's text before its first `:` is only ever read as an owner name when
    /// it is at most this many characters. Without some cap, a line like
    /// "- Review the API: check the auth flow" -- a colon inside the ACTION text itself, not an
    /// owner separator -- would misparse "Review the API" as an owner. This is the same
    /// first-colon heuristic the downstream Transcripted indexer already applies to a stored
    /// action item's leading `"Name: "` prefix (per this task's brief), so it cannot be replaced
    /// with a smarter one without breaking compatibility with that consumer; the length cap is
    /// this parser's own mitigation to keep the common false-positive case (a clause, not a
    /// name, before a stray colon) from being misread as an owner. A genuine long name would
    /// still be misparsed as text-only past this length -- documented, not silently assumed
    /// impossible.
    private static let maxOwnerCandidateLength = 40

    /// Returns `nil` when `raw` contains not one recognized section header -- i.e. the model
    /// ignored the requested format entirely. `MeetingSummaryService` maps that to
    /// `.unparseable(rawText:)`. A response with SOME but not all four headers still parses: the
    /// missing sections come back empty, which is the honest reading of "the model didn't
    /// produce this section" and not grounds to discard sections it did produce correctly.
    static func parse(_ raw: String) -> ParsedMeetingSummarySections? {
        let unfenced = stripWrappingCodeFence(raw)
        let lines = unfenced.components(separatedBy: "\n")

        var buffers: [Section: [String]] = [:]
        var current: Section?
        var foundAnyHeader = false

        for line in lines {
            if let section = matchHeader(line) {
                current = section
                foundAnyHeader = true
                buffers[section] = buffers[section] ?? []
                continue
            }
            guard let current else { continue }
            buffers[current, default: []].append(line)
        }

        guard foundAnyHeader else { return nil }

        return ParsedMeetingSummarySections(
            purpose: parseProse(buffers[.purpose] ?? []),
            questions: parseList(buffers[.questions] ?? []),
            conclusions: parseList(buffers[.conclusions] ?? []),
            actionItems: parseActionItems(buffers[.actionItems] ?? [])
        )
    }

    /// Matches a line that is (after trimming whitespace) exactly one of the four header words
    /// followed by a colon and nothing else, case-insensitively -- lenient on casing since the
    /// prompt's requested casing is a request, not something this parser can enforce, but strict
    /// on shape so an ordinary sentence that happens to start with one of these words (e.g. a
    /// purpose line reading "Questions came up about...") is never mistaken for a header.
    private static func matchHeader(_ line: String) -> Section? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(":") else { return nil }
        let word = String(trimmed.dropLast()).uppercased()
        return Section.allCases.first { $0.rawValue == word }
    }

    /// Strips a single leading/trailing ``` fence (with an optional language tag on the opening
    /// line, e.g. ```text) if the WHOLE trimmed response is wrapped in one. Only ever removes a
    /// fence that wraps everything -- a fence appearing inside otherwise well-formed sections is
    /// left alone, since stripping it there could silently delete a line the model meant to keep.
    private static func stripWrappingCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count > 6 else { return text }

        var lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 2 else { return text }
        lines.removeFirst()  // opening fence, with any language tag
        guard lines.last?.trimmingCharacters(in: .whitespaces) == "```" else { return text }
        lines.removeLast()
        return lines.joined(separator: "\n")
    }

    /// Matches "None", case-insensitively, with or without a trailing period -- the prompt asks
    /// for exactly "None" but a real model asked to write a short standalone sentence (`PURPOSE`
    /// is prose, not a bulleted list) will plausibly punctuate it as "None." anyway. Tolerating
    /// that is a parsing leniency, not a prompt ambiguity: nothing about accepting "None." here
    /// risks treating REAL content as empty, since both spellings mean the same thing.
    private static func isNone(_ text: String) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed.caseInsensitiveCompare("None") == .orderedSame
    }

    private static func parseProse(_ lines: [String]) -> String {
        let nonEmpty = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty, !(nonEmpty.count == 1 && isNone(nonEmpty[0])) else { return "" }
        return nonEmpty.joined(separator: " ")
    }

    private static func parseList(_ lines: [String]) -> [String] {
        var items: [String] = []
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !isNone(trimmed) else { continue }
            let withoutBullet = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
            guard !withoutBullet.isEmpty else { continue }
            items.append(withoutBullet)
        }
        return items
    }

    private static func parseActionItems(_ lines: [String]) -> [MeetingActionItem] {
        parseList(lines).map { line in
            guard let colonIndex = line.firstIndex(of: ":") else {
                return MeetingActionItem(owner: nil, text: line)
            }
            let candidateOwner = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            let remainder = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            guard !candidateOwner.isEmpty, candidateOwner.count <= maxOwnerCandidateLength, !remainder.isEmpty else {
                return MeetingActionItem(owner: nil, text: line)
            }
            return MeetingActionItem(owner: candidateOwner, text: remainder)
        }
    }
}

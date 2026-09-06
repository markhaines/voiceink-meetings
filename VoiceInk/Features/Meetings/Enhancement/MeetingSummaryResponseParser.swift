// New for this fork (Phase 3). Not a port.
//
// Parses the plain-text response `MeetingSummaryPrompt` asks the model for into a
// `MeetingSummary`-shaped set of raw sections, or reports that the response could not be parsed
// at all. Pure and synchronous: no networking, no model access, so it is testable directly
// against fixed strings without a fake provider in the loop.
//
// THE ONE PROPERTY THIS FILE EXISTS TO HOLD, stated once and then implemented literally:
//
//     A parse either represents EVERY line of the model's response, or it fails.
//     It never returns a `ParsedMeetingSummarySections` -- which `MeetingSummaryService` turns
//     into a `.summary`, i.e. a result that presents itself as complete -- while having silently
//     DROPPED, TRUNCATED or ABSORBED any of that response's content.
//
// That property has been defeated three times, every time by a rule that was right for one real
// response shape and wrong for another:
//   1. Accepting a response carrying a single recognized header, with the other three sections
//      silently defaulting to empty -- a `.summary` indistinguishable from a genuine four-section
//      parse. Closed by requiring all four headers (see `parse`).
//   2. The fix for a trailing model sign-off being absorbed as a list item: "stop collecting at
//      the second un-bulleted line". Right for a sign-off; catastrophic for a wrapped
//      continuation line, a multi-paragraph section, or a real final action item after a stray
//      line, all of which it silently discarded while still returning a complete-looking
//      `.summary`. A silently shortened ACTION_ITEMS list means an action Mark agreed to is
//      simply absent from a document that reads as finished -- worse than no summary at all.
//   3. Two more of the same shape, found by review of the fix for (2). Text before the first
//      header was DROPPED on the argument that it belongs to no section -- but it can just as
//      easily BE the real purpose, written above its own header, and the rule cannot tell the two
//      apart. And a nested sub-bullet was RECLASSIFIED as a new top-level item, because the
//      bullet test ran before the indentation test: one owned action became that action plus a
//      second, ownerless one, silently flattening the hierarchy the model wrote. Both now follow
//      the rule below -- refuse, and attribute-by-nesting, respectively.
//
// THE RULE THIS FILE NOW FOLLOWS, in place of all of them:
//
//   * ATTRIBUTION IS BY HEADER. Every line between one recognized header and the next belongs to
//     that section. Nothing under a header is ever discarded.
//   * WITHIN A SECTION, THE SECTION'S KIND DECIDES HOW ITS LINES BECOME CONTENT.
//     - PURPOSE is PROSE: all of it is the purpose. Paragraphs (blank-line-separated) are
//       preserved as paragraphs; wrapped lines within a paragraph are joined. Prose has no
//       internal structure for a foreign line to violate, so there is nothing to detect and
//       nothing is dropped.
//     - QUESTIONS / CONCLUSIONS / ACTION_ITEMS are LISTS, and a list has item boundaries that a
//       line can be ambiguous about. Item boundaries come from exactly two unambiguous signals:
//       a bullet marker, and a blank line. See `parseList` for the three cases and which one
//       refuses.
//   * WHEN A LINE'S ATTRIBUTION IS GENUINELY AMBIGUOUS, THIS PARSER REFUSES: `parse` returns
//     `nil`, which `MeetingSummaryService` maps to `.unparseable(rawText:)`, keeping the model's
//     full response for diagnostics. It does not guess, and it does not return a shortened
//     result that reads as complete. On this project a loud failure has always been cheaper than
//     a plausible wrong answer, and this is the file where that trade is actually made.
//
// WHAT REFUSING COSTS, stated plainly rather than left to be discovered: a model that appends
// "Let me know if you have any other questions!" after its last section now costs the WHOLE
// summary, not just that line. The prompt forbids exactly that ("Do not add any other section,
// preamble, or closing remark"), so it should be rare -- but "rare" is not "never", and when it
// happens Mark gets `.unparseable` and no notes rather than notes with one bogus trailing item.
// That is the deliberate choice: the alternative rules are (a) absorb it, which puts words
// nobody said into an action item the downstream indexer will attribute to an owner, or (b) drop
// it, which is indistinguishable from dropping a real final action item -- defeat #2 above. Only
// refusal is honest about the fact that this parser cannot tell those apart. `.unparseable`
// carries `rawText`, so nothing the model said is destroyed by refusing; a caller can show it or
// ask again.
//
// STILL LENIENT, deliberately, about formatting noise that does NOT create ambiguity: a wrapping
// code fence, blank lines, inconsistent header casing, a section written as one un-bulleted
// sentence, and bullet markers the prompt did not ask for (`*`, `•`, `1.`). Widening what counts
// as a confident signal is the opposite of guessing -- every marker recognized here is one more
// response shape that parses exactly rather than refusing.
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
    /// impossible. Note this never loses content either way: the full line is kept, only the
    /// owner/text split differs.
    private static let maxOwnerCandidateLength = 40

    /// Returns `nil` -- `.unparseable(rawText:)` at the service level -- in exactly two cases:
    ///
    /// 1. **Not all four headers are present.** Not "at least one", the original (first blocking
    ///    finding) behavior, under which a response carrying a single recognized header produced
    ///    a `.summary` indistinguishable from a genuine four-section parse. Requiring every
    ///    header makes `.summary` ITSELF the completeness signal: reaching it means every section
    ///    was genuinely found, even when a section's content is legitimately empty (the model
    ///    wrote nothing, or literally "None", between one header and the next). It is a
    ///    structural completeness check, not a content-non-emptiness check.
    /// 2. **Some line inside a list section cannot be confidently attributed** -- see
    ///    `parseList`. This is the second blocking finding's fix, and it replaces a rule that
    ///    silently stopped collecting instead.
    ///
    /// 3. **Any non-whitespace text appears BEFORE the first recognized header.** This used to be
    ///    dropped, on the argument that a preamble precedes every section so it can belong to
    ///    none of them. That argument was wrong, and it was the same mistake in new clothes: the
    ///    rule cannot tell "Sure, here's the summary:" from a model that wrote the substantive
    ///    purpose text and only then emitted `PURPOSE:`. In the second case the parse returned a
    ///    complete-looking summary with real content silently gone -- exactly the property this
    ///    file exists to hold. Refusing is the only outcome that does not depend on knowing which
    ///    of the two it was. A narrow allowlist of known boilerplate lead-ins was considered and
    ///    rejected: an allowlist is a heuristic, "usually right" is what has lost here three
    ///    times, and it would still mis-handle the case it does not recognize. The refusal cost
    ///    is paid on the INPUT side instead -- `MeetingSummaryPrompt` now states "no text before
    ///    the first header" as a rule rather than a preference.
    static func parse(_ raw: String) -> ParsedMeetingSummarySections? {
        let unfenced = stripWrappingCodeFence(raw)
        let lines = unfenced.components(separatedBy: "\n")

        var buffers: [Section: [String]] = [:]
        var current: Section?

        for line in lines {
            if let section = matchHeader(line) {
                current = section
                buffers[section] = buffers[section] ?? []
                continue
            }
            guard let current else {
                // Before the first header. Blank lines carry nothing and are ignored; anything
                // else is unattributable content, and refusing is the only reading that cannot
                // silently lose a real PURPOSE the model wrote above its own header. See (3) in
                // this function's doc comment.
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                return nil
            }
            buffers[current, default: []].append(line)
        }

        guard Section.allCases.allSatisfy({ buffers[$0] != nil }) else { return nil }

        guard let questions = parseList(buffers[.questions] ?? []),
            let conclusions = parseList(buffers[.conclusions] ?? []),
            let actionItemLines = parseList(buffers[.actionItems] ?? [])
        else {
            return nil
        }

        return ParsedMeetingSummarySections(
            purpose: parseProse(buffers[.purpose] ?? []),
            questions: questions,
            conclusions: conclusions,
            actionItems: actionItemLines.map(makeActionItem)
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

    /// Matches "None", case-insensitively, ignoring an ENUMERATED set of surrounding punctuation:
    /// the wrappers `(` `)` `[` `]` `"` `'` and the trailing marks `.` `!` `,` `;` `:`. The prompt
    /// asks for exactly "None", but a real model writing a short standalone answer punctuates it
    /// ("None.", "None!", "(None)"), and every one of those spellings means the same thing.
    ///
    /// The set is a fixed list, not a "strip anything non-alphanumeric" rule, deliberately: an
    /// open-ended strip is the kind of heuristic that has cost this file three rounds, whereas an
    /// enumerated set is exhaustively reviewable. Nothing here can turn REAL content empty --
    /// `isNone` is only ever consulted for a section whose ENTIRE content is that single token
    /// (see `parseProse` and `parseList`), so the only strings it can affect are ones that say
    /// "nothing here" in the first place. A "None" appearing ALONGSIDE real items is not a
    /// section-is-empty marker; it is an unattributable line, and is handled as one rather than
    /// quietly skipped.
    private static let noneTrailingPunctuation: Set<Character> = [".", "!", ",", ";", ":"]
    private static let noneWrappingPunctuation: Set<Character> = ["(", ")", "[", "]", "\"", "'"]

    private static func isNone(_ text: String) -> Bool {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespaces))
        while let last = trimmed.last, noneTrailingPunctuation.contains(last) { trimmed = trimmed.dropLast() }
        while let first = trimmed.first, noneWrappingPunctuation.contains(first) { trimmed = trimmed.dropFirst() }
        while let last = trimmed.last, noneWrappingPunctuation.contains(last) { trimmed = trimmed.dropLast() }
        while let last = trimmed.last, noneTrailingPunctuation.contains(last) { trimmed = trimmed.dropLast() }
        return trimmed.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("None") == .orderedSame
    }

    /// PURPOSE, the one PROSE section: every line under the header is part of the purpose, and
    /// none of it is ever dropped. Blank lines separate paragraphs and are preserved as paragraph
    /// breaks; lines within a paragraph are joined with a space, which is how a hard-wrapped
    /// paragraph reads back correctly.
    ///
    /// There is deliberately no foreign-text detection here, unlike `parseList`. A prose section
    /// has no item boundaries to be ambiguous about: a stray sentence under PURPOSE is simply
    /// part of the prose the model put under PURPOSE, and including it is both the honest reading
    /// and the only one that cannot lose real content. (The accepted consequence, since the
    /// alternative is guessing: if a model ignored the required section order and ended its
    /// response with PURPOSE, a trailing sign-off would read as part of the purpose text. It is
    /// visible there, not silently discarded, and it cannot become a fake action item.)
    private static func parseProse(_ lines: [String]) -> String {
        var paragraphs: [String] = []
        var currentParagraph: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !currentParagraph.isEmpty {
                    paragraphs.append(currentParagraph.joined(separator: " "))
                    currentParagraph = []
                }
                continue
            }
            currentParagraph.append(trimmed)
        }
        if !currentParagraph.isEmpty {
            paragraphs.append(currentParagraph.joined(separator: " "))
        }

        guard !paragraphs.isEmpty else { return "" }
        if paragraphs.count == 1, isNone(paragraphs[0]) { return "" }
        return paragraphs.joined(separator: "\n\n")
    }

    /// The three LIST sections (QUESTIONS, CONCLUSIONS, ACTION_ITEMS). Returns `nil` -- refusing
    /// the whole response -- rather than ever returning a list that is missing, truncated, or
    /// silently padded with content from one of the model's lines.
    ///
    /// Item boundaries come from exactly two unambiguous signals, and nothing else:
    ///   * A BULLET MARKER starts a new item (`-`, `*`, `•`, or `1.`/`1)`; see `bulletBody`).
    ///   * A BLANK LINE starts a new block, which in a section with no bullets starts a new item.
    ///
    /// Every non-blank line is then one of three things:
    ///   1. **Indented DEEPER than the line that opened the current item** -- a continuation of
    ///      that item, joined onto it with a space. Checked BEFORE the bullet test, so a nested
    ///      sub-bullet continues its parent instead of becoming a separate top-level item; its
    ///      marker is kept verbatim in the joined text, since the result type is flat and cannot
    ///      hold a tree. Relative depth, not "starts with whitespace": a model that indents a
    ///      whole list under its header would otherwise have every bullet folded into the first.
    ///      Indentation is the signal because it is the one a hard-wrapped continuation and a
    ///      sub-bullet both carry and a model's closing remark never does. A blank line does not
    ///      break it: an indented block below a bullet is nested under that bullet in the model's
    ///      own formatting, so attributing it there follows the model's structure rather than
    ///      guessing past it.
    ///   2. **Bulleted, at or above the current item's depth** -- a new item. Unambiguous.
    ///   3. **Un-bulleted and un-indented.** This is the ambiguous case, and it splits on whether
    ///      the section uses bullets at all:
    ///      - If the section contains NO bullet anywhere, the model wrote this section as plain
    ///        blocks rather than a bulleted list. Each blank-line-separated block is one item.
    ///        That covers both a section that is one un-bulleted sentence and a genuinely
    ///        multi-paragraph one, with nothing dropped. But a SECOND un-indented line inside the
    ///        same block is ambiguous -- a wrapped continuation of the line above, or a second
    ///        item whose bullet the model omitted -- and the two readings differ materially
    ///        (an ACTION_ITEMS block reading "Alice: send report" / "Bob: book the room" is
    ///        either two owned actions or one action absurdly attributed to Alice), so this
    ///        REFUSES rather than picking one.
    ///      - If the section DOES use bullets, the model is following the required format, and an
    ///        un-bulleted, un-indented line is foreign to it: a sign-off, a lead-in sentence, a
    ///        fifth section's header, a stray interjection between two items. There is no way to
    ///        tell those from a real item whose bullet was dropped, so this REFUSES too -- rather
    ///        than absorbing it (defeat #1: words nobody said become an action item with an
    ///        owner) or stopping collection at it (defeat #2: every real item after it silently
    ///        disappears).
    private static func parseList(_ lines: [String]) -> [String]? {
        let nonBlank = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !nonBlank.isEmpty else { return [] }
        // A section whose entire content is the single word "None" is the prompt's own
        // there-is-nothing-here answer, and is a real, honest empty list -- not a dropped line.
        if nonBlank.count == 1, isNone(nonBlank[0]) { return [] }

        let usesBullets = nonBlank.contains { bulletBody($0) != nil }

        var items: [String] = []
        /// Index of the item a continuation line attaches to, or `nil` when no item has been
        /// opened yet (the start of the section, or a bare marker that carried no text).
        var openItem: Int?
        /// The leading-whitespace width of the line that OPENED `openItem`. Continuation is
        /// decided relative to this, never against zero: a model that indents a whole list under
        /// its header writes every bullet at the same depth, and an absolute "is indented" test
        /// would fold that entire list into its first item.
        var openItemIndent = 0
        var atBlockStart = true

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                atBlockStart = true
                continue
            }

            // CONTINUATION IS CHECKED FIRST, INCLUDING FOR A BULLETED LINE. A nested bullet is
            // indented deeper than the item it sits under, and testing `bulletBody` first made it
            // open a NEW top-level item instead -- so "- Alice: Prepare launch plan" followed by
            // "  - include rollback owners" became Alice's action PLUS a second, ownerless one,
            // inventing an unattributed action item for the downstream indexer and silently
            // flattening the hierarchy the model wrote. The nested marker is kept verbatim in the
            // continuation text: `[String]`/`MeetingActionItem` cannot represent a tree, so the
            // sub-item stays visible AS a sub-item inside its parent's text rather than being
            // erased or promoted.
            if indentWidth(rawLine) > openItemIndent, let target = openItem {
                items[target] += " " + trimmed
                atBlockStart = false
                continue
            }

            if let body = bulletBody(trimmed) {
                atBlockStart = false
                guard !body.isEmpty else {
                    // A bare marker with no text carries no content to lose, but it also leaves
                    // nothing for a following indented line to continue -- so no item is opened,
                    // and such a line refuses below rather than attaching to the wrong item.
                    openItem = nil
                    continue
                }
                items.append(body)
                openItem = items.count - 1
                openItemIndent = indentWidth(rawLine)
                continue
            }

            if !usesBullets, atBlockStart {
                items.append(trimmed)
                openItem = items.count - 1
                openItemIndent = indentWidth(rawLine)
                atBlockStart = false
                continue
            }

            return nil
        }

        return items
    }

    /// The number of leading whitespace characters on the raw (untrimmed) line -- the
    /// continuation signal `parseList` keys on. Read off the raw line deliberately: every other
    /// check in this parser works on the trimmed line, and this is the one place the leading
    /// whitespace itself is the information. Counted in characters, so one tab counts as one
    /// level: mixing tabs and spaces within a single list would make depths incomparable, but a
    /// model emits one or the other consistently, and the failure mode of a mixed list is a
    /// refusal, not a silent misattribution.
    private static func indentWidth(_ rawLine: String) -> Int {
        rawLine.prefix { $0.isWhitespace }.count
    }

    /// The text after a leading list marker, or `nil` if the (already trimmed) line does not
    /// start with one.
    ///
    /// The prompt asks for `- `, so that is accepted in the loosest form the previous version of
    /// this parser accepted it (a leading `-`, space or not). `*`, `•` and `1.`/`1)` are accepted
    /// too, because a model that formats one section as `* item` should parse exactly rather than
    /// refuse -- recognizing a marker is a CONFIDENT attribution, so widening this set strictly
    /// reduces how often the ambiguous branch is reached. `*` and `•` require a following space
    /// specifically so a `**bold**` line is not mistaken for a bullet and mangled.
    private static func bulletBody(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("-") {
            return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        for marker in ["*", "•"] where trimmed.hasPrefix(marker) {
            let rest = String(trimmed.dropFirst(marker.count))
            guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
            return rest.trimmingCharacters(in: .whitespaces)
        }
        return numberedBulletBody(trimmed)
    }

    /// `1. text` / `12) text` -- the other list shape a model reaches for unprompted. Requires
    /// digits, then `.` or `)`, then whitespace, so ordinary prose starting with a number
    /// ("2026 was the year we...") is not read as a list marker.
    private static func numberedBulletBody(_ trimmed: String) -> String? {
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index].isNumber {
            index = trimmed.index(after: index)
        }
        guard index != trimmed.startIndex, index < trimmed.endIndex else { return nil }
        guard trimmed[index] == "." || trimmed[index] == ")" else { return nil }

        let afterMarker = trimmed.index(after: index)
        guard afterMarker < trimmed.endIndex, trimmed[afterMarker].isWhitespace else { return nil }
        return String(trimmed[afterMarker...]).trimmingCharacters(in: .whitespaces)
    }

    /// Splits one already-extracted action-item line into `owner` + `text` on its first colon,
    /// subject to `maxOwnerCandidateLength`. Never drops any of the line: when the split is not
    /// taken, the whole line becomes `text` with a `nil` owner.
    private static func makeActionItem(_ line: String) -> MeetingActionItem {
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

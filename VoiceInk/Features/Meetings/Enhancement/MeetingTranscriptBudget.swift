// New for this fork (Phase 3). Not a port.
//
// Turns a meeting's segments into the plain-text transcript `MeetingSummaryService` sends inside
// <TRANSCRIPT>, and decides what happens when that transcript is too big to send at all.
//
// THE POLICY, decided here rather than left implicit: character-budgeted, segment-granular,
// head+tail truncation. Chosen over the alternatives for concrete reasons:
// - Refusing outright on any long meeting would make the service useless for exactly the
//   meetings a summary is most valuable for (long ones).
// - Chunk-and-combine (summarize each chunk, then summarize the summaries) would give better
//   coverage of a very long meeting, but it multiplies the number of real LLM calls per meeting
//   (Mark's API spend) and multiplies the failure surface (a partial-chunk failure has to be
//   handled too, and combining several partial `PURPOSE`/`ACTION_ITEMS` sections back into one
//   coherent set is itself a summarization step that can misattribute or drop things). That
//   complexity is not justified for a v1 of this service; the truncation policy below fails in a
//   simple, predictable, fully-tested direction instead, and is `wasTruncated`-flagged so nothing
//   pretends to have seen the whole meeting when it did not.
// - Naive head-only or tail-only truncation would systematically lose exactly the section that
//   tends to cluster at the OTHER end of a meeting: a meeting's purpose/agenda is usually set at
//   the start, while its conclusions and agreed actions are usually reached near the end. Taking
//   only one end would make the corresponding summary section reliably empty on every long
//   meeting, not occasionally.
// - Truncating a single segment's TEXT mid-string (rather than dropping whole segments) risks
//   handing the model a sentence that stops mid-word with no signal that it was cut off, which
//   the prompt cannot warn about because the cut is invisible to it. Dropping whole segments and
//   inserting an explicit "segments omitted" marker line keeps every included line a complete,
//   real utterance and makes the gap visible in the prompt itself.
//
// STATED PLAINLY, because `wasTruncated` alone only says "something was cut," not what that
// costs: the dropped middle can contain a real decision the meeting actually reached, or an
// action item actually agreed, mid-meeting -- not just filler. Head+tail weighting (below) is
// chosen specifically because CONCLUSIONS and ACTION_ITEMS tend to land near the end, but "tend
// to" is not "always": a meeting that revisits and closes an earlier topic in its middle can lose
// exactly that closure. A truncated summary is therefore not merely "possibly incomplete" in the
// generic sense every summary already is -- it can specifically be missing a real decision, and
// `wasTruncated` is the caller's only signal that this risk exists for a given summary.
//
// Character count, not a token count, is the budget unit. This project has no tokenizer
// dependency for any provider (Gemini/Anthropic/OpenAI-compatible/Ollama/local CLI all reach
// `AIEnhancementService` through plain string requests — see that file), and adding one just for
// this budget would be new plumbing for a single call site. A rough 4-characters-per-token English
// heuristic stands in for it instead; `defaultCharacterBudget` is picked conservatively against
// that heuristic — see its own doc comment for the number.
enum MeetingTranscriptBudget {
    /// ~15,000 tokens at a 4-characters-per-token heuristic. Picked to stay safely inside the
    /// smallest context windows this app can actually be pointed at (a local Ollama or Local CLI
    /// model, which this app lets Mark configure with no minimum context-length check anywhere),
    /// while comfortably covering roughly an hour-plus of normal multi-speaker conversation
    /// before truncation kicks in at all. This is a heuristic default, not a measured per-model
    /// limit — there is no per-model context-length lookup in this codebase to consult (`grep`
    /// confirmed no `maxTokens`/`contextWindow` concept exists yet), so a fixed conservative
    /// constant is the honest choice over pretending to a precision this app cannot currently
    /// provide.
    static let defaultCharacterBudget = 60_000

    /// The fraction of the budget spent on the START of the meeting. Deliberately less than half:
    /// the tail is where conclusions and agreed actions cluster (see this type's header), and
    /// those are exactly the sections `MeetingSummaryService` is least willing to leave empty.
    static let headFraction = 0.4

    struct Result: Equatable {
        let transcript: String
        let wasTruncated: Bool
    }

    /// A meeting title is ordinary UI-authored text -- a handful of words in every real case --
    /// but nothing upstream of `MeetingSummaryService` enforces that (an imported or otherwise
    /// pathological title could be arbitrarily large). This is capped SEPARATELY from
    /// `characterBudget`/`defaultCharacterBudget` above, not folded into the segment-dropping
    /// transcript budget: a title is not a transcript segment, there is nothing to "drop from the
    /// middle" of one, and mixing the two kinds of content into one algorithm would make both
    /// harder to reason about. 200 characters is generous for any real title and exists only to
    /// bound the pathological case -- see `truncateTitle`, and `MeetingSummaryService`, which
    /// used to append the title AFTER transcript budgeting with no cap of its own at all
    /// (a review finding: the title bypassed the whole budget, and `wasTruncated` stayed `false`
    /// regardless of the title's real size).
    static let maxTitleLength = 200

    struct TitleResult: Equatable {
        let text: String
        let wasTruncated: Bool
    }

    /// Sanitizes and, only if necessary, hard-cuts `title` to `maxTitleLength`, reusing the same
    /// visible-marker `hardTruncate` the pathological-segment case below uses -- one truncation
    /// mechanism, not two. `wasTruncated` here means exactly what it means on `Result`: the
    /// caller did not see the whole of what was asked to be summarized. Sanitizing alone never
    /// sets it, because sanitizing removes no words -- see `sanitizeTitle`.
    static func truncateTitle(_ title: String) -> TitleResult {
        let sanitized = sanitizeTitle(title)
        guard sanitized.count > maxTitleLength else {
            return TitleResult(text: sanitized, wasTruncated: false)
        }
        return TitleResult(text: hardTruncate(sanitized, to: maxTitleLength), wasTruncated: true)
    }

    /// Flattens a title to a single line of ordinary text: every whitespace or control character
    /// becomes a space, runs of spaces collapse to one, and the ends are trimmed. A title that
    /// holds nothing else -- whitespace only, or control characters only -- therefore comes back
    /// empty, and `MeetingSummaryService` omits the "Meeting title:" line entirely rather than
    /// sending an empty or garbage one. That is the same standard the transcript path already
    /// applies to segment text (`MeetingSummaryService.summarize`'s `hasRealContent` check treats
    /// a whitespace-only segment as no content at all), applied to the title too instead of only
    /// to the transcript.
    ///
    /// Control characters and newlines are the point, not incidental tidying. A title is
    /// arbitrary text this service splices into the prompt directly above the transcript, so a
    /// title containing newlines could otherwise contribute extra lines that read to the model
    /// exactly like transcript content -- a fake speaker turn, or a line mimicking the
    /// "[... earlier segments omitted ...]" marker. Flattening removes that shape entirely while
    /// keeping every word the title actually contained, which is why it does not count as
    /// truncation.
    private static func sanitizeTitle(_ title: String) -> String {
        let flattened = String(
            title.map { character in
                character.unicodeScalars.allSatisfy {
                    CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                } ? " " : character
            })
        return flattened.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    private static let omittedMarker = "[... earlier segments omitted to fit the context budget ...]"

    /// `build` never returns more than this many characters, full stop, regardless of how the
    /// segment-dropping policy below plays out. It is a BACKSTOP, not the primary policy: the
    /// primary policy (drop whole segments from the middle) is what normally keeps the result
    /// near `characterBudget` while every included line stays a complete, real utterance. This
    /// exists only for the pathological case the primary policy cannot help with -- one or two
    /// single segments each individually bigger than the whole budget, where there is no middle
    /// left to drop (see `lastIndexWithinBudget`'s "always includes at least the starting line"
    /// guarantee). `characterBudget * 2` gives that guarantee generous room to do its job on
    /// ordinary transcripts without ever engaging, while still making "never silently send an
    /// unbounded prompt" true even in that pathological case, by falling back to a plain
    /// character-level cut. A mid-word cut in that fallback is an accepted, documented cost: it
    /// only ever triggers when the alternative was sending something unbounded instead.
    private static func hardCeiling(for characterBudget: Int) -> Int { characterBudget * 2 }

    /// Sorts `segments` the same way the rest of this fork's Meetings code does — by
    /// `startOffset`, breaking ties on `orderIndex` — matching `TranscriptedMarkdownExporter`'s
    /// (PR #18, not present on this branch) and `MeetingStoreTests`' fetch-order convention, so
    /// this transcript reads in the same order a human would see the meeting rendered anywhere
    /// else in this app.
    static func build(from segments: [MeetingSegment], characterBudget: Int = defaultCharacterBudget) -> Result {
        let ordered = segments.sorted { lhs, rhs in
            if lhs.startOffset != rhs.startOffset { return lhs.startOffset < rhs.startOffset }
            return lhs.orderIndex < rhs.orderIndex
        }
        let lines = ordered.map(renderLine)
        let full = lines.joined(separator: "\n")

        guard full.count > characterBudget else {
            return Result(transcript: full, wasTruncated: false)
        }

        guard lines.count > 1 else {
            // A single segment bigger than the whole budget: there is no second line to drop, so
            // the only lever left is a hard character cut. See `hardCeiling` for why this is a
            // documented last resort rather than the normal path.
            return Result(transcript: hardTruncate(full, to: hardCeiling(for: characterBudget)), wasTruncated: true)
        }

        let headBudget = Int(Double(characterBudget) * headFraction)
        let tailBudget = characterBudget - headBudget

        let headEndIndex = lastIndexWithinBudget(lines, from: 0, forward: true, budget: headBudget)
        var tailStartIndex = lastIndexWithinBudget(lines, from: lines.count - 1, forward: false, budget: tailBudget)
        // Never let the two windows overlap: each independently guarantees at least its own
        // boundary line (see `lastIndexWithinBudget`), which can otherwise let them cross when
        // both boundary lines are individually large. Clamping the tail window to start right
        // after the head window ends keeps every line counted at most once.
        if tailStartIndex <= headEndIndex {
            tailStartIndex = headEndIndex + 1
        }

        let headLines = Array(lines[0...headEndIndex])
        let tailLines = tailStartIndex < lines.count ? Array(lines[tailStartIndex...]) : []
        let omittedCount = max(0, tailStartIndex - headEndIndex - 1)

        let assembledLines = omittedCount > 0 ? headLines + [omittedMarker] + tailLines : headLines + tailLines
        let assembled = assembledLines.joined(separator: "\n")

        // Even after dropping every droppable segment, the two guaranteed boundary lines alone
        // can still exceed the budget (both individually huge). The hard ceiling backstop below
        // is a no-op on any ordinary transcript and only ever engages in that case.
        let capped = hardTruncate(assembled, to: hardCeiling(for: characterBudget))
        return Result(transcript: capped, wasTruncated: omittedCount > 0 || capped != assembled)
    }

    /// Cuts `text` to at most `limit` characters, appending a marker so the cut is visible rather
    /// than silent. A no-op when `text` already fits.
    private static func hardTruncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let marker = " …[cut to fit the context budget]"
        let keep = max(0, limit - marker.count)
        return String(text.prefix(keep)) + marker
    }

    /// Walks `lines` one whole line at a time from `from`, in the given direction, and returns
    /// the last index that keeps the cumulative character count (lines joined by "\n") within
    /// `budget`. Always includes at least the starting line, even if it alone exceeds `budget` --
    /// this function never drops every line on that end.
    private static func lastIndexWithinBudget(_ lines: [String], from: Int, forward: Bool, budget: Int) -> Int {
        var index = from
        var total = lines[from].count
        var lastGood = from

        while true {
            let next = forward ? index + 1 : index - 1
            guard next >= 0, next < lines.count else { break }
            let candidateTotal = total + 1 + lines[next].count  // +1 for the joining "\n"
            guard candidateTotal <= budget else { break }
            total = candidateTotal
            index = next
            lastGood = next
        }

        return lastGood
    }

    /// `[MM:SS] Label: text`. This is this service's own working format for the model, not
    /// Transcripted's export markup (`**MM:SS**  [Channel/Label]`, `TranscriptedMarkdownExporter`
    /// on the separate PR #18 branch) -- there is no requirement that the two match, since only
    /// the exporter's output is ever read by Mark's real Transcripted indexer.
    private static func renderLine(_ segment: MeetingSegment) -> String {
        "[\(timestamp(segment.startOffset))] \(segment.speakerLabel): \(segment.text)"
    }

    private static func timestamp(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

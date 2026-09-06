// New for this fork (Phase 3). Not a port.
//
// Pure tests against fixed strings -- no provider, no SwiftData, no async. Each test pins one
// specific parsing decision `MeetingSummaryResponseParser` makes, so a future change to that
// parser's leniency rules shows up as a failing assertion here rather than a silently different
// summary shape downstream.
//
// FIX ROUND (Blocking 3): `parse` used to return non-nil as soon as ONE recognized header was
// seen, with the other three silently defaulting to empty -- a `.summary` outcome
// indistinguishable from a genuine four-section parse. It now requires ALL FOUR headers, so
// several tests below that used to get away with two or three headers now carry all four
// (usually with trivial "None" bodies on the ones not under test) purely to stay past that gate
// while still isolating the ONE leniency rule each test exists to pin. `exactlyOneHeaderIs
// Unparseable` and `twoHeadersAreUnparseable` (replacing the old, now-wrong `partialHeadersStill
// Parse`) test the gate itself.
//
// ESCALATED ROUND: that same fix ALSO introduced "stop collecting at the second un-bulleted
// line", and TWO tests here blessed what that silently discarded --
// `secondUnbulletedLineEndsCollection` and `trailingProseAfterLastHeaderIsDropped`. Both are
// replaced (by `adjacentUnbulletedLinesRefuse` and `trailingProseAfterLastHeaderRefuses`), for
// the reason recorded at each one: a rule that drops an unattributable line is indistinguishable
// from one that drops a real one, and either way it returns a result that presents itself as
// complete. Every test added in this round asserts the FULL expected content of a section, or an
// outright refusal -- never merely that parsing succeeded.

import Testing

@testable import VoiceInk

@Suite("MeetingSummaryResponseParser")
struct MeetingSummaryResponseParserTests {
    @Test("well-formed response parses every section")
    func wellFormedResponse() {
        let raw = """
            PURPOSE:
            Discuss Q3 roadmap priorities and align on staffing.

            QUESTIONS:
            - Do we have budget for the extra hire?
            - Is the Q2 deadline still realistic?

            CONCLUSIONS:
            - We will prioritize the migration over new features.

            ACTION_ITEMS:
            - Alice: Draft the staffing proposal.
            - Follow up with finance about budget.
            """

        let parsed = MeetingSummaryResponseParser.parse(raw)
        let result = try! #require(parsed)

        #expect(result.purpose == "Discuss Q3 roadmap priorities and align on staffing.")
        #expect(result.questions == [
            "Do we have budget for the extra hire?",
            "Is the Q2 deadline still realistic?",
        ])
        #expect(result.conclusions == ["We will prioritize the migration over new features."])
        #expect(
            result.actionItems == [
                MeetingActionItem(owner: "Alice", text: "Draft the staffing proposal."),
                MeetingActionItem(owner: nil, text: "Follow up with finance about budget."),
            ])
    }

    @Test("a response with no recognized header at all is unparseable")
    func noHeaderIsUnparseable() {
        let raw = "Sure! Here's a summary of the meeting: it went well and everyone agreed."
        #expect(MeetingSummaryResponseParser.parse(raw) == nil)
    }

    @Test("exactly one recognized header is unparseable, not a one-section summary")
    func exactlyOneHeaderIsUnparseable() {
        let raw = """
            PURPOSE:
            Weekly status check-in.
            """
        #expect(MeetingSummaryResponseParser.parse(raw) == nil)
    }

    @Test("two of four recognized headers is unparseable, not a two-section summary")
    func twoHeadersAreUnparseable() {
        let raw = """
            PURPOSE:
            Weekly status check-in.

            ACTION_ITEMS:
            - Bob: Send the report.
            """
        #expect(MeetingSummaryResponseParser.parse(raw) == nil)
    }

    @Test("all four headers present but genuinely empty bodies parse as real, honest empty sections")
    func allHeadersPresentWithEmptyBodiesParse() {
        let raw = """
            PURPOSE:

            QUESTIONS:

            CONCLUSIONS:

            ACTION_ITEMS:
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(result.purpose.isEmpty)
        #expect(result.questions.isEmpty)
        #expect(result.conclusions.isEmpty)
        #expect(result.actionItems.isEmpty)
    }

    @Test("'None' sections come back empty, not fabricated")
    func noneSectionsComeBackEmpty() {
        let raw = """
            PURPOSE:
            None.

            QUESTIONS:
            None

            CONCLUSIONS:
            None

            ACTION_ITEMS:
            None
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(result.purpose.isEmpty)
        #expect(result.questions.isEmpty)
        #expect(result.conclusions.isEmpty)
        #expect(result.actionItems.isEmpty)
    }

    // CHANGED IN THE ESCALATED ROUND, from `trailingProseAfterLastHeaderIsDropped`, which asserted
    // that this response parses and quietly loses its last line. That assertion blessed a silent
    // drop: this exact shape -- an un-bulleted, un-indented line after a real item -- is what a
    // genuine final action item looks like when the model omits its bullet, and the old rule
    // discarded it while still returning a complete-looking `.summary`. Nothing here can tell a
    // sign-off from a real item, so the response is refused whole instead.
    @Test("free-text trailing after the last section refuses the whole response, rather than being dropped or absorbed")
    func trailingProseAfterLastHeaderRefuses() {
        let raw = """
            PURPOSE:
            Weekly status check-in.

            QUESTIONS:
            None

            CONCLUSIONS:
            None

            ACTION_ITEMS:
            - Alice: Ship the report.

            Let me know if you have any other questions!
            """
        #expect(MeetingSummaryResponseParser.parse(raw) == nil)
    }

    @Test("header casing is not required to match exactly")
    func headerCasingIsLenient() {
        let raw = """
            purpose:
            Catch-up call.

            questions:
            - Anything blocking?

            conclusions:
            None

            action_items:
            None
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(result.purpose == "Catch-up call.")
        #expect(result.questions == ["Anything blocking?"])
    }

    @Test("a single wrapping code fence around the whole response is stripped")
    func wrappingCodeFenceIsStripped() {
        let raw = """
            ```text
            PURPOSE:
            Design review.

            QUESTIONS:
            None

            CONCLUSIONS:
            None

            ACTION_ITEMS:
            None
            ```
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(result.purpose == "Design review.")
    }

    @Test("blank lines inside a list section are ignored, not treated as items")
    func blankLinesInListsAreIgnored() {
        let raw = """
            PURPOSE:
            None

            QUESTIONS:
            - First question?

            - Second question?

            CONCLUSIONS:
            None

            ACTION_ITEMS:
            None
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(result.questions == ["First question?", "Second question?"])
    }

    @Test("a missing leading '-' bullet is still accepted as a list item")
    func missingBulletIsStillAccepted() {
        let raw = """
            PURPOSE:
            None

            QUESTIONS:
            None

            CONCLUSIONS:
            We will ship on Friday.

            ACTION_ITEMS:
            None
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(result.conclusions == ["We will ship on Friday."])
    }

    // CHANGED IN THE ESCALATED ROUND, from `secondUnbulletedLineEndsCollection`, which asserted
    // `conclusions == ["We will ship on Friday."]` -- i.e. it explicitly blessed silently
    // discarding "That's the final decision." while still returning a `.summary` that reads as
    // complete. Two adjacent un-bulleted, un-indented lines are genuinely ambiguous (one wrapped
    // conclusion, or two conclusions the model failed to bullet), and the two readings differ in
    // substance, so the parser now refuses instead of picking one and hiding the other.
    @Test("two adjacent un-bulleted lines in one block are ambiguous, so the response is refused, not silently shortened")
    func adjacentUnbulletedLinesRefuse() {
        let raw = """
            PURPOSE:
            None

            QUESTIONS:
            None

            CONCLUSIONS:
            We will ship on Friday.
            That's the final decision.

            ACTION_ITEMS:
            None
            """
        #expect(MeetingSummaryResponseParser.parse(raw) == nil)
    }

    @Test("two un-bulleted action items are refused rather than merged into one owner's action")
    func adjacentUnbulletedActionItemsRefuse() {
        // The concrete harm this refusal exists to prevent: joined into one item, this reads as
        // Alice owning both actions, and Bob's agreed action is gone from a summary that presents
        // itself as complete. Split into two, it reads as two owned actions. Nothing in the text
        // says which the model meant.
        let raw = """
            PURPOSE:
            Launch prep.

            QUESTIONS:
            None

            CONCLUSIONS:
            None

            ACTION_ITEMS:
            Alice: Draft the staffing proposal.
            Bob: Book the review room.
            """
        #expect(MeetingSummaryResponseParser.parse(raw) == nil)
    }

    @Test("a stray un-bulleted line in the MIDDLE of a bulleted list refuses, so no later item is lost")
    func strayLineInsideBulletedListRefuses() {
        // The old rule stopped collecting at the stray line, which silently discarded the SECOND
        // question entirely -- a complete-looking summary missing a real question. Refusing is the
        // only outcome that neither invents an item out of the stray line nor hides the one after
        // it.
        let raw = """
            PURPOSE:
            Weekly status check-in.

            QUESTIONS:
            - Do we have budget for the extra hire?
            Some stray note that nobody asked as a question.
            - Is the Q2 deadline still realistic?

            CONCLUSIONS:
            None

            ACTION_ITEMS:
            None
            """
        #expect(MeetingSummaryResponseParser.parse(raw) == nil)
    }

    @Test("a multi-paragraph CONCLUSIONS section keeps every paragraph as its own conclusion")
    func multiParagraphConclusionsAreFullyPreserved() {
        // A section the model wrote as prose blocks rather than bullets. Blank lines are the only
        // item boundary it gave, and they are unambiguous, so both paragraphs survive. The old
        // rule kept the first and silently dropped the second.
        let raw = """
            PURPOSE:
            Quarterly planning.

            QUESTIONS:
            None

            CONCLUSIONS:
            We will prioritize the migration over new features.

            The phased rollout stays as planned, starting with the internal cohort.

            ACTION_ITEMS:
            None
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(
            result.conclusions == [
                "We will prioritize the migration over new features.",
                "The phased rollout stays as planned, starting with the internal cohort.",
            ])
        #expect(result.purpose == "Quarterly planning.")
        #expect(result.questions.isEmpty)
        #expect(result.actionItems.isEmpty)
    }

    @Test("a multi-paragraph PURPOSE keeps both paragraphs, with the paragraph break intact")
    func multiParagraphPurposeIsFullyPreserved() {
        // PURPOSE is the one prose section: everything under it is the purpose, paragraphs and
        // all. The old rule flattened every line into one space-joined run, losing the structure
        // the model wrote even though it kept the words.
        let raw = """
            PURPOSE:
            Quarterly planning for the migration workstream.

            The team also used the slot to close out last quarter's open risks.

            QUESTIONS:
            None

            CONCLUSIONS:
            None

            ACTION_ITEMS:
            None
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(
            result.purpose == """
                Quarterly planning for the migration workstream.

                The team also used the slot to close out last quarter's open risks.
                """
        )
    }

    @Test("an indented wrapped continuation is joined onto its bullet, and later bullets still parse")
    func wrappedBulletContinuationIsJoined() {
        // The case the old rule was worst on: it stopped at the continuation line, so the item was
        // truncated mid-sentence AND every bullet after it vanished.
        let raw = """
            PURPOSE:
            None

            QUESTIONS:
            None

            CONCLUSIONS:
            - We will prioritize the migration over new features
              for the whole of Q3, including the mobile client.
            - The rollout stays phased.

            ACTION_ITEMS:
            - Alice: Draft the runbook
              and circulate it before Friday.
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(
            result.conclusions == [
                "We will prioritize the migration over new features for the whole of Q3, including the mobile client.",
                "The rollout stays phased.",
            ])
        #expect(
            result.actionItems == [
                MeetingActionItem(owner: "Alice", text: "Draft the runbook and circulate it before Friday.")
            ])
    }

    @Test("an indented block below a bullet, after a blank line, continues that bullet rather than being lost")
    func indentedBlockAfterBlankLineContinuesItsBullet() {
        let raw = """
            PURPOSE:
            None

            QUESTIONS:
            None

            CONCLUSIONS:
            - We will ship on Friday.

              The vote was unanimous.

            ACTION_ITEMS:
            None
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(result.conclusions == ["We will ship on Friday. The vote was unanimous."])
    }

    @Test("bullet markers the prompt did not ask for are still recognized, so nothing is refused over formatting alone")
    func alternativeBulletMarkersAreRecognized() {
        let raw = """
            PURPOSE:
            None

            QUESTIONS:
            * Do we have budget for the extra hire?
            * Is the Q2 deadline still realistic?

            CONCLUSIONS:
            1. We will ship on Friday.
            2. The schema freezes on Monday.

            ACTION_ITEMS:
            • Alice: Send the notes.
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(
            result.questions == [
                "Do we have budget for the extra hire?",
                "Is the Q2 deadline still realistic?",
            ])
        #expect(result.conclusions == ["We will ship on Friday.", "The schema freezes on Monday."])
        #expect(result.actionItems == [MeetingActionItem(owner: "Alice", text: "Send the notes.")])
    }

    @Test("a preamble before the first header is dropped by rule, and every section still parses in full")
    func preambleBeforeFirstHeaderIsDropped() {
        // The one thing dropped without refusing, and deliberately: text before the first header
        // precedes every section, so it belongs to none of them -- a confident attribution, not a
        // guess between two readings of the same line.
        let raw = """
            Sure! Here's the summary you asked for:

            PURPOSE:
            Weekly status check-in.

            QUESTIONS:
            - Is the Q2 deadline still realistic?

            CONCLUSIONS:
            - We will ship on Friday.

            ACTION_ITEMS:
            - Alice: Send the notes.
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(result.purpose == "Weekly status check-in.")
        #expect(result.questions == ["Is the Q2 deadline still realistic?"])
        #expect(result.conclusions == ["We will ship on Friday."])
        #expect(result.actionItems == [MeetingActionItem(owner: "Alice", text: "Send the notes.")])
    }

    @Test("a lead-in sentence above a bulleted list refuses rather than becoming a fabricated item")
    func leadInSentenceAboveBulletsRefuses() {
        let raw = """
            PURPOSE:
            Weekly status check-in.

            QUESTIONS:
            None

            CONCLUSIONS:
            Here is what we decided:
            - We will ship on Friday.

            ACTION_ITEMS:
            None
            """
        #expect(MeetingSummaryResponseParser.parse(raw) == nil)
    }

    @Test("all four sections clean, with several items each, parse to exactly their content: the negative control")
    func fullyCleanResponseParsesEverySectionExactly() {
        let raw = """
            PURPOSE:
            Weekly sync on the migration project, and to agree who owns the launch checklist.

            QUESTIONS:
            - Do we have budget for the extra hire?
            - Is the Q2 deadline still realistic?

            CONCLUSIONS:
            - We will prioritize the migration over new features.
            - The rollout stays phased.

            ACTION_ITEMS:
            - Alice: Draft the staffing proposal.
            - Bob: Book the review room.
            - Circulate the meeting notes.
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(result.purpose == "Weekly sync on the migration project, and to agree who owns the launch checklist.")
        #expect(
            result.questions == [
                "Do we have budget for the extra hire?",
                "Is the Q2 deadline still realistic?",
            ])
        #expect(
            result.conclusions == [
                "We will prioritize the migration over new features.",
                "The rollout stays phased.",
            ])
        #expect(
            result.actionItems == [
                MeetingActionItem(owner: "Alice", text: "Draft the staffing proposal."),
                MeetingActionItem(owner: "Bob", text: "Book the review room."),
                MeetingActionItem(owner: nil, text: "Circulate the meeting notes."),
            ])
    }

    @Test("a colon inside the action text, not after a short owner name, is not misread as an owner")
    func longClauseBeforeColonIsNotAnOwner() {
        let raw = """
            PURPOSE:
            None

            QUESTIONS:
            None

            CONCLUSIONS:
            None

            ACTION_ITEMS:
            - Review the deployment checklist before the release freeze on Friday: confirm every box is signed off.
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(result.actionItems.count == 1)
        #expect(result.actionItems[0].owner == nil)
        #expect(
            result.actionItems[0].text
                == "Review the deployment checklist before the release freeze on Friday: confirm every box is signed off."
        )
    }

    @Test("MeetingActionItem.formatted joins owner and text with 'Owner: text'")
    func actionItemFormattedShape() {
        #expect(MeetingActionItem(owner: "Alice", text: "Ship it").formatted == "Alice: Ship it")
        #expect(MeetingActionItem(owner: nil, text: "Ship it").formatted == "Ship it")
    }
}

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

    @Test("free-text prose trailing after the last recognized header's real content is dropped, not absorbed as an item")
    func trailingProseAfterLastHeaderIsDropped() {
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
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(result.actionItems == [MeetingActionItem(owner: "Alice", text: "Ship the report.")])
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

    @Test("a second, later un-bulleted line in a list section ends collection rather than being absorbed as another item")
    func secondUnbulletedLineEndsCollection() {
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
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        // Only the first (leniently un-bulleted) line is kept; the second un-bulleted line is
        // free-text noise, not a second missing-bullet item, so collection stops before it.
        #expect(result.conclusions == ["We will ship on Friday."])
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

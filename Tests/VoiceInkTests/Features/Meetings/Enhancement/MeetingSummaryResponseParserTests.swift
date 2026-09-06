// New for this fork (Phase 3). Not a port.
//
// Pure tests against fixed strings -- no provider, no SwiftData, no async. Each test pins one
// specific parsing decision `MeetingSummaryResponseParser` makes, so a future change to that
// parser's leniency rules shows up as a failing assertion here rather than a silently different
// summary shape downstream.

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

    @Test("a response missing some headers still parses -- the missing sections are empty")
    func partialHeadersStillParse() {
        let raw = """
            PURPOSE:
            Weekly status check-in.

            ACTION_ITEMS:
            - Bob: Send the report.
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(result.purpose == "Weekly status check-in.")
        #expect(result.questions.isEmpty)
        #expect(result.conclusions.isEmpty)
        #expect(result.actionItems == [MeetingActionItem(owner: "Bob", text: "Send the report.")])
    }

    @Test("header casing is not required to match exactly")
    func headerCasingIsLenient() {
        let raw = """
            purpose:
            Catch-up call.

            questions:
            - Anything blocking?
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
            QUESTIONS:
            - First question?

            - Second question?
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(result.questions == ["First question?", "Second question?"])
    }

    @Test("a missing leading '-' bullet is still accepted as a list item")
    func missingBulletIsStillAccepted() {
        let raw = """
            CONCLUSIONS:
            We will ship on Friday.
            """
        let result = try! #require(MeetingSummaryResponseParser.parse(raw))
        #expect(result.conclusions == ["We will ship on Friday."])
    }

    @Test("a colon inside the action text, not after a short owner name, is not misread as an owner")
    func longClauseBeforeColonIsNotAnOwner() {
        let raw = """
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

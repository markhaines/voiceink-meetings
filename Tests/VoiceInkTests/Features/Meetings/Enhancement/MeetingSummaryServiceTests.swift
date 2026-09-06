// New for this fork (Phase 3). Not a port.
//
// Exercises `MeetingSummaryService` end to end against `FakeMeetingEnhancementProvider` -- a
// stand-in for `AIEnhancementService` that never makes a network call, an API request, or spends
// any of Mark's provider credits. NO test in this file, or anywhere else in this repo, may
// construct a real `AIEnhancementService` and call a real provider; see
// `RealMeetingSummaryGateSmokeTests.swift` for the one place that does that, gated the same way
// `RealModelSmokeTests.swift` gates its own real-model calls.

import Foundation
import SwiftData
import Testing

@testable import VoiceInk

private final class FakeMeetingEnhancementProvider: MeetingEnhancementProviding {
    enum Behavior {
        case success(String)
        case failure(Error)
        case cancellation
    }

    private var behavior: Behavior
    private(set) var receivedTexts: [String] = []
    private(set) var receivedConfigurations: [EnhancementRuntimeConfiguration] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    var callCount: Int { receivedTexts.count }

    func enhance(
        _ text: String,
        configuration: EnhancementRuntimeConfiguration,
        contextSnapshot: RecordingContextSnapshot?
    ) async throws -> AIEnhancementResult {
        receivedTexts.append(text)
        receivedConfigurations.append(configuration)

        switch behavior {
        case .success(let responseText):
            return AIEnhancementResult(
                text: responseText, duration: 0, promptName: nil, systemMessage: nil, userMessage: nil)
        case .failure(let error):
            throw error
        case .cancellation:
            throw CancellationError()
        }
    }
}

private struct FakeProviderFailure: Error, LocalizedError {
    var errorDescription: String? { "The AI provider's server encountered an error. Please try again later." }
}

private let wellFormedResponse = """
    PURPOSE:
    Weekly sync on the migration project.

    QUESTIONS:
    - Is the new schema backwards compatible?

    CONCLUSIONS:
    - We will proceed with the phased rollout.

    ACTION_ITEMS:
    - Alice: Write the rollout runbook.
    - Circulate the meeting notes.
    """

@Suite("MeetingSummaryService")
struct MeetingSummaryServiceTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Meeting.self, MeetingSegment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func makeMeeting(title: String = "Sync", in context: ModelContext) -> Meeting {
        let meeting = Meeting(title: title, audioDirectoryPath: "/tmp/meeting")
        context.insert(meeting)
        return meeting
    }

    private func makeSegment(
        start: TimeInterval, speaker: String, text: String, channel: MeetingSegmentChannel = .system,
        order: Int = 0, meeting: Meeting, in context: ModelContext
    ) -> MeetingSegment {
        let segment = MeetingSegment(
            startOffset: start, endOffset: start + 1, speakerLabel: speaker, text: text,
            sourceChannel: channel, orderIndex: order, meeting: meeting)
        context.insert(segment)
        meeting.segments.append(segment)
        return segment
    }

    private let anthropicConfiguration = MeetingSummaryProviderConfiguration(provider: .anthropic, modelName: "claude")

    @Test("an empty meeting is reported as empty without ever calling the provider")
    func emptyMeetingNeverCallsProvider() async throws {
        let context = try makeContext()
        let meeting = makeMeeting(in: context)
        let provider = FakeMeetingEnhancementProvider(behavior: .success(wellFormedResponse))
        let service = MeetingSummaryService(enhancementProvider: provider)

        let outcome = try await service.summarize(meeting: meeting, segments: [], configuration: anthropicConfiguration)

        #expect(outcome == .empty)
        #expect(provider.callCount == 0)
    }

    @Test("a meeting whose segments are all blank is also reported as empty")
    func blankOnlyMeetingIsEmpty() async throws {
        let context = try makeContext()
        let meeting = makeMeeting(in: context)
        let segments = [
            makeSegment(start: 0, speaker: "You", text: "   ", meeting: meeting, in: context),
            makeSegment(start: 1, speaker: "You", text: "", meeting: meeting, in: context),
        ]
        let provider = FakeMeetingEnhancementProvider(behavior: .success(wellFormedResponse))
        let service = MeetingSummaryService(enhancementProvider: provider)

        let outcome = try await service.summarize(
            meeting: meeting, segments: segments, configuration: anthropicConfiguration)

        #expect(outcome == .empty)
        #expect(provider.callCount == 0)
    }

    @Test("a meeting with only mic-side (your own) speech still summarizes normally")
    func onlyMicSpeechStillSummarizes() async throws {
        let context = try makeContext()
        let meeting = makeMeeting(in: context)
        let segments = [
            makeSegment(start: 0, speaker: "You", text: "Reminder to self: renew the domain.", channel: .mic, meeting: meeting, in: context)
        ]
        let provider = FakeMeetingEnhancementProvider(behavior: .success(wellFormedResponse))
        let service = MeetingSummaryService(enhancementProvider: provider)

        let outcome = try await service.summarize(
            meeting: meeting, segments: segments, configuration: anthropicConfiguration)

        guard case .summary(let summary) = outcome else {
            Issue.record("expected .summary, got \(outcome)")
            return
        }
        #expect(summary.participants == ["You"])
        #expect(provider.callCount == 1)
    }

    @Test("voiceInkRefine is refused before any provider call: it ignores the summary prompt entirely")
    func voiceInkRefineIsRefused() async throws {
        let context = try makeContext()
        let meeting = makeMeeting(in: context)
        let segments = [makeSegment(start: 0, speaker: "You", text: "Hello.", meeting: meeting, in: context)]
        let provider = FakeMeetingEnhancementProvider(behavior: .success(wellFormedResponse))
        let service = MeetingSummaryService(enhancementProvider: provider)
        let configuration = MeetingSummaryProviderConfiguration(provider: .voiceInkRefine)

        let outcome = try await service.summarize(meeting: meeting, segments: segments, configuration: configuration)

        #expect(outcome == .unsupportedProvider)
        #expect(provider.callCount == 0)
    }

    @Test("a well-formed provider response produces a full, correctly structured summary")
    func wellFormedResponseProducesFullSummary() async throws {
        let context = try makeContext()
        let meeting = makeMeeting(title: "Migration Sync", in: context)
        let segments = [
            makeSegment(start: 0, speaker: "You", text: "Let's discuss the migration.", channel: .mic, meeting: meeting, in: context),
            makeSegment(start: 5, speaker: "Speaker 1", text: "Sounds good, is the schema ready?", meeting: meeting, in: context),
        ]
        let provider = FakeMeetingEnhancementProvider(behavior: .success(wellFormedResponse))
        let service = MeetingSummaryService(enhancementProvider: provider)

        let outcome = try await service.summarize(
            meeting: meeting, segments: segments, configuration: anthropicConfiguration)

        guard case .summary(let summary) = outcome else {
            Issue.record("expected .summary, got \(outcome)")
            return
        }
        #expect(summary.purpose == "Weekly sync on the migration project.")
        #expect(summary.questions == ["Is the new schema backwards compatible?"])
        #expect(summary.conclusions == ["We will proceed with the phased rollout."])
        #expect(
            summary.actionItems == [
                MeetingActionItem(owner: "Alice", text: "Write the rollout runbook."),
                MeetingActionItem(owner: nil, text: "Circulate the meeting notes."),
            ])
        #expect(summary.participants == ["You", "Speaker 1"])
        #expect(summary.wasTruncated == false)

        // The meeting's title is passed through as grounding context, and the configuration
        // handed to the provider carries this service's own prompt rather than the caller's.
        #expect(provider.receivedTexts.first?.contains("Migration Sync") == true)
        #expect(provider.receivedConfigurations.first?.prompt?.useSystemInstructions == false)
    }

    @Test("a provider failure is reported with its description, never as a fabricated summary")
    func providerFailureIsReported() async throws {
        let context = try makeContext()
        let meeting = makeMeeting(in: context)
        let segments = [makeSegment(start: 0, speaker: "You", text: "Hello.", meeting: meeting, in: context)]
        let provider = FakeMeetingEnhancementProvider(behavior: .failure(FakeProviderFailure()))
        let service = MeetingSummaryService(enhancementProvider: provider)

        let outcome = try await service.summarize(
            meeting: meeting, segments: segments, configuration: anthropicConfiguration)

        #expect(
            outcome
                == .providerFailure(
                    description: "The AI provider's server encountered an error. Please try again later."))
    }

    @Test("an unparseable provider response is reported, not silently accepted as a summary")
    func unparseableResponseIsReported() async throws {
        let context = try makeContext()
        let meeting = makeMeeting(in: context)
        let segments = [makeSegment(start: 0, speaker: "You", text: "Hello.", meeting: meeting, in: context)]
        let garbage = "Sure! It was a great meeting, everyone seemed happy."
        let provider = FakeMeetingEnhancementProvider(behavior: .success(garbage))
        let service = MeetingSummaryService(enhancementProvider: provider)

        let outcome = try await service.summarize(
            meeting: meeting, segments: segments, configuration: anthropicConfiguration)

        #expect(outcome == .unparseable(rawText: garbage))
    }

    @Test("cancellation propagates as CancellationError, never as a providerFailure outcome")
    func cancellationPropagates() async throws {
        let context = try makeContext()
        let meeting = makeMeeting(in: context)
        let segments = [makeSegment(start: 0, speaker: "You", text: "Hello.", meeting: meeting, in: context)]
        let provider = FakeMeetingEnhancementProvider(behavior: .cancellation)
        let service = MeetingSummaryService(enhancementProvider: provider)

        await #expect(throws: CancellationError.self) {
            try await service.summarize(meeting: meeting, segments: segments, configuration: anthropicConfiguration)
        }
    }

    @Test("a very long meeting is truncated before it reaches the provider, and the summary says so")
    func longMeetingIsTruncatedBeforeReachingTheProvider() async throws {
        let context = try makeContext()
        let meeting = makeMeeting(in: context)
        // Comfortably over `MeetingTranscriptBudget.defaultCharacterBudget` (60,000): 1,000
        // segments at roughly 140 characters rendered each is ~140,000 characters raw.
        let segments = (0..<1_000).map { index in
            makeSegment(
                start: TimeInterval(index), speaker: "Speaker 1",
                text: "This is line number \(index) of a very long meeting transcript that keeps going for a while.",
                meeting: meeting, in: context)
        }
        let provider = FakeMeetingEnhancementProvider(behavior: .success(wellFormedResponse))
        let service = MeetingSummaryService(enhancementProvider: provider)

        let outcome = try await service.summarize(
            meeting: meeting, segments: segments, configuration: anthropicConfiguration)

        guard case .summary(let summary) = outcome else {
            Issue.record("expected .summary, got \(outcome)")
            return
        }
        #expect(summary.wasTruncated == true)
        let sentText = try #require(provider.receivedTexts.first)
        #expect(sentText.contains("segments omitted"))
        #expect(sentText.count <= MeetingTranscriptBudget.defaultCharacterBudget * 2)
    }
}

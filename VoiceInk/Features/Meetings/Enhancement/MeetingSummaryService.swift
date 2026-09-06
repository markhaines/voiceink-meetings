// New for this fork (Phase 3). Not a port.
//
// Turns a finished meeting's segments into a `MeetingSummaryOutcome`, reusing the app's existing
// `AIEnhancementService` for the actual model call rather than adding a second provider stack.
// Everything specific to meeting summarization -- the prompt (`MeetingSummaryPrompt`), the
// context-budget policy (`MeetingTranscriptBudget`), and the response parsing
// (`MeetingSummaryResponseParser`) -- lives beside this file; this file is only the seam that
// wires those together against the real enhancement call.
//
// `MeetingEnhancementProviding` exists so this service (and its tests) never depend on the
// concrete `AIEnhancementService` class -- which needs a live `ModelContext` and a real/mocked
// `AIService` to even construct, and is `@MainActor`-isolated for AppKit/UserDefaults reasons
// that have nothing to do with summarization. `AIEnhancementService.enhance(_:configuration:
// contextSnapshot:)` ALREADY has exactly this signature, so the conformance below adds no code
// to that class -- it is declared entirely in this new file, in this fork-owned tree, and
// touches nothing upstream. Tests substitute a fake conforming to the same protocol; see
// `Tests/VoiceInkTests/Features/Meetings/Enhancement/MeetingSummaryServiceTests.swift`.
protocol MeetingEnhancementProviding {
    func enhance(
        _ text: String,
        configuration: EnhancementRuntimeConfiguration,
        contextSnapshot: RecordingContextSnapshot?
    ) async throws -> AIEnhancementResult
}

extension AIEnhancementService: MeetingEnhancementProviding {}

/// Which real provider/model to run the summary through. Deliberately just these two fields,
/// not a whole `EnhancementRuntimeConfiguration` -- this service builds its own configuration
/// (see `summarize` below) with its own prompt and with every context-capture flag
/// (`useClipboardContext`, `useSelectedTextContext`, `useScreenCaptureContext`) forced `false`,
/// because none of "selected text", "clipboard", or "the active window" are meaningful concepts
/// for a finished meeting. Accepting a caller-supplied `provider`/`modelName` rather than
/// resolving one itself (e.g. via `ModeRuntimeResolver.currentEnhancementConfiguration`, the
/// existing dictation-mode path) is deliberate too: which provider a meeting summary should run
/// through -- reuse the user's current dictation-enhancement provider, or a dedicated setting of
/// its own -- is a wiring decision, and wiring this service into anything (`MeetingEngine`, a
/// composition root, a settings UI) is explicitly out of scope for this task.
struct MeetingSummaryProviderConfiguration {
    let provider: AIProvider
    let modelName: String?

    init(provider: AIProvider, modelName: String? = nil) {
        self.provider = provider
        self.modelName = modelName
    }
}

final class MeetingSummaryService {
    private let enhancementProvider: MeetingEnhancementProviding

    init(enhancementProvider: MeetingEnhancementProviding) {
        self.enhancementProvider = enhancementProvider
    }

    /// Produces a structured summary of `meeting`/`segments`, or a specific, honest reason it
    /// could not.
    ///
    /// The only thing this function ever throws is `CancellationError`, propagated from the
    /// underlying `enhance` call if the calling `Task` is cancelled mid-request -- structured
    /// concurrency's own cancellation signal, which callers need to be able to observe as a
    /// thrown error rather than a value. Every OTHER failure mode (no provider configured, the
    /// provider erroring, an unparseable response) is a `MeetingSummaryOutcome` case, never a
    /// thrown error, precisely so a caller cannot forget to handle one by only catching errors.
    func summarize(
        meeting: Meeting,
        segments: [MeetingSegment],
        configuration: MeetingSummaryProviderConfiguration
    ) async throws -> MeetingSummaryOutcome {
        let hasRealContent = segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard hasRealContent else {
            // No provider call: there is nothing here for a model to summarize except by
            // inventing content, and this service never fabricates. See `MeetingSummaryOutcome
            // .empty`'s doc comment.
            return .empty
        }

        guard configuration.provider != .voiceInkRefine else {
            return .unsupportedProvider
        }

        let participants = orderedUniqueParticipants(segments)
        let budgetResult = MeetingTranscriptBudget.build(from: segments)
        let runtimeConfiguration = EnhancementRuntimeConfiguration(
            mode: nil,
            isEnabled: true,
            prompt: CustomPrompt(
                title: "Meeting Summary",
                promptText: MeetingSummaryPrompt.systemMessage,
                useSystemInstructions: false
            ),
            provider: configuration.provider,
            modelName: configuration.modelName,
            useClipboardContext: false,
            useSelectedTextContext: false,
            useScreenCaptureContext: false
        )

        // The meeting's own title is cheap, always-available grounding for `PURPOSE` (e.g. a
        // title of "Sprint Planning" is a strong hint even before reading a word of transcript).
        // Capped independently of the transcript budget via `MeetingTranscriptBudget
        // .truncateTitle` -- a real title is a handful of characters, but nothing enforces that
        // upstream, so an imported or pathological title is bounded too rather than appended
        // verbatim and unbounded (a review finding: it used to bypass the whole budget with
        // `wasTruncated` staying `false` regardless of the title's actual size).
        let titleResult = MeetingTranscriptBudget.truncateTitle(meeting.title)
        let promptText = titleResult.text.isEmpty
            ? budgetResult.transcript
            : "Meeting title: \(titleResult.text)\n\n\(budgetResult.transcript)"

        let result: AIEnhancementResult
        do {
            result = try await enhancementProvider.enhance(
                promptText,
                configuration: runtimeConfiguration,
                contextSnapshot: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .providerFailure(description: EnhancementFailureFormatter.description(for: error))
        }

        guard let parsed = MeetingSummaryResponseParser.parse(result.text) else {
            return .unparseable(rawText: result.text)
        }

        return .summary(
            MeetingSummary(
                purpose: parsed.purpose,
                questions: parsed.questions,
                conclusions: parsed.conclusions,
                actionItems: parsed.actionItems,
                participants: participants,
                wasTruncated: budgetResult.wasTruncated || titleResult.wasTruncated
            )
        )
    }

    /// Distinct `speakerLabel`s across every segment, in first-appearance order, sorted by the
    /// meeting's own timeline (`startOffset`, then `orderIndex` -- the same tie-break
    /// `MeetingTranscriptBudget` and `TranscriptedMarkdownExporter` use). Computed from the
    /// segments directly rather than asked of the model -- see `MeetingSummaryPrompt`'s header
    /// comment for why participants are exactly the one field this service already knows for
    /// certain and therefore never delegates to the LLM.
    private func orderedUniqueParticipants(_ segments: [MeetingSegment]) -> [String] {
        let ordered = segments.sorted { lhs, rhs in
            if lhs.startOffset != rhs.startOffset { return lhs.startOffset < rhs.startOffset }
            return lhs.orderIndex < rhs.orderIndex
        }
        var seen = Set<String>()
        var result: [String] = []
        for label in ordered.map(\.speakerLabel) where seen.insert(label).inserted {
            result.append(label)
        }
        return result
    }
}

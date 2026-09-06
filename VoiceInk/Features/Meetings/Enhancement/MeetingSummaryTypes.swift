// New for this fork (Phase 3). Not a port.
//
// The public result types `MeetingSummaryService` produces. Deliberately NOT the same shape as
// `Meeting.actionItems: [String]` / `Meeting.summary: String?` (the export-facing fields already
// on `Meeting`, populated by "a later meeting-intelligence pass" per that model's own doc
// comment): those are flat strings because that is what
// `TranscriptedMarkdownExporter.actionItemsField`/`summaryField` (PR #18, not on this branch)
// consume, but this service's job is to produce the STRUCTURED result first. `MeetingActionItem`
// keeps `owner` and `text` apart so a caller can do something with the owner (route a
// notification, group by person) instead of re-parsing it back out of a string this service
// itself just joined together -- flattening to `Meeting.actionItems`' `[String]` shape, when a
// future wiring step needs to, is a lossless one-line map over `formatted` (see below), never
// the other direction.
import Foundation

/// One action item extracted from a meeting. `owner` is `nil` whenever the transcript did not
/// make an owner clear -- never a guess.
struct MeetingActionItem: Equatable, Sendable {
    let owner: String?
    let text: String

    /// `"Owner: text"` when `owner` is known, otherwise just `text`. This is the exact shape a
    /// downstream indexer extracts an owner from via a leading `"Name: "` prefix (see this
    /// file's header) -- the reason `owner` and `text` are captured separately in the first
    /// place is so this join happens exactly once, here, rather than being re-derived by every
    /// consumer.
    var formatted: String {
        guard let owner, !owner.trimmingCharacters(in: .whitespaces).isEmpty else { return text }
        return "\(owner): \(text)"
    }
}

/// A finished meeting's structured summary. `participants` is computed directly from
/// `MeetingSegment.speakerLabel` across the meeting's own segments, never from the model's
/// output -- see `MeetingSummaryPrompt`'s header comment for why that field is deliberately not
/// something the model is asked to produce.
struct MeetingSummary: Equatable, Sendable {
    let purpose: String
    let questions: [String]
    let conclusions: [String]
    let actionItems: [MeetingActionItem]
    let participants: [String]

    /// `true` when `MeetingTranscriptBudget` had to drop segments (or, in the pathological
    /// single-huge-segment case, hard-cut text) to fit the transcript sent to the model. A
    /// summary built from a truncated transcript is still a real, non-fabricated summary of the
    /// PART of the meeting the model actually saw -- this flag is how a caller distinguishes
    /// that from a summary of the whole meeting, rather than the two looking identical.
    let wasTruncated: Bool
}

/// Every outcome `MeetingSummaryService.summarize` can produce. Deliberately not `throws` for any
/// of these -- see that file's header for why only actual task cancellation is allowed to
/// propagate as a thrown error, and everything else (including every provider/parsing failure) is
/// a value here instead.
enum MeetingSummaryOutcome: Equatable, Sendable {
    /// A structured summary was produced and parsed successfully.
    case summary(MeetingSummary)

    /// The meeting had no real content to summarize (no segments, or every segment's text was
    /// empty/whitespace-only). No provider call is made for this case -- see
    /// `MeetingSummaryService.summarize` -- both to avoid spending an API call asking a model to
    /// summarize nothing, and because a model asked to do that has nothing to build a real
    /// answer from except invention.
    case empty

    /// `configuration.provider` was `.voiceInkRefine`. That provider's real implementation
    /// (`AIEnhancementService.makeRequest`, the `.voiceInkRefine` branch) calls
    /// `aiService.enhanceWithVoiceInkRefine(transcript:)` directly and never even reads
    /// `configuration.prompt` -- it always runs its own fixed dictation-refine behavior, so
    /// `MeetingSummaryPrompt` would silently never be sent to the model at all. Refusing here,
    /// before any request is made, is the honest response to that fixed contract; it is not a
    /// gap this service's own logic could close without adding new provider plumbing, which is
    /// out of scope.
    case unsupportedProvider

    /// The underlying `AIEnhancementService.enhance` call threw. `description` is
    /// `EnhancementFailureFormatter.description(for:)`'s existing, already-user-facing rendering
    /// of that error -- reused rather than re-derived, and consistent with how every other
    /// enhancement failure in this app is already described.
    case providerFailure(description: String)

    /// The provider returned text that could not be parsed into the four required sections (see
    /// `MeetingSummaryResponseParser`). `rawText` is kept for diagnostics -- logging, a future
    /// "show what the model actually said" UI -- but this case is never treated as a usable
    /// summary anywhere.
    case unparseable(rawText: String)
}

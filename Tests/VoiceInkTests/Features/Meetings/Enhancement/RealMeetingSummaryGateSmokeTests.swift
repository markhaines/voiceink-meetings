// Fork-owned (no donor equivalent). Not a port.
//
// The ONE place in this repo's meeting-summary tests that calls a REAL `AIEnhancementService`
// against a REAL, already-configured AI provider -- spending a real request against whatever
// provider Mark has connected. Every other test under
// `Tests/VoiceInkTests/Features/Meetings/Enhancement/` uses `FakeMeetingEnhancementProvider` and
// must never be changed to do otherwise.
//
// GATED THE SAME WAY `RealModelSmokeTests.swift` GATES ITS OWN REAL-MODEL CALLS -- reused
// verbatim, not reinvented, per FOLLOWUPS.md's "Gate-running modes" section, which is the one
// place that lists every `<GATE>_GATE_MODE` flag in this repo in its correct external form.
//
// `isRunningInCI` is `RealModelSmokeTests.swift`'s/`AudioGraphExceptionBridgeTests.swift`'s exact
// `VOICEINK_CI` idiom: CI has no configured provider and no business spending real API credits,
// so this suite is disabled there for an ORDINARY run -- but, unlike `RealModelSmokeTests.swift`
// (which disables on CI unconditionally, gate mode or not, because CI genuinely cannot have a
// downloaded model or audio hardware, full stop), an EXPLICIT `TEST_RUNNER_
// MEETING_SUMMARY_SMOKE_GATE_MODE=1` request overrides the CI skip here. A provider IS something
// CI could plausibly be given (a Keychain-backed key, unlike a GPU), so someone deliberately
// engaging gate mode there should get the loud, real "no provider" failure `#require` produces,
// not a silent, correctly-labeled-but-wrong-for-a-gate skip.
//
// THE MOST IMPORTANT PROPERTY OF THIS FILE, stated up front because getting it wrong once
// already meant an ordinary `xcodebuild test` run on a machine with ANY provider configured
// silently spent a real API call: **outside gate mode, this test is disabled UNCONDITIONALLY --
// regardless of whether a real provider happens to be configured.** Whether a usable provider
// exists is relevant ONLY inside the test body, ONLY once gate mode has already been confirmed,
// where it decides pass vs. `#require`-fail, never skip vs. run.
//
// GATE-RUNNING MODE. THE COMMAND TO RUN, copy it exactly:
//
//     TEST_RUNNER_MEETING_SUMMARY_SMOKE_GATE_MODE=1 xcodebuild test \
//       -project VoiceInk.xcodeproj -scheme VoiceInk -destination 'platform=macOS' \
//       -only-testing:VoiceInkTests/RealMeetingSummaryGateSmokeTests
//
// TWO DIFFERENT NAMES, ON PURPOSE, and getting this wrong silently defeats the whole mechanism --
// this is the exact mistake `RealModelSmokeTests.swift`'s own header records being made and fixed
// once already, so it is written correctly here from the start:
// `TEST_RUNNER_MEETING_SUMMARY_SMOKE_GATE_MODE` is the EXTERNAL environment variable you set on
// the `xcodebuild` invocation above. `xcodebuild test` launches the actual test host through a
// LaunchServices-mediated path that does not inherit that shell's environment at all -- except
// for variables prefixed `TEST_RUNNER_`, which it forwards into the test host WITH THE PREFIX
// STRIPPED. `MEETING_SUMMARY_SMOKE_GATE_MODE` (no `TEST_RUNNER_` prefix) is the UNPREFIXED name
// `isGateRunningMode` below reads via `ProcessInfo.processInfo.environment` INSIDE that
// already-launched test process -- it is never something an external caller sets directly.
// Setting the unprefixed form on `xcodebuild`'s own invocation does NOTHING: it never crosses the
// LaunchServices boundary, `isGateRunningMode` reads `nil` inside the test host exactly as if
// gate mode were never requested, a missing provider quietly SKIPS, and the run reports green --
// the exact false assurance this mechanism exists to prevent.
//
// PREREQUISITE: at least one AI enhancement provider other than VoiceInk Refine must already be
// configured (an API key in Keychain via `APIKeyManager`, or a connected Ollama/Local CLI/Custom
// setup) -- `AIService.connectedProviders` is read directly, the same source of truth the real
// app's own settings UI uses, not a second check invented for this test. This check happens
// ONLY inside the test body, ONLY once gate mode is already confirmed on (see above): in gate
// mode, a missing provider is a hard, loud test failure (`#require`), never a skip -- see
// `RealModelSmokeTests.swift`'s header for why that distinction is the entire point of a
// gate-running mode.
//
// VoiceInk Refine is deliberately excluded from "a usable real provider" here, not merely
// skipped over by chance: `MeetingSummaryService.summarize` refuses it unconditionally
// (`.unsupportedProvider`, see that file) because its real implementation
// (`AIEnhancementService.makeRequest`'s `.voiceInkRefine` branch) ignores any custom prompt and
// always runs its own fixed dictation-refine behavior. Picking it here would make this test
// exercise the refusal path, not the real summarization path it exists to prove.
//
// WHAT THIS TEST DOES NOT ASSERT: it never checks the real model's summary content for exact
// wording -- that would make the test flaky against ordinary model output variance and tell
// Mark nothing useful. It asserts SHAPE: the real call executed, produced a `.summary` outcome
// (not a provider failure or an unparseable response), and that outcome's `participants` list
// (computed independently of the model, from the fixture's own segments -- see
// `MeetingSummaryService.orderedUniqueParticipants`) matches those fixture segments exactly. That
// is what "the real path actually ran, end to end" means for this service.

import Foundation
import SwiftData
import Testing

@testable import VoiceInk

/// Same idiom as `RealModelSmokeTests.isRunningInCI` / `AudioGraphExceptionBridgeTests
/// .isRunningInCI` -- reused verbatim rather than reinvented.
private var isRunningInCI: Bool {
    ProcessInfo.processInfo.environment["VOICEINK_CI"] != nil
}

/// See this file's header, "GATE-RUNNING MODE", for the full mechanism and the canonical
/// command. READ THAT BEFORE SETTING ANYTHING: this string is the UNPREFIXED name this
/// already-launched test process reads its own environment for -- it is NOT what an external
/// caller sets. Engaging this from outside requires the EXTERNAL, `TEST_RUNNER_`-prefixed form
/// on the `xcodebuild` invocation instead.
private var isGateRunningMode: Bool {
    ProcessInfo.processInfo.environment["MEETING_SUMMARY_SMOKE_GATE_MODE"] != nil
}

@Suite("Real-provider meeting summary smoke test (gate-running mode)")
struct RealMeetingSummaryGateSmokeTests {
    @Test(
        "a real, already-configured AI provider actually summarizes a small real transcript end to end",
        // CI skip, OVERRIDABLE by an explicit gate-mode request -- see this file's header,
        // "THE MOST IMPORTANT PROPERTY OF THIS FILE" and the paragraph above it, for why this
        // one trait differs from `RealModelSmokeTests.swift`'s unconditional CI disable.
        .disabled(
            if: isRunningInCI && !isGateRunningMode,
            "spends real provider credits -- CI has no configured provider (VOICEINK_CI idiom, see AudioGraphExceptionBridgeTests.swift); overridden by an explicit gate-mode request"
        ),
        // THE BLOCKING FIX: this trait no longer depends on whether a provider happens to be
        // configured. It used to (`!hasUsableRealProvider() && !isGateRunningMode`), which meant
        // an ORDINARY `xcodebuild test` run on any machine with any provider already configured
        // -- Mark's own daily machine included -- was NOT disabled and called the real provider.
        // Outside gate mode this test is disabled full stop, regardless of what is configured;
        // whether a provider exists is checked only inside the body, only once gate mode is
        // already on, via `#require` below.
        .disabled(
            if: !isGateRunningMode,
            "spends real provider credits -- only runs in gate mode (TEST_RUNNER_MEETING_SUMMARY_SMOKE_GATE_MODE=1, see this file's header)"
        )
    )
    @MainActor
    func realProviderSummarizesRealMeeting() async throws {
        let aiService = AIService()
        let provider = try #require(
            aiService.connectedProviders.first { $0 != .voiceInkRefine },
            "gate mode requires a configured AI enhancement provider, but none is connected"
        )

        let schema = Schema([Meeting.self, MeetingSegment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let modelContext = ModelContext(container)

        let enhancementService = AIEnhancementService(aiService: aiService, modelContext: modelContext)
        let service = MeetingSummaryService(enhancementProvider: enhancementService)

        let meeting = Meeting(title: "Launch Checklist Sync", audioDirectoryPath: "/tmp/meeting-summary-gate-smoke")
        modelContext.insert(meeting)

        let segments = [
            MeetingSegment(
                startOffset: 0, endOffset: 4, speakerLabel: "You",
                text: "Let's quickly decide who owns the launch checklist before Friday.",
                sourceChannel: .mic, orderIndex: 0, meeting: meeting),
            MeetingSegment(
                startOffset: 4, endOffset: 10, speakerLabel: "Speaker 1",
                text: "I can take the launch checklist and have it ready by Friday.",
                sourceChannel: .system, orderIndex: 0, meeting: meeting),
        ]
        for segment in segments {
            modelContext.insert(segment)
            meeting.segments.append(segment)
        }

        let configuration = MeetingSummaryProviderConfiguration(
            provider: provider, modelName: aiService.selectedModel(for: provider))

        let outcome = try await service.summarize(meeting: meeting, segments: segments, configuration: configuration)

        guard case .summary(let summary) = outcome else {
            Issue.record("expected a real .summary outcome from provider=\(provider.rawValue), got \(outcome)")
            return
        }

        #expect(summary.participants == ["You", "Speaker 1"])
        #expect(summary.wasTruncated == false)
        print(
            "REALMEETINGSUMMARY-SMOKE provider=\(provider.rawValue) purpose-length=\(summary.purpose.count) "
                + "questions=\(summary.questions.count) conclusions=\(summary.conclusions.count) "
                + "action-items=\(summary.actionItems.count)"
        )
    }
}

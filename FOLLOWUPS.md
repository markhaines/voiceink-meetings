# Follow-ups

Known gaps and limitations deliberately left open, with the reasoning, so they are
decisions rather than accidents. Not a task tracker: a record so they are not
rediscovered from scratch later. See each entry for the evidence.

## Gate-running modes: the central list

This project's real-model/real-audio smoke tests skip cleanly when their prerequisites (a
downloaded model, real audio, network reachability) are absent -- correct, desired convenience
for ordinary developer and CI runs. Each such test also has a GATE-RUNNING MODE: an opt-in that
turns a missing prerequisite from "skip" into "fail loudly", so a passing run can only mean the
real path actually executed. **This is the one place that lists every one of those flags, in the
external form a caller actually sets, so the next one doesn't need rediscovering (or get its
prefix wrong the way `RealModelSmokeTests.swift`'s own header comment once did -- see that file's
GATE ITEM 1 entry below for the full story of that mistake).**

Every flag here follows the SAME two-name shape, and the distinction is load-bearing, not
cosmetic: the EXTERNAL name, `TEST_RUNNER_<GATE>_GATE_MODE`, is what you set as an environment
variable on the `xcodebuild` command itself; `xcodebuild test` launches the actual test host
through a LaunchServices-mediated path that does not inherit that shell's environment at all,
except for `TEST_RUNNER_`-prefixed variables, which it forwards into the test host WITH THE
PREFIX STRIPPED. The UNPREFIXED name, `<GATE>_GATE_MODE`, is what the already-launched test
process reads back via `ProcessInfo.processInfo.environment` -- it is never something an external
caller sets directly. Setting the unprefixed form on the outer `xcodebuild` invocation does
nothing: it never crosses that boundary, the test process reads it as absent, and a missing
prerequisite quietly skips and reports green.

**Whenever a gate has a CI skip, gate mode must override it -- no exception.** Not every gate has
one: `TranscriptedIndexerAcceptanceTests.swift` defines no independent CI-disable trait at all, so
gate mode simply wins there with nothing to override. `RealModelSmokeTests.swift` DOES have one
(the `isRunningInCI` / `VOICEINK_CI` idiom `AudioGraphExceptionBridgeTests.swift` established), as
a convenience for ordinary CI runs that have neither downloaded models nor real audio hardware.
Wherever such a CI-disable trait exists, it must be written
`.disabled(if: isRunningInCI && !isGateRunningMode, ...)` -- gate mode ANDed against the CI check,
never a bare `.disabled(if: isRunningInCI, ...)` that gate mode cannot reach. The reasoning is the
same one that justifies gate mode existing at all: the whole point is that a pass means the real
path ran and a missing prerequisite fails loudly, so an environment variable a caller may not know
about -- CI or otherwise -- must never be able to silently downgrade an explicitly requested gate
into a skip. A gate-mode failure on a runner with no models is not an unrelated failure; it is
exactly the information an operator who set that flag asked for.

`RealModelSmokeTests.swift` got this wrong twice in successive rounds, and both mistakes are worth
recording so a future gate doesn't repeat either. First (fixed 2026-09-06): it applied its CI
disable unconditionally, with a header arguing that was deliberate -- the mistake this section's
opening rule now exists to prevent. Second (fixed in the same round, after review): its fix
claimed the explanation (naming the missing prerequisite and the CI environment) lived in the
`.disabled` SKIP messages, and that a gate-mode failure would carry it. That is impossible by
construction -- `!isGateRunningMode` is ANDed into every one of those conditions, so gate mode is
exactly what stops them firing, and a skip message that never displays explains nothing. A gate
that wants a self-explanatory gate-mode failure has to put the explanation somewhere gate mode
actually reaches: an explicit check inside the test body itself (see `GateModePrerequisiteMissing`
in that file), not a `.disabled` trait's message. See that file's header, "MAKING THAT FAILURE
SELF-EXPLANATORY," for the full story and the proof. Any new gate landing here with its own
CI-disable trait must use the ANDed form from the start, and if it wants its gate-mode failures to
be self-explanatory, that explanation belongs in the test body, not in a skip message.

**Exemption: `AudioGraphExceptionBridgeTests.swift`'s three CI disables are NOT part of this
convention, and should not be "fixed" to match it.** They read a bare
`.disabled(if: isRunningInCI, ...)` with no `isGateRunningMode` in sight, because that file defines
no `<GATE>_GATE_MODE` flag at all -- there is nothing for gate mode to override. Those three tests
exist to skip a ~600s hang against this CI runner's specific CoreAudio device inventory; they are
not real-model/real-audio prerequisite gates, so the ANDed form and this section's convention
simply don't apply to them.

| Flag (external, `TEST_RUNNER_`-prefixed) | Test file | Status |
|---|---|---|
| `TEST_RUNNER_REALMODEL_SMOKE_GATE_MODE` | `Tests/VoiceInkTests/Features/Meetings/Transcription/RealModelSmokeTests.swift` | Live (2026-09-06) |
| `TEST_RUNNER_MEETING_SUMMARY_SMOKE_GATE_MODE` | `Tests/VoiceInkTests/Features/Meetings/Enhancement/RealMeetingSummaryGateSmokeTests.swift` | Live (2026-09-06) |
| `TEST_RUNNER_TRANSCRIPTED_ACCEPTANCE_GATE_MODE` | `Tests/VoiceInkTests/Features/Meetings/Export/TranscriptedIndexerAcceptanceTests.swift` | Live (2026-09-06) -- adopted this sibling's two-name convention once PR #19 merged to `main`, but DELIBERATELY WITHOUT its independent CI-disable trait, so gate mode overrides CI here (Mark's ruling; `RealModelSmokeTests` is expected to be realigned to this rule separately). See `TRANSCRIPTED_ACCEPTANCE.md` and that test file's header for the real-binary prerequisite this one gates on, and for the full reasoning. |

**Canonical command, run every gate-running mode this repo has together** (harmless for any not
yet defined -- an env var nothing reads is simply ignored):

```
TEST_RUNNER_REALMODEL_SMOKE_GATE_MODE=1 \
TEST_RUNNER_MEETING_SUMMARY_SMOKE_GATE_MODE=1 \
TEST_RUNNER_TRANSCRIPTED_ACCEPTANCE_GATE_MODE=1 \
  xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -destination 'platform=macOS' \
  -only-testing:VoiceInkTests/RealModelSmokeTests \
  -only-testing:VoiceInkTests/RealMeetingSummaryGateSmokeTests \
  -only-testing:VoiceInkTests/TranscriptedIndexerAcceptanceTests
```

Add each new gate's `TEST_RUNNER_<GATE>_GATE_MODE=1` on its own line above as it lands, and widen
`-only-testing:` (or drop it to run the whole suite) to cover it.

## `MeetingSummaryService`'s structured output has no join function into `Meeting.actionItems`/`Meeting.summary` yet

Source: `VoiceInk/Features/Meetings/Enhancement/{MeetingSummaryService,MeetingSummaryTypes}.swift`;
consumer: `TranscriptedMarkdownExporter.swift` (PR #18, `phase3-transcripted-export` branch, not on
`main`).

**OPEN, recorded rather than fixed, because it belongs to whichever PR does the actual wiring, not
to the summarizer built in isolation from it.** `MeetingSummaryService.summarize` returns a
`MeetingSummary` -- `purpose: String`, `questions: [String]`, `conclusions: [String]`,
`actionItems: [MeetingActionItem]`, `participants: [String]`, `wasTruncated: Bool` -- entirely
independent of `Meeting`'s own persisted, exporter-facing fields (`actionItems: [String]`,
`summary: String?`). Reviewed and accepted on the understanding that the exporter can stay
untouched ONLY once a future wiring step supplies two things neither this service nor the exporter
currently has:

1. **Action items: the join exists, but nothing calls it yet.** `MeetingActionItem.formatted`
   ("Owner: text" or just "text") is exactly `Meeting.actionItems`' `[String]` element shape --
   a future composition root should be able to write `Meeting.actionItems = summary.actionItems
   .map(\.formatted)` and get `TranscriptedMarkdownExporter.actionItemsField`'s existing `"- item |
   - item"` contract for free, unchanged. That call does not exist anywhere yet.
2. **`Meeting.summary`: no formatter exists at all.** `Meeting.summary` is a single `String?`, but
   `MeetingSummary` carries THREE separate prose/list fields (`purpose`, `questions`,
   `conclusions`) with no defined function combining them into one string. Whoever wires this in
   has to decide that shape (headed sections? just `purpose`? something the exporter's frontmatter
   grows a field for instead of squeezing into the body?) -- it is a real, unresolved design
   decision, not an oversight to fix mechanically.

Also unresolved by the same wiring step: `MeetingSummary.participants` has no destination at all
today -- `TranscriptedMarkdownExporter` (as it stands on PR #18) has no `auto_summary_participants`
frontmatter key; only `auto_summary`, `auto_summary_action_items`, and `auto_summary_version`
exist there. See that PR's own description, which calls the rest of the `auto_summary_*` family
(participants included) a known, not-yet-built gap.

## `MeetingSummaryResponseParser` refuses strictly, and nobody has measured what that costs in practice

Source: `VoiceInk/Features/Meetings/Enhancement/{MeetingSummaryResponseParser,MeetingSummaryPrompt}.swift`.

**OPEN, recorded rather than built, deliberately.** The parser refuses (`.unparseable(rawText:)`)
on any line it cannot confidently attribute: text before the first header, an un-bulleted and
un-indented line inside a bulleted section, a second un-bulleted line inside one block. That is the
right default -- three separate review rounds established that guessing here produces a summary
which reads as complete while a real agreed action is missing -- but it means an otherwise-good
model response is rejected WHOLE over a formatting slip, and Mark gets no notes for that meeting.
The response to that is deliberately on the INPUT side (the prompt now states "no text before the
first header", "no closing remark", "every entry on its own `- ` line", "never wrap an entry",
"never indent or nest" as hard rules, and says a breach is rejected in full), not on the parser's.

Two follow-ups, in this order, neither started:

1. **MEASURE the real refusal rate before changing anything else.** The measurement tool already
   exists and does not need building: `RealMeetingSummaryGateSmokeTests.swift`, run in gate mode
   with the external flag **`TEST_RUNNER_MEETING_SUMMARY_SMOKE_GATE_MODE=1`** (see this file's
   "Gate-running modes: the central list" for the exact command). It already calls a real,
   configured provider end to end and asserts a `.summary` outcome, so a `.unparseable` shows up as
   a loud failure with the model's raw text in hand. What is missing is repetition and variety: a
   handful of runs across the providers Mark actually uses, over a few different real transcript
   fixtures, recording how often the tightened prompt is honoured. Without that number, "the
   refusals are too aggressive" and "the refusals almost never fire" are both just opinions --
   including the ones in the review that prompted this entry.
2. **THEN consider one retry on `.unparseable`, with a stricter reminder.** `MeetingSummaryService
   .summarize` currently makes exactly one provider call and reports the outcome. A single retry --
   same transcript, same prompt plus a short "your previous response broke rule X; re-emit it
   following the output format exactly" reminder -- would recover most formatting slips at the cost
   of one extra real API call per failed meeting. It is NOT built here for three reasons: it
   doubles the worst-case spend per meeting, it needs a decision about whether the retry's own
   failure is reported differently from the first (a caller cannot currently tell "failed twice"
   from "failed once"), and it should be aimed at whatever the measurement in (1) says actually
   breaks, rather than at a guess about which rule models most often ignore. Do (1) first.

## `retainRecording` stays `false` on `meetings-ui-shell` -- turning it on today would be worse, not better

Source: `VoiceInk/Features/Meetings/Views/MeetingRecordingController.swift`,
`VoiceInk/Features/Meetings/Workflows/MeetingEngine.swift`. Cross-vendor review of PR #15's
launch-fix round flagged that `MeetingsView`'s copy implied retained audio while
`retainRecording: false` means only metadata + an empty transcript survive, and delegated the
underlying judgement call: should the flag flip to `true` instead of just fixing the wording?

**Decision: no, stays `false`.** Not for the reason originally on the table (no settings surface
for a real user choice -- still true, but not sufficient on its own): reading
`MeetingEngine.stop()` shows `MeetingEngineResult.retainedRecordingURL` is only ever the raw
temp WAV `MeetingRecordingWriter` wrote -- `persistTemporaryRecordingAsync` (the temp-to-
permanent-M4A step) is explicitly NOT called anywhere in this stage, per `MeetingEngine.swift`'s
own header: "persisting it permanently is a later stage's (a future app-controller's) job." And
`MeetingRecordingController.stopMeeting()` discards the whole `MeetingEngineResult` after
extracting only `persistenceFailures` -- it never reads `retainedRecordingURL` at all.

So flipping the flag today, on this branch, with no other change, would not give Mark a kept
recording. It would write a temp WAV for the full length of every meeting, then leak that file:
nothing captures its path, nothing surfaces it in the UI, nothing moves it anywhere durable, and
nothing cleans it up. That is `NSTemporaryDirectory()` growing unboundedly and invisibly for as
long as the app runs between reboots -- a worse failure mode than the current honestly-empty
row, not a better one, and exactly the "audio accumulates on disk undisclosed" risk the review
raised as the argument against `true`.

**Would need revisiting** together, not separately, with: (a) wiring
`persistTemporaryRecordingAsync` (or an equivalent) so the file actually reaches permanent
storage, (b) a place to reference that path from the `Meeting` row (a schema change, since
`Meeting`/`MeetingSegment` have no audio-path field today), (c) a management/playback surface so
the retained audio is discoverable and deletable, and (d) UI copy that reflects all of the above
truthfully. That is Phase 3 (Transcripted-parity export) territory, not a wording fix's scope --
flipping one `Bool` without the other three pieces trades one honest gap for a hidden one.

## `MeetingsView`'s `@Query` and `MeetingDetailView`'s segment list are both unbounded

Source: `VoiceInk/Features/Meetings/Views/MeetingsView.swift` (`@Query(sort: \Meeting.startDate,
order: .reverse) private var meetings: [Meeting]`) and
`VoiceInk/Features/Meetings/Views/MeetingDetailView.swift` (`orderedSegments`, rendered as one
`SegmentBubble` per segment in a plain `VStack` inside a `ScrollView`, no lazy container).
Flagged as non-blocking by cross-vendor review of PR #15's launch-fix round.

Both fetch/render everything with no page size and no virtualization. Fine today -- a fresh
install has zero-to-few meetings, and Stage 2c's transcription is stubbed so every meeting's
segment count is currently zero regardless of length -- but two things change that:

- A long-lived install accumulates meeting rows with no cap on the `@Query`.
- Once Stage 2c lands real transcription, a 60-90 minute meeting could produce hundreds of
  segments, all rendered eagerly in a non-lazy `VStack` rather than a `LazyVStack`.

**Not fixed here**: bounding either one is a real design decision (pagination UI for the list,
`LazyVStack` + possibly `LazyVStack`-unfriendly bubble-alignment rework for the detail view) that
deserves its own pass rather than a reactive patch inside a wording/lifecycle fix round.
**Worth doing before Stage 2c ships real transcription**, at the latest -- that is when segment
counts per meeting stop being zero.

## App termination while a meeting is recording strands the row at `.recording` forever -- RESOLVED (PR #15 review round 3, B1)

Both halves this entry called for are now built. See `FORK-PATCHES.md`'s "PR #15 review round
3" section for the full design and verification:

- `AppDelegate.applicationShouldTerminate(_:)` (new) holds termination with `.terminateLater`,
  races `MeetingRecordingController.stopMeetingAndWait()` (new) against a 5-second ceiling, and
  replies `true` either way -- answering this entry's "how long should a quit visibly block"
  question with an explicit, justified number, and its "what if `stop()` hangs" question with
  "reply anyway; the row is real either way."
- `MeetingStore.reconcileInterruptedRecordings(in:)` (new), called from `VoiceInk.swift`'s
  `init()` on every launch, is the actual answer to "someone builds a way to reconcile stale
  `.recording` rows at launch" this entry asked for -- it is what catches everything (i) cannot:
  `kill -9`, a panic, a power cut, or a clean quit that outran the 5-second ceiling.

Residual, carried forward rather than silently dropped: two processes of the same build racing
each other at launch (bypassing the Dock/LaunchServices single-instance behavior) is still
unaddressed -- would need process-singleton locking, which this fix does not add.

## `MeetingStore`'s isolation guarantee excludes raw-memory forgery and `Mirror` on a handle

Source: `VoiceInk/Features/Meetings/Models/MeetingStore.swift`. `MeetingStore` guarantees that
no code outside that file can reach the `ModelContext` it mutates or the managed objects
registered in it, and enforces that four ways (no `ModelActor` conformance, a file-`private`
engine actor, a `struct` facade that cannot be made to conform retroactively, and the engine
held only as a closure capture). The guarantee is explicitly scoped to the language's CHECKED
features. Two things fall outside it, disclosed here rather than papered over:

1. **`unsafeBitCast` and raw-memory access.** These defeat any Swift boundary; this one is no
   exception, and no design short of process separation would change that. The closure
   indirection does raise the cost from a one-line cast on a stored property to reconstructing
   an undocumented closure-context layout, but that is a cost, not a defence, and is not
   claimed as one.
2. **`Mirror` on a `MeetingHandle`** recovers the `PersistentIdentifier` inside it, even though
   the field is `fileprivate`. This is asserted by a test
   (`MeetingStoreIsolationTests.handleReflectionIsADisclosedHole`) so the disclosure cannot go
   stale. It grants no authority: a `PersistentIdentifier` is only usable with a
   `ModelContext`, and anyone who can make one already has `fetch(FetchDescriptor<Meeting>())`
   over the same rows. It does not reach the store's own context, so the guarantee above is
   unaffected. The `fileprivate` exists to keep ordinary checked code away from
   `ModelContext.model(for:)` (which fatal-errors on an unrecognised identifier rather than
   returning nil), not to hide a secret.

**Would need revisiting** if meeting data ever becomes something a hostile in-process component
could be interested in — a plugin host, or a scripting surface. Today every caller is
first-party code in the same binary, where the boundary's job is to make the wrong thing hard
to write by accident, not to withstand a determined attacker who already has code execution.

## `Meeting.id` / `MeetingSegment.id` are not declared `@Attribute(.unique)`

Source: `VoiceInk/Features/Meetings/Models/Meeting.swift`,
`VoiceInk/Features/Meetings/Models/MeetingSegment.swift`. Both `id: UUID` fields are plain
stored properties, not marked unique. This is fine today because every `id` is locally
constructed (`UUID()` in each model's own `init`, never accepted as external input) and nothing
currently queries by `id` for identity purposes — `MeetingStore` looks meetings
up by `PersistentIdentifier`, SwiftData's own row identity, not by this field.

**Would need revisiting** if a future import or sync path (e.g. a Transcripted-compatible
importer, or cross-device sync) ever admits externally supplied `id` values: without a
uniqueness constraint, two rows could silently share an `id`, and any code written later that
assumes `id` is a reliable lookup key (following the pattern `Meeting.id` is already documented
as suited for — see `MeetingStoreDurabilityTests.swift`'s note on why
`PersistentIdentifier` doesn't survive a container reopen but `Meeting.id` does) would need the
constraint added first. Not fixed here: no current caller needs it, and adding `@Attribute
(.unique)` to an already-shipped model is the kind of change worth making deliberately, with a
migration in mind, rather than speculatively.

## `RouteAwareMeetingMicRecorderTests`: cross-queue assertion audit (2026-09-02)

Source: `Tests/VoiceInkTests/Features/Meetings/Capture/RouteAwareMeetingMicRecorderTests.swift`.
This file produced two intermittent CI failures in two different tests
(`liveRouteChangeWaitsForFirstBuffer`, then `healthTriggeredRecoveryPromotesOnFirstBuffer`),
both the same class: `RouteAwareMeetingMicRecorder` retires a superseded child recorder by
dispatching `child.recorder.stop(); child.recorder.cancel()` onto `cleanupQueue`
(`.concurrent`) from `completePendingHandoff`, which itself runs on the serial
`lifecycleQueue`. A test's `waitUntil` loop that only watches the *promotion signal* (the
`samples` callback, or `activeRecorderKindForDebug()`) can observe that signal and fall
through to a `#expect` on `stopCalls`/`cancelCalls` before the concurrently-dispatched
retirement block has actually run — a wait that observes the promotion is not a wait that
observes the teardown.

Audited every one of the file's 24 `@Test`s for this shape: does a `#expect` read state
written on `handoffWorkerQueue`/`cleanupQueue` without either (a) a direct `waitUntil` on
that exact state, (b) a semaphore explicitly signalled from that write, or (c) a queue-order
argument that's actually airtight (e.g. `stop()`/`cancel()` are literally the next
synchronous statement on the calling thread, so returning from the call already proves the
write happened)? 20 were safe by one of those three. 4 were exposed and fixed, all with the
same idiom — extend the wait to cover the write actually being asserted, never a sleep:

- `liveRouteChangeWaitsForFirstBuffer` — waited on `stopCalls` but not `cancelCalls`, which
  is the second statement in the same retirement closure; extended the wait to both.
- `healthTriggeredRecoveryPromotesOnFirstBuffer` — the flake itself: waited on `samples` but
  asserted `degraded.stopCalls` next line, unguarded. Added `waitUntil { degraded.stopCalls
  == 1 }`.
- `rapidRouteChangesRejectSupersededCallbacks` — asserted `samples` after two *unrelated*
  waits (`diagnosticsSnapshot()`, `system.stopCalls`) that happened to postdate the `samples`
  write in lifecycleQueue program order. Technically safe but fragile — one reordering of
  statements in `completePendingHandoff` would silently break the guarantee with no compiler
  or test-runner signal. Hardened with a direct `waitUntil { samples == ... }`.
- `stopWithQueuedRecoveryNeverStartsCandidate` — used a blind 200ms `DispatchSemaphore` +
  `asyncAfter` delay as a "let it settle" proxy instead of watching the actual write. Replaced
  with `waitUntil { candidate.cancelCalls >= 1 }` (test converted to `async throws`); the
  `startCalls == 0` assertion next to it remains valid regardless of timing because the
  production code's `isPendingCandidateCurrent` guard makes that code path structurally
  unreachable once `stop()` has cleared `state.pending`, not just unlikely to be reached in
  time.

**The rule for the next test added to this file**: if an `#expect` reads a counter or
callback effect that the production code sets from `handoffWorkerQueue` or `cleanupQueue`
(anything dispatched via `cancelAsync`/`retireAfterHandoffAsync`/the handoff worker's
`.async` block), the preceding `waitUntil` must name that exact variable — not a different
variable that happens to change around the same time, and never a fixed sleep. `waitUntil`
itself is always safe as a *wait condition* (worst case it polls longer or times out loudly
via `Issue.record`); the risk is only ever an `#expect` immediately following a wait on
something else.

Proof the fixes are load-bearing, not just quieter: added a temporary `teardownDelay` hook to
`FakeMeetingMicRecorder.stop()`/`cancel()` (0.3s `Thread.sleep`), reverted the two flaky
tests' final assertions to their pre-fix unguarded form, and ran them — both failed
deterministically (`Expectation failed: (system.stopCalls → 0) == 1` /
`(degraded.stopCalls → 0) == 1`). Restored the guarded form with the delay still active — both
passed (0.623s / 0.312s, visibly absorbing the injected delay via the wait). Reverted the
delay instrumentation via `git checkout` + reapplying the real fix as a patch, so no
instrumentation shipped. 30-iteration loops of both tests: 30/30 pass, 0 failures, confirmed
against the `.xcresult` bundle (not just log grep) since `-only-testing` selectors for a single
`@Test` method require the `()` suffix — an earlier run in this same session silently matched
zero tests without it (`totalTestCount: 0`) and would have reported a meaningless "0/0 passed"
had the bundle not been checked.

## `AudioGraphExceptionBridgeTests`: three tests skip on CI, run for real on a developer Mac

`inputStateReadIsContained`, `invalidInputRouteIsContained` and `installTapExceptionIsContained`
(`Tests/VoiceInkTests/Features/Meetings/Capture/AudioGraphExceptionBridgeTests.swift`) construct
a real `AVAudioEngine()` and touch `.inputNode`, which is unreliable against GitHub Actions'
macOS runner's specific CoreAudio device inventory. Two independent branches hit this:

- `phase-1-mic-route` (PR #3): a ~600s hang (CI run 33555297407), then again at run 33561167080
  after a device-presence guard was proven not to change the outcome (the runner DOES enumerate
  an input-capable CoreAudio object, so that guard evaluated true and the real calls still ran).
- `phase-1-capture-core` (PR #4): a different manifestation of the same cause — an immediate
  crash of the shared xctest host process (CI run 33560960456; all four in-flight tests,
  including two unrelated `CoreAudioSystemRecorderTests` cases, failed at exactly 0.000s within
  ~1.5ms of each other at the tail of the run — collateral damage, not a defect in
  `CoreAudioSystemRecorderTests` itself, confirmed by that file's own header stating none of its
  tests touch real hardware).

One shared root cause, two timing-dependent manifestations, not two separate bugs, and not a
production defect — real Macs have an addressable input device, so this is specific to the
runner's virtualized/absent audio hardware.

**Adopted fix** (from `phase-1-mic-route` commit `8ecc2d1`, copied verbatim onto this branch so
both branches carry byte-identical `.github/workflows/ci.yml` and
`AudioGraphExceptionBridgeTests.swift` for a clean merge): `.github/workflows/ci.yml`'s "Run
test targets" step sets `env: TEST_RUNNER_VOICEINK_CI: 1`; `xcodebuild` forwards any
`TEST_RUNNER_`-prefixed environment variable into the LaunchServices-launched xctest host with
the prefix stripped, which a plain `GITHUB_ACTIONS`/`CI` check cannot reach (verified: that
shell-level variable never propagates to the test process). The three tests gate on
`ProcessInfo.processInfo.environment["VOICEINK_CI"] != nil` via `.disabled(if: isRunningInCI,
...)`, so they SKIP on CI and RUN FOR REAL on a developer Mac (including Xcode's own Test
Navigator, which doesn't go through this CI script). This was chosen over an earlier
unconditional `.disabled(if: true, ...)` version specifically because that left the ObjC
exception-containment boundary with zero automated coverage anywhere — cross-vendor review
correctly rejected that as an unacceptable endpoint.

An earlier device-presence guard attempt on this exact file/branch is superseded and no longer
described in the file header — see PR #3's `acf438c`/`2f822a4` history for that dead end if it
resurfaces as a suggestion.

## `RouteAwareMeetingMicRecorderTests.healthTriggeredRecoveryPromotesOnFirstBuffer` flaked once on CI — RESOLVED

`Tests/VoiceInkTests/Features/Meetings/Capture/RouteAwareMeetingMicRecorderTests.swift`. Failed
once on CI run 33664226428 (attempt 1) at 0.038s -- far inside `waitUntil`'s 5s timeout, so an
assertion flipped rather than a wait expiring. Evidence that it is non-deterministic rather than
a real regression:

- **The same commit (`1bc26756`) passed on attempt 2 of the same run**, with no code change
  between attempts.
- Locally the test passed 12/12 consecutive runs alongside the full `MeetingEngineTests` suite.
- It is the only failed run in the last 25 on this repo.
- The change in flight (`MeetingChunkCollector`/`MeetingEngine` persistence reporting) touches
  no code this test exercises: `MeetingEngineTests` uses its own private `FakeMeetingMicRecorder`
  and never constructs a `RouteAwareMeetingMicRecorder`.

**Was recorded here as "likely cause, not confirmed"** (unsynchronised counters read across
threads). **Now confirmed and fixed**, together with the same class of bug found elsewhere in
the same file, by the "`RouteAwareMeetingMicRecorderTests`: cross-queue assertion audit
(2026-09-02)" entry above — see that entry for the exact race, the full per-test audit, and the
before/after proof that the fix is load-bearing. The `#expect(degraded.stopCalls == 0)`
mentioned in the original diagnosis as an additional "has not happened yet" assertion turned out
to be safe (nothing in this test's flow could set it early); the actual fault was the very next
`#expect(degraded.stopCalls == 1)` after the buffer arrives, asserted before the async
retirement that sets it had necessarily run.

## `.xcresult` not recoverable from a failed CI run

When "Run test targets" fails, nothing in `.github/workflows/ci.yml` uploads the `.xcresult`
bundle (or a crash report) as a workflow artifact — it only exists on the ephemeral runner
filesystem, which is gone once the job ends or the run is re-triggered. This meant the CI
run 33560960456 investigation above had to work entirely from the raw step log's text output
(test names, pass/fail, per-test duration) rather than the structured result bundle or an actual
crash report, and any `.xcresult`-level detail (symbolicated stack, signal, thread state) for
that specific failure is permanently lost. Worth fixing at the workflow level: add an
`actions/upload-artifact` step, gated on `if: failure()`, that uploads
`.ci-test-build/Logs/Test/*.xcresult` (see the path xcodebuild already prints under "Test
session results, code coverage, and logs:") so a future flaky-test investigation has the real
bundle instead of reconstructing evidence from log text. Not done here — out of scope for this
branch's immediate test-reliability fix.

## `pause()`/`resume()` can still leave a meeting row on the wrong `MeetingState`

Source: `VoiceInk/Features/Meetings/Workflows/MeetingEngine.swift`, `pause()`'s
`Task { try? await persistence.updateState(.paused, for: meetingHandle) }` and `resume()`'s
equivalent `.recording` call. Same shape as the `discard()` gap this entry used to describe:
`try?` discards `updateState`'s error, so if that one write fails the row keeps whatever state
it held before the call instead of reflecting what actually happened, and neither `pause()` nor
`resume()` is `async` or returns anything a caller could inspect to notice.

**`discard()`'s own `markFailed` half of this same original finding IS now fixed** (see
FORK-PATCHES.md's engine-cleanup entry): it retries a bounded number of times and, only if
every attempt fails, reports the final error on the existing stderr channel with enough detail
to act on -- so a caller can no longer lose the error with a single silent `try?`. The residual
that fix disclosed rather than hid: retrying shrinks the window in which a genuinely broken
store leaves the row stuck, it does not close it, and there is still no `stop()`-style result
object for a caller to inspect. `pause()`/`resume()`'s `updateState` calls were never in scope
for that fix and remain exactly as open as before -- **still worth closing the same way**
before Phase 2, ideally reusing the same retry-then-report shape rather than re-deriving it.

## Repeated `discard()` calls can start overlapping `markFailed` retry loops

Source: `VoiceInk/Features/Meetings/Workflows/MeetingEngine.swift` (`markMeetingFailedAfterDiscard`).
Raised as a non-blocking note by cross-vendor review of PR #13 (the round that closed `discard()`'s
silent `try? markFailed` gap), and accepted rather than fixed there.

`discard()` has no one-shot guard, so calling it more than once can start more than one unstructured
retry `Task` against the same meeting row. This is not new behaviour introduced by the retry: before
PR #13 the same repeated calls produced overlapping *single* attempts. What the bounded retry changes
is the amplitude, not the shape: three attempts per call instead of one, so concurrent loops generate
more `markFailed` traffic and can emit duplicate final stderr lines for one logical failure.

Not a correctness defect: `markFailed` is idempotent in intent (it drives the row to `.failed`), so
overlapping loops converge on the same terminal state rather than fighting. The cost is noise and
wasted work, not a wrong row.

**Fix when `discard()` next gets touched:** give it a one-shot guard so a second call is a no-op
rather than a second retry loop. Cheap to do at that point; not worth its own round now.

## Known limitations to validate

### DTLN AEC delay estimator: fixed 0–800ms candidate grid, no clock-skew compensation

Source: `VoiceInk/Features/Meetings/Capture/MeetingNeuralAec.swift` (`MeetingAecDelayEstimator`),
ported verbatim from the donor — this is donor behavior, not something introduced by the DTLN
port. Cross-vendor review of the Phase 1 Stage 1 AEC port (`phase-1-aec-dtln`) confirmed: the
periodic delay estimate tracks modest drift between the mic and system-audio reference by
re-scoring a fixed grid of candidate delays (`MeetingAecDelayEstimator.defaultCandidateDelaysMs`,
0–800ms in fine steps), but there is no resampling and no explicit clock-skew compensation.
Sustained skew over a long meeting will eventually walk the true delay outside that 0–800ms
range, at which point every candidate scores badly and the estimator has nothing better to fall
back to.

**Validate in the Phase 2 two-hour soak test.** Watch `MeetingAecDiagnosticsSnapshot.delayHistory`
and `.delaySkipHistory` for a session that runs long enough for drift to plausibly exceed 800ms,
and check whether `decision == "rejectedLowConfidence"` starts dominating late in the recording
(the symptom of the true delay having walked off the grid).

## Handover: MeetingEngine / MeetingSession integration owner

### Route-state concurrency

`MeetingAecRouteBypassSource` (`MeetingNeuralAec.swift`) is read from
`processStreamingMic`/`resetForStreaming`, which per the file's own existing comment run only on
`MeetingSession`'s `chunkRotationQueue`. Whatever concrete type backs `routeBypassSource` (wired
to the real `AudioRouteClassifier`) needs to make its `isHeadphoneLikeRoute` reads safe against
whatever queue/thread actually detects a route change (e.g. a CoreAudio device-change callback),
since that is very unlikely to be the same queue. Not built here — this file only defines the
protocol seam and reads through it; the synchronization is the integration owner's to add when
wiring the real classifier in.

# ⛔ WIRING GATE: what must be true BEFORE a composition root constructs this coordinator

**Nothing in production constructs `MeetingTranscriptionCoordinator` today.** `MeetingEngine`
still defaults to `NullMeetingTranscriptionCoordinator`, and that is correct for now: the seam and
its adapters have never run against a real model or real audio on any machine, because neither
exists in the environment they were built in.

This section exists so that state cannot be left by accident. **Do not wire this seam until every
item below is resolved.** None is a nice-to-have. Items 1 and 2 have their own `GATE ITEM`
sections immediately below; item 4 has its own entry further down ("B4.2's dictation-priority
admission is FluidAudio-only"); items 3 and 5 are covered in the per-file entries they name.

| # | Prerequisite | Status | Why it blocks wiring |
|---|---|---|---|
| 1 | Real-audio / real-model smoke testing of all three adapters | **PARTIALLY CLOSED** (FluidAudio path) by `RealModelSmokeTests.swift`, 2026-09-06; **OPEN** for transcribe-cpp | FluidAudio transcription and diarization now have real model-load and real-inference evidence with measured numbers (see GATE ITEM 1 below). transcribe-cpp's `.segment` timestamp support and resource use are still untested — no transcribe-cpp model was available on the machine that closed the FluidAudio half. |
| 2 | B2 residual: the admission-to-inference window (below) | **OPEN** | A dictation Mark starts in that window still queues behind a meeting chunk. Closing it needs shared admission with the dictation path, which is an upstream change nobody has authorised. |
| 3 | A dictation-priority closure that is actually correct | **OPEN** | `MeetingAsrRuntimeAccess.isDictationActiveOrPending` has no default by design. Admission is only as good as what the composition root passes; passing `{ false }` silently disables item 2's mitigation entirely. |
| 4 | transcribe.cpp concurrent-session safety | **OPEN** | Unlike FluidAudio, that path runs meeting and dictation inference concurrently rather than serialised, and whether that is safe or affordable on a 16GB M2 Pro is unmeasured. |
| 5 | A diarizer `loadOperationTimeout` chosen from data | **OPEN, now DATA-INFORMED (not validated)** | The 30s default was picked without measurement; `RealModelSmokeTests.swift` (2026-09-06) took the first real-hardware measurement -- a genuine cold network download + CoreML load + diarize completed in ~17.5s, TWO PARALLEL workers contending for the same download and disk cache, on Mark's Mac mini's connection. It did not blow the ceiling on that one occasion. That is one uncontrolled data point about this Mac's broadband and disk contention, not proof the constant is correctly chosen -- it does not test a slow or metered connection, a single-worker load, or a worst-case contention scenario, so the constant itself is left unchanged and this row stays OPEN. Do not read "did not time out once" as "30s is validated". |
| 6 | The capability must not expose an eviction-capable `AsrManager` | **CLOSED** by `MeetingAsrSharing.swift` in round 6 | Kept as a row rather than deleted, because the history is the point. Round 5's capability returned the live shared `AsrManager`, and `AsrManager.cleanup()` is ordinary public FluidAudio API that nils every loaded model: `access.borrowLoadedManager()?.manager.cleanup()` compiled from any meeting-side file with zero diagnostics. Closed by inversion — the capability now performs the transcription on the owning side and returns a fork-owned value receipt, so the meeting side never holds a manager. Enforced by `MeetingCapabilityReturnValueEvictionAttack.swift`, `MeetingReceiptMutatingApiAttack.swift` and `MeetingSeamCannotNameAsrManagerAttack.swift`. |
| 7 | A computed manager-returning member on the seam's types would FAIL OPEN | **OPEN** | The guards enforce the STORED surface only: a new stored property or outcome case stops the build, but `extension MeetingAsrRuntimeAccess { var liveManager: AsrManager { ... } }` compiles and nothing catches it. `Mirror` does not see computed properties, the memberwise initializer gains no parameter, and Swift has no exhaustiveness rule over a method list. An AST/source-signature guard would close it and was deliberately NOT built (see below). **Re-read the seam's types for computed members before wiring.** |

## The seam's error channel is not type-constrained (safe today by inspection)

Source: `VoiceInk/Features/Meetings/Transcription/MeetingAsrSharing.swift`
(`MeetingChunkTranscriptionOperation`).

The capability's SUCCESS channel is constrained to fork-owned value types: the operation returns
`MeetingChunkTranscriptionOutcome`, and negative controls destructure every payload to prove none
of it is or contains an `AsrManager`. The ERROR channel has no equivalent constraint. The
operation is `throws`, so it can throw `any Error`, and nothing in the type system stops a future
error type from carrying a manager or the service across the seam.

**Safe today, by inspection rather than by type.** Everything on the factory's path that can throw
is `AsrManager.transcribe`, which throws FluidAudio's own `ASRError` and decoding errors; none of
them embed the manager. Raised by cross-vendor review in round 7, which also found no current
leaking path.

**Deliberately not fixed.** Constraining it means a typed-throws boundary plus error mapping
across the seam, which is a larger change than the residual justifies for a channel that is empty
today. Recorded here so it is a decision rather than an oversight.

**Would need revisiting** if the operation ever grows a second throwing call, or if a fork-owned
error type is introduced on this path: at that point map errors to a fork-owned enum rather than
letting `any Error` through.

Item 7 is the honest residual of rounds 7 and 8. Round 7's production comment claimed "a new
member" fails closed; that was true of STORED properties and false of computed ones, and the guard
suite admitted as much in its own text while the comment did not. Both now say the same thing. The
AST guard that would close it was ruled out for this PR as bespoke test infrastructure whose own
correctness would need verifying, which rots when the source layout changes, on a coordinator
nothing constructs yet: a precise narrow claim beats a broad one a future reader would trust
further than it deserves. That trade is only acceptable *because* nothing is wired, which is
exactly why it sits on this gate rather than in a comment.

Item 6 is recorded as CLOSED rather than removed because four successive designs of that boundary
were each defeated in one line, and the last one was defeated by an attack nobody had listed: the
suite tested routes to the *service* while the capability handed out the *manager* through its own
front door. A future editor who re-exposes any FluidAudio runtime object across this seam should
see that history before deciding it is safe.

Items 2, 3 and 4 all reduce to the same exposure and the same person's daily flow: **Mark dictates
with local Parakeet every day, and none of the mitigations above have been measured against real
inference times.** A meeting chunk that degrades costs one chunk's segment timings. A dictation
that stalls costs him the thing he was in the middle of saying. That asymmetry is why this gate is
a gate and not a checklist.

## GATE ITEM 1 -- Real-audio / real-model smoke testing

**PARTIALLY CLOSED for the FluidAudio path (2026-09-06), OPEN for transcribe-cpp.** See
`Tests/VoiceInkTests/Features/Meetings/Transcription/RealModelSmokeTests.swift` — the one file in
this tree that constructs a real `FluidAudioTranscriptionService` (real Parakeet v3 CoreML model)
and a real `FluidAudioMeetingDiarizer` (real `DiarizerManager`) and drives them through this
fork's own `MeetingTranscriptionCoordinator` / `FluidAudioMeetingSegmentTranscriber`, never
FluidAudio called directly, against real audio. Gated on the existing `VOICEINK_CI` idiom
(`AudioGraphExceptionBridgeTests.swift`'s mechanism, reused verbatim) plus its own
model/audio/network availability checks, so it skips cleanly everywhere those aren't present —
proved both ways: skipped under `TEST_RUNNER_VOICEINK_CI=1`, executed and green without it.

What that file's two tests actually establish, with real numbers from Mark's own Mac mini
(Mac14,12, M2 Pro, 16GB) on 2026-09-06:

- **`FluidAudioMeetingSegmentTranscriber` transcribes real speech through the coordinator.**
  Source audio: one of Mark's own real dictation recordings from
  `~/Library/Application Support/com.prakashjoshipax.VoiceInk/Recordings/` (16kHz mono, ~15s),
  copied read-only, never moved or modified. Produced a real 24-word, 47-segment transcript (one
  segment per sub-word token, matching this adapter's documented mapping) via
  `MeetingTranscriptionCoordinator.transcribeMeetingChunk`, not FluidAudio directly.
- **Actual resource measurement**, first data point ever taken: peak RSS during model load +
  transcription measured at ~202-253MB across two runs (well within a 16GB M2 Pro's headroom).
  Not yet measured for transcribe-cpp (no transcribe-cpp model was available to test with).
- **Model load and per-chunk latency.** Reported here as two SEPARATE, non-comparable
  observations, per the fix round below (2026-09-06) that corrected an earlier draft of this
  entry which wrongly combined them into a "cold vs. warm" ratio:
  - The FIRST time these exact models were loaded via this pinned FluidAudio version on this Mac,
    the whole test (model load + a full ~15s-recording transcript + two 4s-chunk transcriptions,
    across TWO PARALLEL test workers, plus Swift Testing's own per-test overhead and whatever
    inter-worker contention two workers touching the same CoreML/disk state at once costs)
    took **21.8s / 36.4s in aggregate**. That number bundles at least five confounded costs and
    has no per-step breakdown — it is reported only as "first run, aggregate wall time", not as a
    measurement of model load in isolation.
  - A later, separately-instrumented run — same models, but no longer verifiably the first load
    on this Mac, since prior runs (including the one above) had already primed whatever
    persistent state macOS's CoreML/ANE stack keeps between process launches — measured
    `first-load-in-process-seconds` (named for exactly what it is, not `cold-model-load-seconds`)
    at 0.13-0.58s, a full ~15s recording transcript at 0.14-0.23s, and a representative 4s chunk
    at 0.10-0.16s per call.
  - **No ratio is claimed between these two numbers.** They measure different things (a bundled
    aggregate vs. an isolated component) under different, unverified cache states. An earlier
    draft of this entry said "the cold/warm gap is roughly two orders of magnitude" and that claim
    was WRONG and has been deleted, not softened — it was flagged in review before being repeated
    to Mark as a finding. If a real cold/warm ratio is wanted later, it needs controlled SERIAL
    measurements of the same isolated interval with a stated, verified cache state (e.g. confirm
    no prior process on this Mac has ever loaded this model version, or deliberately clear
    whatever cache backs the speedup first) — not two numbers this task already had lying around.
- **`FluidAudioMeetingDiarizer`'s real `DiarizerModels.load`/`performCompleteDiarization` path
  runs to completion within the 30s `loadOperationTimeout` default, measured but NOT validated
  against it.** No real multi-speaker system-audio recording exists on this machine, so the audio
  here is SYNTHESIZED (disclosed in the test file): two distinct macOS `say` voices reading
  different sentences back to back — proves the real load/run path executes and returns a real
  `DiarizationResult`, not that diarization accuracy has been validated. The diarizer's actual
  model (`FluidInference/speaker-diarization-coreml`) was NOT present on this Mac before this test
  first ran (see the premise-verification note below) and had to download over the network for
  real. That real cold download + load + diarize completed in ~17.5s / 2.7s across two parallel
  test workers **contending with each other for the same network download and disk cache at the
  same time** — an uncontrolled measurement of Mark's broadband and disk contention as much as of
  CoreML, not a clean single-worker timing. It stayed under the 30s ceiling on this run, on this
  Mac, on this network, with two workers competing for the same download. **That is evidence the
  ceiling did not bite here, not evidence the constant is correctly chosen.** Gate item 5 stays
  OPEN precisely because of this — see that row's own wording, corrected in the same fix round to
  stop implying the 30s default is validated. The warm reload (files already on disk from the
  download above) took ~0.46-0.53s across several later runs. Once the diarizer test's fix-round
  correction (below) made a `loadTimedOut` a hard test failure rather than a silently-recorded
  pass, this same 30s default was verified to still pass on this Mac (see "Fix round" section).

**Premise check that surfaced a real correction to how this project's own Application-Support
model cache was understood.** A pre-existing `~/.cache/huggingface/hub/models--aufklarer--Pyannote-Community-1-CoreML`
directory on this Mac looked at first glance like it might already satisfy the diarizer's model
dependency. It does not: `FluidAudioMeetingDiarizer`'s production init resolves
`DiarizerModels.defaultModelsDirectory()` → `~/Library/Application Support/FluidAudio/Models/<Repo.diarizer.folderName>`,
and `Repo.diarizer` is `FluidInference/speaker-diarization-coreml` — a different HuggingFace repo
from a different org than the cached `aufklarer/Pyannote-Community-1-CoreML` (itself a mirror of
`pyannote/speaker-diarization-community-1`). FluidAudio never reads the `huggingface.co/hub` cache
convention at all; it has its own cache layout under Application Support. The `aufklarer` cache
was and remains unused by this codebase's pinned FluidAudio version — this test's real diarizer
run downloaded `FluidInference/speaker-diarization-coreml` fresh into
`~/Library/Application Support/FluidAudio/Models/speaker-diarization/`, confirmed present after
the run.

**Still OPEN: `.segment` timestamp support, per transcribe-cpp catalog model.**
`segment-timing-design.md` §B and `FORK-PATCHES.md` both flag this as unresolved: whether
`cohereTranscribe` or `senseVoiceSmall` (or both, or neither) actually populates
`Transcript.segments` when asked for `timestamps: .segment`, versus silently resolving to a
coarser kind. Requesting `.segment` and getting back an empty `segments` array is NOT a crash —
it silently degrades to `TranscribeCppMeetingSegmentTranscriber`'s own empty-segments fallback
(one flat, zero-duration segment) — so this needs an explicit real-audio check, not just "it
didn't throw." NOT addressed by `RealModelSmokeTests.swift`: no transcribe-cpp model was
downloaded or available to test against on this Mac, and it was out of scope for the task that
produced that file. This sub-item, and transcribe-cpp's own resource measurement, are why gate
item 1 is PARTIALLY closed rather than fully closed — whoever picks this up next should extend
`RealModelSmokeTests.swift` (or add a sibling file) with a real transcribe-cpp model rather than
re-verify the FluidAudio path again.

**Fix round (2026-09-06), after independent review returned CHANGES REQUESTED with three blocking
findings against the first version of `RealModelSmokeTests.swift`.** What the review correctly
kept (not regressed): Parakeet inference genuinely routes through
`MeetingTranscriptionCoordinator`/`FluidAudioMeetingSegmentTranscriber`, not FluidAudio directly;
the FOLLOWUPS.md edits above are replacements of superseded text, not quiet discards; "PARTIALLY
CLOSED" stays correctly bounded to the FluidAudio path; scope stays clean (zero production,
`VoiceInk/App/`, or upstream changes). Three things were wrong and are now fixed:

1. **A missing prerequisite produced a green suite with nothing exercised, and a comment claimed
   otherwise.** Both tests used `.disabled(if:)` for their prerequisites, so a machine with no
   Parakeet model, no usable recording, or no diarizer model/network produced SKIPPED tests and a
   passing build — correct behavior for an ordinary run, but the file's own comment claimed this
   avoided "silently reporting green with nothing exercised", which is false: it is exactly that,
   by design, for convenience. Fixed by adding an explicit GATE-RUNNING MODE, engaged with
   ```
   TEST_RUNNER_REALMODEL_SMOKE_GATE_MODE=1 xcodebuild test -project VoiceInk.xcodeproj \
     -scheme VoiceInk -destination 'platform=macOS' -only-testing:VoiceInkTests/RealModelSmokeTests
   ```
   (see the "Gate-running modes" section at the top of this file for the repo-wide canonical
   list): with that set, a missing prerequisite is no longer grounds to skip, and the test runs
   for real and fails loudly instead. **A ROUND-3 REVIEW FINDING, since fixed:** the file's header
   comment and this very paragraph originally told the reader to "Set `REALMODEL_SMOKE_GATE_MODE`"
   -- the UNPREFIXED name, which only the already-launched test process itself reads via
   `ProcessInfo`. Setting that unprefixed form on the outer `xcodebuild` invocation does nothing:
   `xcodebuild test` launches the test host through a LaunchServices-mediated path that does not
   inherit the invoking shell's environment except for `TEST_RUNNER_`-prefixed variables (which it
   forwards with the prefix stripped), so a caller who followed the original wording ran ordinary
   skip-mode by another name, watched everything skip, and would have read the resulting green run
   as proof the gate had executed -- the exact false assurance this mechanism exists to prevent,
   reintroduced through its own documentation. Both the file's header and this paragraph now give
   the correct `TEST_RUNNER_`-prefixed external command above, and the point where
   `isGateRunningMode` is defined in the source carries its own one-sentence warning against the
   unprefixed name, so a reader who only looks at the `ProcessInfo` line still cannot miss it.
   Proof both ways (correct prefixed form fails on a genuinely missing prerequisite; the wrong
   unprefixed form skips and reports green on the SAME missing prerequisite) is in this task's
   report, "Round 3" section. Separately, the diarizer test previously required network
   reachability unconditionally; it now only requires it when the diarizer's model is not already
   cached under FluidAudio's own Application Support directory
   (`RealModelAvailability.diarizerModelsPresent`), so a machine with the model already downloaded
   runs offline.
2. **The diarizer test PASSED when the production path timed out.** `loadTimedOut` was caught,
   recorded as a diagnostic, and swallowed — the test could pass having loaded no model, run no
   diarization, and produced no `DiarizationResult`, while its own name claimed otherwise. Fixed:
   any error, `loadTimedOut` included, is now recorded for diagnostics and then RETHROWN, failing
   the test. Proved both directions on this Mac, verbatim in this PR's report: forcing
   `FluidAudioMeetingDiarizer(loadOperationTimeout: 0.0)` made the test FAIL
   (`outcome=failed error=loadTimedOut`, ~0.08-0.1ms elapsed); reverting to the real
   `FluidAudioMeetingDiarizer()` (30s default) made it PASS again (`outcome=succeeded segments=2`,
   ~0.46-0.53s elapsed, model already cached from the prior run).
3. **The "cold vs. warm" ratio was not a real ratio.** See the "Model load and per-chunk latency"
   bullet above, rewritten in this fix round. The "roughly two orders of magnitude" claim compared
   a whole-test aggregate (two parallel workers, four operations, test overhead, and
   inter-worker contention all bundled together) against separately-instrumented per-step timings
   from a later run, and was deleted rather than hedged. `cold-model-load-seconds` was renamed to
   `first-load-in-process-seconds`, which is what it actually measures — the first load in that
   test process, not a verified cold CoreML/ANE cache state.

Also fixed, cheap and non-blocking: `MetricsSink` (the file this suite's real numbers are read
back from) now prefixes every line with a per-process run identifier
(`[run=<pid>-<short-uuid>]`) and appends via a raw `open(..., O_APPEND)` file descriptor instead of
`FileHandle.seekToEndOfFile()` + `write()`, so concurrent test workers writing to the same path
cannot produce a torn or silently-mixed line, and any number can be traced to the exact run that
produced it.

None of this can be substituted with more unit tests against injected fakes — the whole point is
verifying the REAL backend/model behavior the fakes stand in for.

## GATE ITEM 2 -- B2 residual: one `await` still separates admission from inference

Source: `VoiceInk/Features/Meetings/Transcription/FluidAudioMeetingSegmentTranscriber.swift`
(`transcribe(chunkAt:)`, `reconfirmDictationIsIdle()`).

**Where this now lives (round 6).** The sequence moved from
`FluidAudioMeetingSegmentTranscriber.transcribe(chunkAt:)` into the capability's operation in
`MeetingAsrSharing.swift`, because the meeting side no longer holds an `AsrManager` to run it
with. The property is PRESERVED and slightly improved: the whole sequence now runs on
`@MainActor`, so the final check is a synchronous statement rather than needing its own hop, and
round 5's `await reconfirmDictationIsIdle()` suspension is gone. Exactly one `await` still
separates the final check from inference.

**The exact remaining suspension.** The operation runs:

1. Early priority check + borrow — both synchronous, on `@MainActor`, no `await` between them.
2. `await manager.decoderLayerCount` — hop into the `AsrManager` actor and back. **Above the
   final check**; round 4 had it below, which is the window review found then.
3. The final admission decision — **synchronous** on `@MainActor` (round 5 needed an `await` here
   to hop back; round 6 does not, because it never left).
4. `await manager.transcribe(url, decoderState:&decoderState)` — **the residual.** One hop, from
   `@MainActor` into the `AsrManager` actor.

Nothing else suspends between (3) and (4): `TdtDecoderState.make(decoderLayers:)` is a synchronous
static function on a `Sendable` struct.

**The interleaving that loses.** Our task resumes on `@MainActor` at (3) having decided dictation
is idle, then calls `transcribe`, which enqueues work on the `AsrManager` actor. If a dictation
enqueues on that same actor after our check returned but before our call lands, the dictation is
behind us in the actor's queue and runs second.

**The user-visible consequence.** Mark starts a dictation in that window and it does not begin
transcribing until the meeting chunk's inference finishes. Latency, not corruption: no data is
lost and no model is evicted. The magnitude is one chunk's inference time, **which has never been
measured** (gate item 1).

**Why it cannot be closed from this side.** The check runs on `@MainActor`; the inference runs on
the `AsrManager` actor. Any sequence that decides in one isolation domain and acts in another has
a gap between them, and no reordering within this file removes it — round 5 already hoisted
everything hoistable, which is why exactly one `await` remains rather than three. Closing it means
making the admission decision *inside* the actor that serialises both flows, i.e. **shared
admission with the dictation path**. That is a change to code this fork merges from a
daily-pushed upstream forever, so it is deliberately **not attempted here**: it is Mark's call.

**HARD PREREQUISITE.** Do not wire this coordinator until this is either closed by shared
admission or explicitly accepted by Mark with a measured inference time in hand.

## The meeting transcription seam cannot load a Parakeet model, only borrow one

Source: `VoiceInk/Infrastructure/Providers/Transcription/FluidAudio/FluidAudioTranscriptionService.swift`
(`borrowedAsrManager()`), `VoiceInk/Features/Meetings/Transcription/FluidAudioMeetingSegmentTranscriber.swift`.

Fix round 3 for review finding B1 removed the meeting seam's ability to trigger a model load,
because being able to load was exactly what let a meeting run `cleanupLoadedManagers()` --
including `asrManager.cleanup()` -- underneath a live dictation. The accessor is now synchronous,
argument-less and calls nothing, so the bad interleaving is not expressible rather than merely
unlikely.

**The cost, which is real and is a composition-root requirement, not a bug:** if dictation has no
model loaded when a meeting chunk is transcribed, `FluidAudioMeetingSegmentTranscriber` throws
`MeetingSegmentTranscriberError.sharedModelNotLoaded` and `MeetingTranscriptionCoordinator`
degrades that chunk to its flat-fallback path (a single zero-duration segment, which
`MicTurnNormalizer` sentence-splits). It never loads a model to rescue itself.

**What the composition root must therefore do** when one is finally built (nothing constructs a
non-Null coordinator today): ensure the user's selected FluidAudio model is loaded through the
EXISTING dictation API, `FluidAudioTranscriptionService.loadModel(for:)`, at meeting start --
exactly as `VoiceInkEngine` already does at recording start (`VoiceInkEngine.swift`, the
`@MainActor` preload block after `scheduleVoiceInkRefinePreparation`). That call belongs on the
dictation side of the seam, where a version switch is the user's own intent, not on the meeting
side, where it is an eviction of somebody else's model.

## Dictation can still evict a model a meeting is using (the deliberate asymmetry)

Source: same files. B1's fix is one-directional on purpose. A meeting can no longer evict
dictation's manager. Dictation switching models still runs `cleanupLoadedManagers()` and can nil
the CoreML models out of an `AsrManager` a meeting chunk is mid-way through using.

Not fixed, and not an oversight: protecting Mark's daily dictation outranks a meeting chunk, and
the two outcomes are not comparable. A meeting chunk that fails degrades to the flat-fallback
transcript and the recording is already persisted; a dictation that fails is the thing Mark was
in the middle of saying. Closing the reverse direction properly would need a lease/refcount on
`FluidAudioTranscriptionService`'s manager lifecycle (the shape `OfflineTranscribeCppService`
already has via `activeTranscriptionCount`), which means changing existing upstream logic rather
than adding to it -- past the authorised touchpoint budget, and a change that could make
dictation's own model switch block on a meeting.

**Would need revisiting** if meetings ever become a foreground feature people run for hours
alongside heavy dictation use, at which point the lease is worth its upstream cost.

## An expired diarizer load keeps running alongside its replacement -- CAPPED in round 4

Source: `VoiceInk/Features/Meetings/Transcription/FluidAudioMeetingDiarizer.swift`
(`expireLoad`, `finishLoad`, `maxOutstandingAbandonedLoads`).

**This entry previously said "two model loads can be in flight at once" and that was an
understatement, which review caught (B4.3).** A PERMANENTLY stuck load is abandoned and never
returns, so under round 3 every later `MeetingEngine.stop()` could start yet another
cancellation-blind CoreML load: unbounded accumulation of memory and CPU across a working day of
meetings. The UUID quarantine prevented stale STATE from being installed; it did nothing about
stale RESOURCES.

**Fixed by a circuit breaker.** `expireLoad` increments `outstandingAbandonedLoads`; a load only
decrements it by actually reporting back (`finishLoad` with a stale id, whether it succeeded or
threw). While the count is at `maxOutstandingAbandonedLoads` (1), `startLoadIfNeeded` throws
`.loadAbandonedAndStillOutstanding` BEFORE creating any task, so a refused attempt costs nothing
and does not wait out another deadline. At most two loads can ever be in flight: one live, one
abandoned, no matter how many meetings end.

If the abandoned load never returns, the breaker stays open and diarization fails fast for the
rest of the session. That is the intended outcome, not a regression: the alternative is the
unbounded accumulation this fixes, and a failed diarization is recoverable (audio and segments
are already persisted by the time `stop()` reaches this call).

**Would need revisiting** if real-hardware measurement (see the smoke-test prerequisite above)
shows genuine `DiarizerModels.load` hangs are common rather than pathological, at which point the
right answer is probably a user-visible signal that diarization is disabled for the session,
rather than a different cap.

## A diarizer waiter cancelled before it registers waits for the ceiling, not for its cancel

Source: `VoiceInk/Features/Meetings/Transcription/FluidAudioMeetingDiarizer.swift` (`join`).

`withTaskCancellationHandler`'s `onCancel` can fire before the enclosing
`withCheckedThrowingContinuation` has stored the waiter, in which case `cancelWaiter` finds no
entry and the call waits for the load generation to end normally instead of returning at once
with `CancellationError`. Only reachable for a caller whose Task is already cancelled on entry.

Cost is latency, not a hang, and specifically because of B2's fix: the generation is bounded by
`expireLoad` no matter what the loader does, so the worst case is one `loadOperationTimeout`
(default 30s). Left as is -- a pre-registration cancellation check has its own race and is no
simpler. Disclosed here so it is a decision rather than an oversight.

## `cleanup()` remains internal on `FluidAudioTranscriptionService`

Source: `VoiceInk/Infrastructure/Providers/Transcription/FluidAudio/FluidAudioTranscriptionService.swift`,
`VoiceInk/Features/Meetings/Transcription/MeetingAsrSharing.swift`.

Round 3 claimed the meeting seam could not evict dictation's model partly because the
eviction-capable methods were `private`. Review found that false (B4.1): `cleanup()` is
`internal`, so any file in the app target could compile `await service.cleanup()`.

Round 4 fixed the seam by capability narrowing rather than by changing upstream: the meeting
transcriber is handed `any MeetingAsrManagerBorrowing` (one getter) and stores a closed-over
`@MainActor @Sendable` capability, so `cleanup()`, `loadModel(for:)` and the concrete type are
not nameable there at all. Five negative-control attacks enforce it.

**What is still CONVENTIONAL, stated as such:** `cleanup()` is unchanged and still `internal`, so
app-target code that obtains the CONCRETE service (from `TranscriptionServiceRegistry`, say) can
still call it. Making it `private` would mean changing its existing upstream callers, which is
larger than the accessor-sized touchpoint that was authorised. What is enforced is that the
meeting seam is never given that concrete type; what is conventional is that a future meeting
file does not reach around the capability to fetch the service itself.

**Would need revisiting** if the meeting seam ever grows a second component that needs the
service, at which point the right move is probably to ask for a third upstream touchpoint and
make `cleanup()` `private` with an explicit lifecycle owner, rather than widen the capability.

## B4.2's dictation-priority admission is FluidAudio-only, and transcribe.cpp's exposure is different and unverified

Source: `VoiceInk/Features/Meetings/Transcription/FluidAudioMeetingSegmentTranscriber.swift`
(admission control) versus `TranscribeCppMeetingSegmentTranscriber.swift` (no admission control).
Noticed while fixing B4.2; not raised by review, and deliberately NOT "fixed" here, because the
transcribe-cpp borrow path was reviewed and accepted and changing it would be scope I was not
given.

The two seams share a model in genuinely different ways, so B4.2's hazard does not transfer:

- **FluidAudio:** `AsrManager` is a `public actor`, so meeting and dictation inference are
  mutually serialized and a dictation started after a meeting chunk QUEUES behind it. That is the
  latency defect B4.2 fixes with admission control.
- **transcribe.cpp:** `OfflineTranscribeCppService.transcribe` holds no lock across inference. It
  calls `nativeModel.session()` per chunk and runs that session; `Model.session()`
  (`Transcribe-cpp-swift/Sources/TranscribeCpp/Model.swift:43`) creates a FRESH native session
  from the shared model pointer on each call. So a meeting and a dictation do not queue behind
  each other there; they run concurrently.

**What is therefore unverified, and belongs with the real-model smoke tests above:** whether
running two concurrent sessions against one shared `Model` is thread-safe in this build of
transcribe.cpp, and what the CPU and memory cost of doing so is on a 16GB M2 Pro. The one-model
many-sessions API shape is consistent with concurrent use being intended, and the meeting seam
uses exactly the same `session()`-per-chunk pattern dictation already uses, so this introduces no
new pattern -- but "the API looks designed for it" is not evidence, and nothing in this
environment can produce evidence without the real GGUF model present.

**Decide when that smoke test runs:** if concurrent sessions turn out to be unsafe or expensive,
the fix is the same admission-control shape B4.2 already establishes, applied to
`TranscribeCppMeetingSegmentTranscriber`. If they are fine, transcribe.cpp is simply the better
sharing model of the two and no change is needed.

## `StreamingVadControllerTests.serializesChunkProcessing` flaked once on CI (2026-09-05) — FIXED

`Tests/VoiceInkTests/Features/Meetings/Transcription/StreamingVadControllerTests.swift`. Failed on
CI run **33965544410** (attempt 1) during PR #16 round 8, in a change that touched only comments,
two test files, a negative control, the verifier script and this file. Evidence it was a flake and
not a regression:

- **The same commit (`01e85ce7`) passed on attempt 2**, with no code change between attempts.
- The change in flight touches nothing this test exercises: `StreamingVadController` and its tests
  were not modified, and the round-8 diff under `VoiceInk/` is comment-only.
- It passed locally in the same round at **0.568s**.
- The CI failure took **2.324s** against a **2-second** deadline, i.e. it exhausted the wait and
  then failed the count assertion. That is the signature of the deadline expiring, not of a
  behavioural fault.

**Root cause.** The test enqueues 10 chunks processed serially at 25ms each (~250ms of work) and
polls for completion under a 2s ceiling. The ceiling is a hang guard, not a latency assertion, but
it was only ~8x the expected work, and a loaded GitHub runner stretched the real duration past it.

**Fix.** Raised that ceiling and its sibling in `buffersChunksBeforeStateReady` to 10s, with the
reasoning recorded at both sites. This cannot mask a real defect: the assertions
(`processedCount == 10`, `maxConcurrentCount == 1`) are unchanged, a genuine serialization
regression still fails on `maxConcurrentCount` immediately, and a genuine hang still fails after
10s. It is the same idiom this file already prescribes in the `RouteAwareMeetingMicRecorderTests`
audit above: extend the wait to cover the state actually being asserted, never a fixed sleep.

**Not fixed here:** the remaining 1s/2s deadlines in that file (lines ~211-258) gate on a single
in-flight operation rather than N serialized ones, so their margins are far wider. If either ever
flakes, apply the same reasoning rather than assuming a behavioural cause.

## `TranscriptedAudioExporter` can only ever populate `playback.m4a`, until this fork retains isolated channels

Source: `VoiceInk/Features/Meetings/Export/TranscriptedAudioExporter.swift` (that file's own
header carries the full evidence trail); `VoiceInk/Features/Meetings/Capture/
MeetingRecordingWriter.swift`; `~/code/transcripted`'s `RecordingAudioArchiver.swift` and
`MeetingAudioStorageManager.swift` (Mark's real, separate Transcripted app).

Real Transcripted's audio directory (`meetings/audio/<stem>_audio/`) holds up to three files:
`microphone.m4a` (isolated mic capture), `system_audio.m4a` (isolated system-audio-tap
capture), and `playback.m4a` (a derived, voice-activity-gated mix of the first two, produced by
an async maintenance pass, never at capture time, and only when BOTH are present and usable —
confirmed by reading `createPlaybackMixIfNeeded`). This fork's `MeetingRecordingWriter` has no
equivalent to the first two: it mixes mic and system PCM together AS THEY ARRIVE into one mono
16kHz file and never retains either channel in isolation. So `TranscriptedAudioExporter`, fed
this fork's only real capture output, can honestly write only `playback.m4a` — writing the same
combined bytes under `microphone.m4a` or `system_audio.m4a` would claim an isolated capture
that was never made, which is worse than the gap.

**This produces a shape never observed in any real Transcripted directory**: in all 33 real
examples that have `playback.m4a` at all, it is accompanied by both its sources. A
fork-produced directory with `playback.m4a` alone is a combination Mark's existing tooling has
never had to parse before. Nothing here proves that tooling handles it gracefully — this task
verified the WRITER's honesty, not every READER's tolerance for a Transcripted-shaped directory
that only ever has one file in it.

**Would need revisiting**, together, if this fork ever wants full parity: (a) retaining mic and
system in isolation somewhere in the capture pipeline (a `MeetingRecordingWriter` redesign, or
a second writer alongside it — out of scope for that file today), (b) re-deriving a real
`playback.m4a` from those two rather than reusing the already-mixed file for that slot, and (c)
confirming Mark's Transcripted MCP / Anytype sync / other tooling actually reads a
`playback`-only directory without assuming the other two exist. None of that is this file's
job: it is Phase 3's *export* leg, additive and unwired (see the `retainRecording stays false`
entry above for why wiring an actual caller is separately out of scope too), not a capture
redesign.

## Stale `TranscriptedAudioExporter` staging and backup directories are never swept

`TranscriptedAudioExporter.export` stages a re-export in a sibling directory and commits it by
renaming, which is what stops a failed re-export destroying a good prior export of audio nobody
can re-record (see that file's header, "ATOMICITY, AND ITS EXACT LIMITS"). The cost of that
shape is that a failure can leave a dot-prefixed scratch directory behind next to the
destination:

- `.TranscriptedAudioExporter-staging-<uuid>/` — a complete or partial staged export, when
  removing it after a failure itself failed, or when it was deliberately KEPT because the
  commit ended in `ExportError.rollbackFailed` and a human is recovering by hand.
- `.TranscriptedAudioExporter-backup-<uuid>/` — the previous good export, when the process was
  killed in the window between `old -> backup` and `staging -> final`, or when the restoring
  rename failed. In the second case the path is carried out in the thrown error, with the
  recovery `mv` spelled out in `errorDescription`; in the first case nothing survives to report
  it, because a SIGKILL runs no code.

**This is debris, not data loss, and the distinction is the reason nothing is built here.** The
directories are dot-prefixed, uniquely suffixed, carry the type's own name, and are never at a
destination path, so nothing reading Transcripted's layout sees them. The audio inside a
`-backup-` one is complete and unmodified: it is in the wrong place, not gone.

**Deliberately NOT built in this PR**, per the review ruling on it: a debris-reaping subsystem
is a different piece of work from the data-loss fix, and bolting one on unreviewed to a change
whose whole point is not deleting things carelessly would be the wrong trade. What was done
instead is narrower and matches what the code actually delivers: the header's old unconditional
claim that no partial output remained "anywhere, ever" was corrected to name this residue, and
every best-effort cleanup now LOGS the path it failed to remove
(`Logger(subsystem: "com.hainesy.voiceinkmeetings", category: "TranscriptedAudioExporter")`)
instead of discarding the result with `try?`, so residue is observable rather than invisible.

**What a sweep would have to get right**, if one is ever wanted: it must not delete a `-backup-`
directory it cannot prove is orphaned, since that is a real recording; it needs an age threshold
well clear of the longest legitimate export; and it has to run somewhere with a view of the
destination root, which today is nowhere, because this exporter still has no caller at all (see
the `retainRecording stays false` entry).

**A related, separate limit worth recording next to this one:** the commit is two renames, and
two renames are not one atomic unit. Darwin's `renameatx_np` with `RENAME_SWAP` would collapse
them into one atomic syscall and close the kill window entirely. It was NOT adopted, on purpose:
the real destination is under `~/Library/CloudStorage/OneDrive-ATEME/`, a File Provider volume
whose `RENAME_SWAP` support cannot be verified from this fork's test environment, and an
unsupported filesystem returns `ENOTSUP`. Shipping it would mean shipping it AND the two-rename
fallback, leaving the window in place on precisely the volume that matters, in exchange for a
second untested code path. Worth revisiting only with a real measurement on that volume.

## `FaultInjection`'s data-only invariant: the barrier covers directly stored closures only

`TranscriptedAudioExporter.FaultInjection` is the value `export` accepts to force the recovery
branches in `commit` to fail. It carries NO CODE on purpose: an earlier design was a struct of
`@Sendable` closures, and review defeated it in one line three ways, each letting `export` report
SUCCESS with the previous export destroyed. `scripts/negative-controls/TranscriptedAudioExportSeamAttacks.swift`
pins six exact expressions that must not compile.

**Six expressions are not the invariant, and review said so.** Someone adding a differently-named
closure-bearing field -- `operationOverride`, say -- leaves all six diagnostics intact and the
control runner passes. That gap was investigated rather than accepted, and the investigation found
the invariant is already enforced for free:

- `FaultInjection` declares `Equatable`, and Swift only SYNTHESISES `Equatable` when every stored
  property is itself `Equatable`. A closure is not.
- Verified empirically, not reasoned about: planting `var operationOverride: (() -> Void)?` on the
  type and running a full `xcodebuild` (not `-typecheck`) gives
  `error: type 'TranscriptedAudioExporter.FaultInjection' does not conform to protocol 'Equatable'`.
- So a DIRECTLY STORED closure-typed property fails to build today, under any name.

Two controls pin the conformances: `TranscriptedAudioExportSeamEquatableBarrierAttack.swift`
(must-not-compile) and `TranscriptedAudioExportSeamSendableBarrierAttack.swift` (must-warn).

**THE GAP THAT REMAINS, in full, because an earlier version of this entry recorded only the last of
these four and read as though the barrier held for the whole class.** It does not. Each of these
re-introduces an executable seam while leaving synthesised `Equatable` intact AND both barrier
controls green, so nothing goes red:

1. **An `Equatable`, `@unchecked Sendable` wrapper type containing a closure**, stored as a field.
   The stored property is `Equatable`, so synthesis is untroubled.
2. **A property wrapper** whose stored backing type is `Equatable` while its `wrappedValue` is a
   closure. The same, one level of indirection further.
3. **A computed closure property, or a method** -- including one added from an extension. No stored
   property is involved, so synthesis never looks at it.
4. **A hand-written `static func ==`**, which suppresses synthesis outright, after which even a
   plainly stored closure field compiles again.

(1) and (2) restore a fully executable `operationOverride`-equivalent. So the accurate summary is
that synthesised `Equatable` blocks the OBVIOUS re-introduction and nothing here blocks a determined
one.

**A separate correction in the same area:** `Sendable` is NOT a second barrier in this build. The
project compiles at `SWIFT_VERSION 5.0` with no strict concurrency, so a non-`Sendable` stored
closure only warns. Its control is sound and does bite, but what it pins is a barrier that becomes
real under the Swift 6 language mode, not one that enforces anything today.

**Deliberately NOT closed, and the reasoning is the ruling made on the summary parser's
computed-member gap, kept consistent with it:** closing any of (1)-(4) needs bespoke
source-signature or AST guard infrastructure -- a negative control in another file cannot see a
wrapper's internals, a property wrapper's `wrappedValue`, a computed member, or a user-defined `==`,
none of which emit a diagnostic of their own. Such machinery would itself need verifying, and it
rots silently when the source layout changes. It would be built to defend a seam whose worst
residual is already bounded: a caller can make an export FAIL, and cannot lose audio.

**What is claimed, precisely**, in the code as well as here: the six expression controls enforce
today's declared surface; synthesised `Equatable` enforces the no-closure property for directly
stored closure-typed properties only; the `Sendable` control enforces nothing until Swift 6; and
nothing enforces (1)-(4). Anyone adding a wrapper field, a property wrapper, a computed closure
member, or a custom `==` to `FaultInjection` is removing a load-bearing barrier and should read this
entry first -- which is why the type's own doc comment spells out the same four rather than leaving
`Equatable` to look like boilerplate.

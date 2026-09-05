# Follow-ups

Known gaps deliberately left open, with the reasoning, so they are decisions rather than
accidents. See each entry for the evidence.

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
Known limitations and handover items surfaced during review, deliberately not fixed as part of
the change that found them. Not a task tracker — just a record so they aren't rediscovered from
scratch later.

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
item below is resolved.** Each is a link to the full entry; none is a nice-to-have.

| # | Prerequisite | Status | Why it blocks wiring |
|---|---|---|---|
| 1 | Real-audio / real-model smoke testing of all three adapters | **OPEN** | No adapter has ever executed a real model load or a real inference. Compilation and fake-driven tests are the only evidence that exists. |
| 2 | B2 residual: the admission-to-inference window (below) | **OPEN** | A dictation Mark starts in that window still queues behind a meeting chunk. Closing it needs shared admission with the dictation path, which is an upstream change nobody has authorised. |
| 3 | A dictation-priority closure that is actually correct | **OPEN** | `MeetingAsrRuntimeAccess.isDictationActiveOrPending` has no default by design. Admission is only as good as what the composition root passes; passing `{ false }` silently disables item 2's mitigation entirely. |
| 4 | transcribe.cpp concurrent-session safety | **OPEN** | Unlike FluidAudio, that path runs meeting and dictation inference concurrently rather than serialised, and whether that is safe or affordable on a 16GB M2 Pro is unmeasured. |
| 5 | A diarizer `loadOperationTimeout` chosen from data | **OPEN** | The 30s default was picked without a single real-hardware measurement of how long `DiarizerModels.load` actually takes. |

Items 2, 3 and 4 all reduce to the same exposure and the same person's daily flow: **Mark dictates
with local Parakeet every day, and none of the mitigations above have been measured against real
inference times.** A meeting chunk that degrades costs one chunk's segment timings. A dictation
that stalls costs him the thing he was in the middle of saying. That asymmetry is why this gate is
a gate and not a checklist.

## GATE ITEM 1 -- Real-audio / real-model smoke testing

`FluidAudioMeetingSegmentTranscriber`, `TranscribeCppMeetingSegmentTranscriber`, and
`FluidAudioMeetingDiarizer` (`Features/Meetings/Transcription/`) compile against the real
FluidAudio/TranscribeCpp package APIs and pass `xcodebuild build-for-testing`, but NONE of their
real model-loading/inference paths have ever run against real audio or real downloaded models —
no Parakeet, transcribe-cpp, or diarizer models are present in the environment these were built
in. Before any composition root constructs a real `MeetingTranscriptionCoordinator` and wires it
into `MeetingEngine` (currently nothing does — see `FORK-PATCHES.md`'s
`meeting-transcription-coordinator` section), the following must be run for real, on a Mac with
the actual models downloaded:

- **`.segment` timestamp support, per transcribe-cpp catalog model.** `segment-timing-design.md`
  §B and `FORK-PATCHES.md` both flag this as unresolved: whether `cohereTranscribe` or
  `senseVoiceSmall` (or both, or neither) actually populates `Transcript.segments` when asked for
  `timestamps: .segment`, versus silently resolving to a coarser kind. Requesting `.segment` and
  getting back an empty `segments` array is NOT a crash — it silently degrades to
  `TranscribeCppMeetingSegmentTranscriber`'s own empty-segments fallback (one flat, zero-duration
  segment) — so this needs an explicit real-audio check, not just "it didn't throw."
- **Actual resource measurement**, now that B1's fix round shares the loaded model with
  dictation instead of duplicating it: confirm on real hardware (ideally Mark's own 16GB M2 Pro)
  that memory stays within an acceptable envelope for the actual model(s) wired in. (The
  version-switch eviction race this bullet used to also ask about is CLOSED as of fix round 3 --
  the meeting seam has no API that can request a version, so it cannot evict. See the
  `borrowedAsrManager()` entries below and in `FORK-PATCHES.md` touchpoint 4.)
- **`FluidAudioMeetingDiarizer`'s real `DiarizerModels.load`/`performCompleteDiarization` path**,
  including a real timing measurement against the `loadOperationTimeout` default (30s) chosen
  without any real-hardware data point for how long a genuine model load takes on Mark's
  machine — the ceiling exists and is proven to bite (`FluidAudioMeetingDiarizerTests`), but
  whether 30s is the RIGHT number, as opposed to just A number, is unverified.

None of this can be substituted with more unit tests against injected fakes — the whole point is
verifying the REAL backend/model behavior the fakes stand in for.

## GATE ITEM 2 -- B2 residual: one `await` still separates admission from inference

Source: `VoiceInk/Features/Meetings/Transcription/FluidAudioMeetingSegmentTranscriber.swift`
(`transcribe(chunkAt:)`, `reconfirmDictationIsIdle()`).

**The exact remaining suspension.** After round 5's reordering, `transcribe(chunkAt:)` runs:

1. `await admitAndBorrow()` — hop to `@MainActor`: early priority check + borrow, no `await`
   between those two statements.
2. `await manager.decoderLayerCount` — hop into the `AsrManager` actor and back. **Hoisted above
   the final check in round 5**; round 4 had it below, which is the window review found.
3. `await reconfirmDictationIsIdle()` — hop to `@MainActor`: the final admission decision.
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


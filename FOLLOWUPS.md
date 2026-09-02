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

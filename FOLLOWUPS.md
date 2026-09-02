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

## `discard()` can leave a meeting row stuck in `.recording`/`.paused`

Source: `VoiceInk/Features/Meetings/Workflows/MeetingEngine.swift`, `discard()`'s
`Task { try? await persistence.markFailed(meetingHandle) }`. The `try?` discards
`markFailed`'s error exactly the way the pre-F3 code discarded every other persistence error.
If that one write fails, the row keeps whatever state it held when `discard()` ran
(`.recording` or `.paused`) instead of moving to `.failed`, so a later reader -- meeting
history, a support investigation -- sees an apparently-abandoned in-progress meeting with no
signal that it was in fact a deliberate, handled discard.

Confirmed accurate by cross-vendor review of the F3 fix rounds, and deliberately NOT fixed
there: `discard()` is not `async` and has no result object, so surfacing this needs a decision
about what channel it reports on (a callback, a stored last-error, a retry), which is a design
question rather than a mechanical fix, and it sits on the same unscoped path as
`pause()`/`resume()`'s own `updateState` calls. The same review's recommendation stands:
**fix before Phase 2**, and fix that whole path (`pause`/`resume`/`discard`) together rather
than one call at a time.

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

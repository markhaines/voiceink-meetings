# Transcription adapter handover

Self-contained handover for whoever builds the transcription adapter stage on top of
`VoiceInk/Features/Meetings/Transcription/` (`StreamingVadController`, `TranscriptFormatter`,
`TranscriptReconciler`, `DiarizerRuntimePolicy`, `MicVadStream`/`SystemVadStream`). Everything
below is sourced from the donor (`Muesli-HQ/muesli`,
`native/MuesliNative/Sources/MuesliNativeApp/`), with file/line citations, so this document does
not depend on anything outside this repository (in particular, not on `.tandem/`, which is
orchestration state and does not exist in an ordinary clone).

## 1. AEC-cleaned mic into mic VAD and mic chunk recorder

Both the mic VAD and the mic PCM chunk recorder are driven from **the same single funnel**, fed
only AEC-cleaned float samples — never raw mic. Donor `MeetingSession.swift`:

- `enqueueRealtimeMicSamples` (lines 1212-1236) receives raw `[Int16]` mic samples, converts to
  float, runs them through `neuralAec.processStreamingMic(floatSamples)`, and passes the
  **cleaned** result to `appendCleanedMicSamplesOnQueue`. Only then, guarded by
  `!cleanedFloat.isEmpty`, does it call `vadController.processAudio(cleanedFloat)` (line 1233).
  The comment directly above that call (lines 1229-1231) is the load-bearing rule:
  > "Meeting mic chunks must be driven by the cleaned mic stream. Raw mic VAD sees speaker
  > playback bleed and can create false `You` chunks even when AEC removed that speech from the
  > final mic audio."
- `appendCleanedMicSamplesOnQueue` (lines 1267-1278) is the funnel itself: it feeds the streaming
  partial-transcript tail, converts cleaned float back to Int16, and calls
  `rawMicChunkRecorder?.append(cleanedInt16)` (line 1275) plus
  `chunkTimingTracker.append(sampleCount:)` (line 1276). So the mic VAD and the mic
  `PCMChunkRecorder` see **exactly the same AEC-cleaned samples**, not two independently-cleaned
  copies.
- System audio also feeds this same mic funnel a second way: `enqueueRealtimeSystemSamples`
  (lines 1238-1265) calls `neuralAec.feedSystemSamples(floatSamples)` then drains any newly
  available cleaned mic output via `neuralAec.processStreamingMic([])` (line 1254) — an
  AEC implementation detail (cleaned mic output can lag behind system input), not a second mic
  source. Both call sites end up funneling through `appendCleanedMicSamplesOnQueue` /
  `vadController.processAudio`.

**In this fork:** use `MicVadStream.process(_:)`, which only accepts `AECCleanedMicSamples`
(see `MeetingVadStreams.swift`). Construct that wrapper immediately after your AEC step's output
— nowhere else — mirroring `appendCleanedMicSamplesOnQueue`'s role as the single funnel. Feed the
same cleaned samples to whatever this fork's mic `PCMChunkRecorder` equivalent is, so the VAD and
the recorded chunk audio never diverge, exactly as the donor does.

## 2. Raw system stream into system VAD

`enqueueRealtimeSystemSamples` (donor `MeetingSession.swift:1238-1265`) converts raw `[Int16]`
system samples to float (line 1251) and passes **that same unmodified `floatSamples`** — not
`cleanedFloat` — to `systemVadController.processAudio(floatSamples)` (lines 1261-1262). No AEC,
no cleaning: the system VAD is meant to see the system audio exactly as captured. The same raw
Int16 samples are separately appended to `systemChunkRecorder` (line 1248) and
`systemChunkTimingTracker` (line 1249).

**In this fork:** use `SystemVadStream.process(_:)`, which only accepts `RawSystemSamples`.

## 3. VAD boundary rotation, and the transcription inputs/outputs at each rotation

Both `MicVadStream`/`SystemVadStream` (via the wrapped `StreamingVadController`) call
`onChunkBoundary` when VAD detects `speechEnd` (subject to the 3s/5s min/max window) or the max
duration timer forces a cut. The donor's handler for the mic side,
`rotateChunkOnQueue` (`MeetingSession.swift:997-1050`), is the shape to follow:

1. `chunkTimingTracker.rotate()` → `MeetingChunkTimingSnapshot?` (start sample index + sample
   count for the just-completed chunk; `nil` means nothing to rotate — bail).
2. `rawMicChunkRecorder?.rotateFile()` → the completed chunk's `URL?` (a finalized WAV file);
   `nil` means an empty/failed rotation — bail and don't leak the timing snapshot.
3. Spawn a `Task` that transcribes that chunk's WAV file against the `chunkTiming` snapshot,
   producing `[SpeechSegment]` (donor's `transcribeMicChunk(rawURL:chunkTiming:isFinalChunk:)`,
   line ~1280 onward — not itself in scope for this stage, since it's inside the unported
   `TranscriptionRuntime`).
4. Register the task with a `MeetingChunkCollector` (`micChunkCollector`/`systemChunkCollector`,
   lines 184-185) so out-of-order completion is handled — chunks can finish transcribing in a
   different order than they were rotated.
5. On completion, retire the task's segments into the collector and invoke a per-chunk callback
   (`onChunkTranscribed?(resolvedSegments, "You")`, line 1044) for any live-updating UI.

The system side (`rotateSystemChunkOnQueue`, lines 1058+, not reproduced here) mirrors this
exactly, tagging with `"Others"`/diarization instead of `"You"`.

**Rotation input**: a completed WAV chunk file + its `MeetingChunkTimingSnapshot` (absolute
sample offset within the meeting). **Rotation output**: `[SpeechSegment]` for that chunk, fed
into the source's `MeetingChunkCollector`.

## 4. Reconcile BEFORE format — always, in that order

End of meeting (`MeetingSession.swift:814-877`):

```swift
micSegments.append(contentsOf: await micChunkCollector.closeAndDrainSortedSegments())
// ... system segments similarly, plus recovery/repair passes ...

let reconciledTranscriptInputs = TranscriptReconciler.reconcile(
    micTurns: micSegments,
    systemSegments: systemSegments,
    diarizationSegments: diarizationSegments
)

let rawTranscript = TranscriptFormatter.merge(
    micSegments: reconciledTranscriptInputs.micSegments,
    systemSegments: reconciledTranscriptInputs.systemSegments,
    diarizationSegments: reconciledTranscriptInputs.diarizationSegments,
    meetingStart: meetingStart
)
```

`TranscriptReconciler.reconcile` must run first, always, on the full collected segment arrays for
the whole meeting — it dedupes cross-stream utterances (0.25s overlap pad, 0.35s merge gap) and
decides which overlapping mic/system turns to keep. `TranscriptFormatter.merge` must only ever
receive the reconciler's *output* (`reconciledTranscriptInputs.micSegments`/`.systemSegments`/
`.diarizationSegments`), never the raw collector output directly — formatting raw, un-reconciled
segments will double up utterances that landed in both streams.

## 5. Diarizer policy/preload requirements and cancellation semantics

`DiarizerRuntimePolicy.resolve(for: .current())` must be called once, and its
`.modelConfiguration` used, whenever loading FluidAudio's `DiarizerManager` — this is what
applies the M1/macOS-15.1 GPU-avoidance workaround (FluidAudio issue #344). Donor
`TranscriptionRuntime.swift`:

- **Shared preload, not per-caller.** `preloadDiarizer(trigger:waitTimeout:)` (lines 680-720) is
  an `actor`-isolated method: if a load is already in progress (`isDiarizerLoadInProgress`), a
  second caller does **not** start a second load — it joins the existing one via
  `waitForActiveDiarizerLoad(timeout:)` (line 815+) and gets the same outcome. Multiple call
  sites (app launch, meeting start, backend change, etc. — see `DiarizerPreloadTrigger`) can all
  call this safely.
- **Operation deadline, independent of the caller's wait timeout.** `startDiarizerLoad`
  (lines 722-764) starts both the load `Task` and a separate `diarizerLoadTimeoutTask` bounded by
  `diarizerLoadOperationTimeout` (line 755, default `TranscriptionCoordinator
  .defaultDiarizerLoadOperationTimeout`). If the operation itself hangs (e.g. CoreML compilation
  never returns), `timeoutDiarizerLoad(id:)` (lines 805-813) cancels the load task and resumes
  *all* waiters with `.timedOut` — this is a hard ceiling on the load itself, separate from any
  individual caller's `waitTimeout`.
- **Cancellation of a joiner does not cancel the shared load.** A caller that cancels while
  waiting (e.g. its own `Task` is cancelled) returns promptly with `.cancelled`, but the
  in-progress shared load keeps running for any other waiter — cancelling one joiner must never
  abort the load for everyone.
- **Cancellation before backend loading.** `preloadRequired(backend:...)` (lines 543+) calls
  `preloadMeetingHelpers` (which calls `preloadDiarizer`) and then, at line 557, does
  `try Task.checkCancellation()` **before** the backend-specific model-loading `switch` (line
  559 onward). This is the boundary that stops a cancelled required-preload from ever entering
  real backend loading.
- **`DiarizerPreloadDiagnostics`** (this fork, `DiarizerRuntimePolicy.swift`) already exists and
  is ready to use — its default `signalSink` now logs via `os.Logger` (see that file's header
  comment for why it isn't `TelemetryDeck.signal` as in the donor), and every real caller can
  either accept that default or inject a proper telemetry sink once one exists.

**Carried forward, not built here** (see the non-blocking items below): the donor's
`DiarizerPreloadCoordinationTests` suite in `DiarizerRuntimePolicyTests.swift` exercises exactly
this shared-load/cancellation/deadline machinery against `TranscriptionCoordinator` — a type that
belongs to the not-yet-built adapter, not to this stage. It was **not** ported (see this stage's
own `DiarizerRuntimePolicyTests.swift` header). The adapter stage's own coordinator must cover the
same three properties before it can be considered a correct port of this behavior:
1. shared-load cancellation (a cancelled joiner returns without cancelling the load for others),
2. an operation deadline independent of any individual caller's wait timeout,
3. cancellation observed **before** backend loading ever starts for a joined, required preload.

## 6. Current tests: deterministic synthetic fixtures, not a golden-transcript foundation

`TranscriptFormatterTests.swift` and `TranscriptReconcilerTests.swift` are pure, deterministic
unit fixtures — `SpeechSegment`/`TimedSpeakerSegment` structs in, string/struct out, no audio, no
timing races. They're useful and worth keeping, but they are **not** a golden-transcript
regression foundation on their own:

- They cover max-overlap speaker mapping, the `"Others"` fallback, and ordinary same-speaker
  consolidation within the formatter's 2.0s gap threshold — but none of them exercise that 2.0s
  boundary itself (a case just inside vs. just outside it), nor the reconciler's 0.25s overlap-pad
  or 0.35s merge-gap boundaries (cases just inside vs. just outside either).
- None of them start from an actual mic/system WAV pair or a captured audio snapshot — every
  fixture is hand-authored `SpeechSegment` arrays with chosen timestamps and text. A real
  golden-transcript regression (Phase 2's stated acceptance criterion) needs an actual recorded
  mic+system pair (or a faithful synthetic equivalent) run through the real VAD → ASR →
  diarization → reconcile → format pipeline end to end, with the expected transcript checked in
  as the golden file. These fixtures cannot be reused as that; they can only serve as a
  complementary layer of fast, targeted unit coverage alongside it.

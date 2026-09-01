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

**In this fork:** drive the mic VAD with `MicVadStream`, and note that the API shape CHANGED in
the third fix round — earlier revisions of this document described a `process(_:)` that took an
`AECCleanedMicSamples` you constructed yourself. It no longer does, and that type is no longer
constructible outside `MeetingVadStreams.swift` at all. The facade now owns the AEC call:

```swift
// Once, at setup. `MicEchoCanceller` is declared in MeetingVadStreams.swift; the AEC branch's
// canceller conforms to it (two methods: processStreamingMic(_:) -> [Float],
// feedSystemSamples(_:)). Nothing in this stage depends on that branch's concrete types.
let micVad = MicVadStream(vadManager: vadManager, echoCanceller: neuralAec)
let systemVad = SystemVadStream(vadManager: vadManager)

// Per mic buffer (donor enqueueRealtimeMicSamples, lines 1212-1236). You hand it RAW mic; the
// stream runs AEC itself and drives the VAD with the cleaned output only.
let cleaned: AECCleanedMicSamples = micVad.process(RawMicSamples(rawMicFloats))
// Feed THAT SAME receipt onward to the mic chunk recorder, so VAD and recorded audio can never
// diverge (donor appendCleanedMicSamplesOnQueue, lines 1267-1278).
micChunkRecorder.append(int16(from: cleaned.samples))

// Per system buffer (donor enqueueRealtimeSystemSamples, lines 1238-1265). Two separate calls,
// exactly as the donor does: the far-end reference feed (which may drain cleaned MIC output into
// the MIC VAD, hence it living on MicVadStream), and the raw system VAD.
let drained: AECCleanedMicSamples = micVad.processFarEndReference(RawSystemSamples(systemFloats))
if !drained.isEmpty { micChunkRecorder.append(int16(from: drained.samples)) }
systemVad.process(RawSystemSamples(systemFloats))
```

**You do not construct `AECCleanedMicSamples`; you receive one.** It is a receipt: its payload is
a `private` stored property and its initializer is `fileprivate`, so no other file in the module
can build one by any route — not directly, not via a memberwise initializer, not via an extension
adding an initializer, not via a retro-conformed `Decodable`. Each of those was attacked from the
test target and the verbatim compiler errors are recorded as the attack list in
`MeetingVadStreamsTests.swift`. Possessing a value of that type therefore means it came out of
`MicEchoCanceller.processStreamingMic` via the facade.

**Wiring the real AEC in does NOT mean editing `MeetingVadStreams.swift`** (it did under the old
design; that instruction is withdrawn). Conform your canceller to `MicEchoCanceller` in the AEC
branch's own file and pass it to `MicVadStream.init`. That is the whole integration.

**The two residual holes you can still open, stated plainly so you do not open them by accident:**

1. **Passing a no-op canceller** — a `MicEchoCanceller` whose `processStreamingMic` returns its
   input — puts raw mic straight into the mic VAD and reintroduces the false-`You` defect. This is
   accepted as a visible, deliberate act rather than designed out; do not write one, including as
   a "temporary" placeholder before the AEC branch merges. If you need the mic path running before
   AEC exists, say so in review rather than stubbing it silently.
2. **Bypassing the facade entirely.** `StreamingVadController.processAudio(_:)` is still directly
   callable with any `[Float]` — `MicVadStream` wraps it, it does not seal it, and this port
   deliberately never modifies `StreamingVadController.swift`. Driving the mic VAD through
   anything other than `MicVadStream` is PROHIBITED.
   `Tests/.../MeetingVadStreamsTests.swift` has two cheap, deterministic static scans over
   `VoiceInk/` that fail the build on either mistake: `processAudioCallSitesAreFacadeOnly` (a
   `.processAudio(` call site outside `MeetingVadStreams.swift`) and
   `forgedCleanedSampleConstructionIsAbsentFromProduction` (production code constructing
   `AECCleanedMicSamples`, `unsafeBitCast`ing to it, or reintroducing the deleted
   `mint(from:)`/`AECMicOutputAttestation`/`unsafeUnattestedForTestsOnly` apparatus). Both are
   substring text scans, not real parsers: neither catches a call reached only through a stored or
   partially-applied method reference (`let fn = controller.processAudio; fn(x)`).

Feed the same cleaned samples to whatever this fork's mic `PCMChunkRecorder` equivalent is, so
the VAD and the recorded chunk audio never diverge, exactly as the donor does.

## 2. Raw system stream into system VAD

`enqueueRealtimeSystemSamples` (donor `MeetingSession.swift:1238-1265`) converts raw `[Int16]`
system samples to float (line 1251) and passes **that same unmodified `floatSamples`** — not
`cleanedFloat` — to `systemVadController.processAudio(floatSamples)` (lines 1261-1262). No AEC,
no cleaning: the system VAD is meant to see the system audio exactly as captured. The same raw
Int16 samples are separately appended to `systemChunkRecorder` (line 1248) and
`systemChunkTimingTracker` (line 1249).

**In this fork:** use `SystemVadStream.process(_:)`, which only accepts `RawSystemSamples` —
handing it `RawMicSamples` is a compile error. `SystemVadStream` has no echo canceller and
never touches one. Remember the far-end reference is a SEPARATE call on the mic side
(`MicVadStream.processFarEndReference(_:)`, section 1): the same `RawSystemSamples` goes to
both, exactly as the donor feeds `neuralAec.feedSystemSamples` and
`systemVadController.processAudio` from the one buffer.

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

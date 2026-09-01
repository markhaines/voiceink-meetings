# Follow-ups

Known limitations and handover items surfaced during review, deliberately not fixed as part of
the change that found them. Not a task tracker — just a record so they aren't rediscovered from
scratch later.

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

// Adapted from Muesli-HQ/muesli
// (native/MuesliNative/Tests/MuesliTests/AudioGraphExceptionBridgeTests.swift).
// Donor imports AudioGraphExceptionBridge as its own SwiftPM module target. This fork exposes
// the same C functions to the whole VoiceInk module via a bridging header instead (see
// VoiceInk/Features/Meetings/Capture/VoiceInk-Bridging-Header.h), so `import
// AudioGraphExceptionBridge` is replaced with `@testable import VoiceInk` and the bridged
// functions are called directly, matching this fork's other test files. The donor's two test
// bodies are otherwise unchanged.
//
// A third test, `installTapExceptionIsContained`, was attempted and then REMOVED after CI
// evidence, not just left untried. It called `MuesliAudioGraphInstallInputTap` with an
// out-of-range bufferSize (1, outside the documented valid [100, 400] range) to force AVFAudio
// to raise the NSException this bridge exists to catch. It passed instantly, repeatably, on a
// real Mac (macOS 26.6.2, Mac mini). On GitHub Actions' macOS runner it did not raise promptly:
// it blocked for ~660 seconds before the whole `xcodebuild test` invocation reported it failed
// (PR #2, run 33547075114, "Run test targets" step -- the other two tests in this suite, which
// this change did not touch, show the same ~600s duration in that run purely because Swift
// Testing's parallel execution reports suite-elapsed time for tests queued behind a blocked
// one, not their own time; they do not hang on their own, confirmed by two earlier green CI
// runs before this test existed). The likely cause: calling into real AVAudioEngine/
// AVAudioIONode APIs on a runner with no audio hardware at all can block on device
// enumeration/negotiation rather than failing fast, which is a materially different failure
// mode from the deterministic, fast NSException this test meant to prove -- and a genuine
// eleven-minute CI hang is a worse defect than the coverage gap it was trying to close. Per the
// instruction that authorized this attempt: this could not be done honestly as a reliable unit
// test, so it is not kept. The exception-containment behavior of `MuesliAudioGraphInstallInputTap`
// remains unit-tested only implicitly, through the donor's own two tests below plus the ported
// C source being provably unchanged (see AudioGraphExceptionBridge.h/.m's attribution comments).
//
// The remaining two tests below regressed with the SAME failure mode once Phase 1 Stage 1
// (mic-route: markhaines/voiceink-meetings#3) added ~700 lines of concurrency-heavy test
// suites alongside them in the same xctest bundle. CI run 33555297407 (this PR's first run)
// reported both `inputStateReadIsContained` and `invalidInputRouteIsContained` at 600.513s --
// identical to each other, and identical to the "Testing started completed" elapsed marker for
// the whole invocation -- while every other suite's tests (including the new ones) printed
// their pass/fail lines in one burst immediately afterward. That pattern is `xcodebuild test`
// buffering ALL Swift Testing output until the process exits, so per-test durations in this log
// are not self-measured wall time; they are "how long the whole run took," misattributed to
// whichever tests happened to be resident when it unblocked -- the same misattribution the
// paragraph above already documented for `installTapExceptionIsContained`. Locally (Mac mini,
// same "zero audio input devices" starting condition as the CI runner) both tests pass in
// ~2.2s each, so the underlying AVAudioEngine-against-no-hardware call genuinely IS fast on at
// least one no-device host; it is evidently not reliably fast on GitHub's virtualized runner.
// Rather than reduce the new suites' concurrency to chase a call this file does not own
// (StreamingMicRecorder/AudioRouteController's tests are legitimately concurrency-heavy by
// design and un-serializable across suites without an .xctestplan this project does not have),
// both tests below are now gated on a real, non-aggregate input device actually being present
// (checked via CoreAudioDeviceInspector().availableInputDevices(), a plain
// AudioObjectGetPropertyData enumeration -- no AVAudioEngine involved, so the guard itself
// cannot hang). Neither this Mac nor the CI runner has one, so both tests report as SKIPPED,
// not passed: an honest signal that this exception-boundary behavior has no environment in this
// project's CI that can verify it fast and reliably, rather than an intermittent 2s-or-600s
// runtime masquerading as a pass. See mic-route.md for the CI run ids and full diagnosis.
//
// MIT License
//
// Copyright (c) 2026 Pranav Hari
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// See NOTICE for full attribution.

import AVFoundation
import CoreAudio
import Testing
@testable import VoiceInk

/// True when at least one real (non-aggregate) CoreAudio input device is present. Backed
/// entirely by `AudioObjectGetPropertyData` enumeration (`CoreAudioDeviceInspector`, from
/// `AudioRouteController.swift`) -- never touches `AVAudioEngine`, so evaluating this guard
/// cannot itself hang, unlike the calls it gates.
private func hasRealAudioInputDevice() -> Bool {
    !CoreAudioDeviceInspector().availableInputDevices().isEmpty
}

@Suite("AVFAudio exception boundary")
struct AudioGraphExceptionBridgeTests {
    @Test(
        "input state reads return a format or a bridged error",
        .enabled(if: hasRealAudioInputDevice(), "requires a real CoreAudio input device")
    )
    func inputStateReadIsContained() {
        let state = MuesliAudioGraphReadInputState(AVAudioEngine())

        #expect(state.outputFormat != nil || state.error != nil)
    }

    @Test(
        "invalid input routing returns an error instead of escaping the boundary",
        .enabled(if: hasRealAudioInputDevice(), "requires a real CoreAudio input device")
    )
    func invalidInputRouteIsContained() {
        let error = MuesliAudioGraphSetInputDevice(AVAudioEngine(), AudioObjectID.max)

        #expect(error != nil)
    }
}

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

@Suite("AVFAudio exception boundary")
struct AudioGraphExceptionBridgeTests {
    @Test("input state reads return a format or a bridged error")
    func inputStateReadIsContained() {
        let state = MuesliAudioGraphReadInputState(AVAudioEngine())

        #expect(state.outputFormat != nil || state.error != nil)
    }

    @Test("invalid input routing returns an error instead of escaping the boundary")
    func invalidInputRouteIsContained() {
        let error = MuesliAudioGraphSetInputDevice(AVAudioEngine(), AudioObjectID.max)

        #expect(error != nil)
    }
}

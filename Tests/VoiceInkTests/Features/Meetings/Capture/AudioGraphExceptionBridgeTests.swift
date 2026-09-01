// Adapted from Muesli-HQ/muesli
// (native/MuesliNative/Tests/MuesliTests/AudioGraphExceptionBridgeTests.swift).
// Donor imports AudioGraphExceptionBridge as its own SwiftPM module target. This fork exposes
// the same C functions to the whole VoiceInk module via a bridging header instead (see
// VoiceInk/Features/Meetings/Capture/VoiceInk-Bridging-Header.h), so `import
// AudioGraphExceptionBridge` is replaced with `@testable import VoiceInk` and the bridged
// functions are called directly, matching this fork's other test files. The donor's two test
// bodies are otherwise unchanged.
//
// `installTapExceptionIsContained` below is NOT from the donor -- added because the two donor
// tests only exercise ordinary control-flow error returns (an unavailable format, a rejected
// OSStatus), never a genuine `@catch`. This bridge's whole reason to exist is catching
// NSExceptions Swift cannot catch, so that path deserves direct coverage. Passing bufferSize 1
// to `installTapOnBus:bufferSize:format:block:` (documented valid range: [100, 400] frames) is
// a hardware-independent way to make AVFAudio raise NSException synchronously. The proof this
// test actually exercises `@catch` and not some other return path is structural, not assumed:
// `MuesliAudioGraphInstallInputTap`'s ported C source (AudioGraphExceptionBridge.m) has exactly
// two exits -- `return nil;` inside the `@try` on success, or `return
// MuesliAudioGraphExceptionError(...)` inside `@catch`. There is no third path and no ordinary
// OSStatus branch (unlike `MuesliAudioGraphSetInputDevice` above, which does have one, which is
// why `invalidInputRouteIsContained` alone does not prove exception containment). So a non-nil
// result from this specific function is only reachable through `@catch`, by construction of the
// code being tested -- confirmed empirically too: this bufferSize/format combination returns a
// non-nil error on this Mac (macOS 26.6.2, no real meeting-audio hardware route active).
//
// All three tests below construct a real `AVAudioEngine` and touch `engine.inputNode`, which
// can block for ~600s negotiating against GitHub Actions' specific CoreAudio device inventory
// instead of returning promptly (they do not hang on a real Mac, where the same calls take
// ~2s). All three are therefore gated on `isRunningInCI` below, a `TEST_RUNNER_`-prefixed
// environment variable set by `.github/workflows/ci.yml` (see that file's comment on the "Run
// test targets" step for why this specific mechanism, and not a plain `GITHUB_ACTIONS` check,
// is required to reach this test process). They run for real -- and pass -- on a developer Mac,
// including via Xcode's own Test Navigator, which does not go through that CI script and so
// never sets this variable. Full diagnosis, both discarded guard attempts (a device-count
// check, then a plain `GITHUB_ACTIONS` check), and the CI run ids that proved each wrong:
// FORK-PATCHES.md, "phase-1-mic-route" section.
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
import Foundation
import Testing
@testable import VoiceInk

/// True only when launched via `.github/workflows/ci.yml`'s "Run test targets" step, which sets
/// `TEST_RUNNER_VOICEINK_CI` so `xcodebuild` forwards it (prefix stripped) into this process.
/// Plain environment lookup -- cannot itself hang, unlike the calls it gates.
private var isRunningInCI: Bool {
    ProcessInfo.processInfo.environment["VOICEINK_CI"] != nil
}

@Suite("AVFAudio exception boundary")
struct AudioGraphExceptionBridgeTests {
    @Test(
        "input state reads return a format or a bridged error",
        .disabled(if: isRunningInCI, "hangs ~600s against this CI runner's CoreAudio device inventory; see file header")
    )
    func inputStateReadIsContained() {
        let state = MuesliAudioGraphReadInputState(AVAudioEngine())

        #expect(state.outputFormat != nil || state.error != nil)
    }

    @Test(
        "invalid input routing returns an error instead of escaping the boundary",
        .disabled(if: isRunningInCI, "hangs ~600s against this CI runner's CoreAudio device inventory; see file header")
    )
    func invalidInputRouteIsContained() {
        let error = MuesliAudioGraphSetInputDevice(AVAudioEngine(), AudioObjectID.max)

        #expect(error != nil)
    }

    @Test(
        "an out-of-range tap buffer size raises NSException, which the bridge contains",
        .disabled(if: isRunningInCI, "hangs ~600s against this CI runner's CoreAudio device inventory; see file header")
    )
    func installTapExceptionIsContained() {
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        // AVAudioIONode.installTap's documented valid bufferSize range is [100, 400] frames.
        // 1 is outside it and should raise NSException synchronously, independent of whether
        // real audio hardware is available.
        let error = MuesliAudioGraphInstallInputTap(engine, 0, 1, format) { _, _ in }

        #expect(error != nil)
    }
}

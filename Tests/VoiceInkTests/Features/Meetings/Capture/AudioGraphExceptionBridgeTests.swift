// Adapted from Muesli-HQ/muesli
// (native/MuesliNative/Tests/MuesliTests/AudioGraphExceptionBridgeTests.swift).
// Donor imports AudioGraphExceptionBridge as its own SwiftPM module target. This fork exposes
// the same C functions to the whole VoiceInk module via a bridging header instead (see
// VoiceInk/Features/Meetings/Capture/VoiceInk-Bridging-Header.h), so `import
// AudioGraphExceptionBridge` is replaced with `@testable import VoiceInk` and the bridged
// functions are called directly, matching this fork's other test files. Test bodies are
// otherwise unchanged.

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

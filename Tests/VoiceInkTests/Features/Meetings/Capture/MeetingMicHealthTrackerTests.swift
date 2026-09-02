// Ported verbatim from Muesli-HQ/muesli (native/MuesliNative/Tests/MuesliTests/MeetingMicHealthTrackerTests.swift), adapted only
// to import VoiceInk instead of MuesliNativeApp — see below.
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

import Foundation
import Testing
@testable import VoiceInk

@Suite("MeetingMicHealthTracker")
struct MeetingMicHealthTrackerTests {
    @Test("all-zero raw mic with active system audio raises degraded warning")
    func allZeroRawMicWithActiveSystemAudioRaisesWarning() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000), now: now)
        var snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(1))
        #expect(snapshot.state == .waitingForAudio)

        snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))
        #expect(snapshot.state == .waitingForAudio)

        snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(3))
        #expect(snapshot.state == .micAllZeroWhileSystemActive)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("system audio without mic callbacks is distinguishable from all-zero mic")
    func systemAudioWithoutMicCallbacksIsMissingCallbacks() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now)
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(1))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))

        #expect(snapshot.state == .micCallbacksMissing)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("mid-meeting mic callback loss after healthy input raises warning")
    func midMeetingMicCallbackLossRaisesWarning() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 400, count: 1_000), now: now)
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(3))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(4))

        #expect(snapshot.state == .micCallbacksMissing)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("mid-meeting mic callback loss still warns when system audio starts during grace window")
    func midMeetingMicCallbackLossWithGraceWindowRaisesWarning() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 400, count: 1_000), now: now)
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 1_600), now: now.addingTimeInterval(0.5))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(3))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(4))

        #expect(snapshot.state == .micCallbacksMissing)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("silence without active system audio does not warn")
    func silenceWithoutActiveSystemAudioDoesNotWarn() {
        let tracker = MeetingMicHealthTracker()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 0, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 0, count: 16_000))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 0, count: 16_000))

        #expect(snapshot.state == .waitingForAudio)
        #expect(snapshot.warningMessage == nil)
    }

    @Test("non-zero raw mic clears degraded warning")
    func nonZeroRawMicClearsWarning() {
        let tracker = MeetingMicHealthTracker()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))
        let recovered = tracker.noteRawMicSamples(Array(repeating: 400, count: 1_000))

        #expect(recovered.state == .healthy)
        #expect(recovered.warningMessage == nil)
        #expect(recovered.firstNonZeroMicAt != nil)
    }
}

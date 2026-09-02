// Ported verbatim from Muesli-HQ/muesli (native/MuesliNative/Tests/MuesliTests/MeetingSignalRefreshPolicyTests.swift), adapted
// only to import VoiceInk instead of MuesliNativeApp — see below.
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

@Suite("MeetingSignalRefreshPolicy")
struct MeetingSignalRefreshPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("idle fallback skips expensive collectors")
    func idleFallbackSkipsExpensiveCollectors() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            lastAudioAttributionRefreshAt: now.addingTimeInterval(-10),
            lastBrowserRefreshAt: now.addingTimeInterval(-10)
        )

        let decision = policy.decision(trigger: .fallbackTimer, state: state, now: now)

        #expect(decision.mode == .idle)
        #expect(decision.fallbackInterval == 120)
        #expect(decision.refreshAudioAttribution == false)
        #expect(decision.refreshBrowserMeetings == false)
    }

    @Test("mic trigger enters suspicion and allows immediate audio attribution")
    func micTriggerAllowsImmediateAudioAttribution() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            lastAudioAttributionRefreshAt: now,
            lastBrowserRefreshAt: now
        )

        let decision = policy.decision(trigger: .micChanged, state: state, now: now)

        #expect(decision.mode == .suspicious)
        #expect(decision.fallbackInterval == 3)
        #expect(decision.refreshAudioAttribution == true)
    }

    @Test("repeated suspicious fallback respects expensive collector throttle")
    func repeatedSuspiciousFallbackRespectsThrottle() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            lastAudioAttributionRefreshAt: now.addingTimeInterval(-4),
            lastBrowserRefreshAt: now.addingTimeInterval(-1),
            lastSuspicionAt: now.addingTimeInterval(-2)
        )

        let decision = policy.decision(trigger: .fallbackTimer, state: state, now: now)

        #expect(decision.mode == .suspicious)
        #expect(decision.refreshAudioAttribution == false)
        #expect(decision.refreshBrowserMeetings == false)
    }

    @Test("suspicious fallback refreshes collectors after throttle expires")
    func suspiciousFallbackRefreshesAfterThrottle() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            lastAudioAttributionRefreshAt: now.addingTimeInterval(-9),
            lastBrowserRefreshAt: now.addingTimeInterval(-4),
            lastSuspicionAt: now.addingTimeInterval(-2)
        )

        let decision = policy.decision(trigger: .fallbackTimer, state: state, now: now)

        #expect(decision.mode == .suspicious)
        #expect(decision.refreshAudioAttribution == true)
        #expect(decision.refreshBrowserMeetings == true)
    }

    @Test("active-tab fallback is throttled per browser bundle")
    func activeTabFallbackIsThrottledPerBundle() {
        let policy = MeetingSignalRefreshPolicy()
        var state = MeetingSignalRefreshState()
        state.lastActiveTabFallbackAttemptAtByBundleID = [
            "com.google.Chrome": now.addingTimeInterval(-10),
            "com.apple.Safari": now.addingTimeInterval(-16),
        ]

        #expect(policy.allowsActiveTabFallbackProbe(for: "com.google.Chrome", state: state, now: now) == false)
        #expect(policy.allowsActiveTabFallbackProbe(for: "com.apple.Safari", state: state, now: now) == true)
        #expect(policy.allowsActiveTabFallbackProbe(for: "com.brave.Browser", state: state, now: now) == true)
    }

    @Test("suspicion expires back to idle after TTL")
    func suspicionExpiresBackToIdle() {
        let policy = MeetingSignalRefreshPolicy()
        let state = MeetingSignalRefreshState(
            lastAudioAttributionRefreshAt: now.addingTimeInterval(-40),
            lastBrowserRefreshAt: now.addingTimeInterval(-40),
            lastSuspicionAt: now.addingTimeInterval(-13)
        )

        let decision = policy.decision(trigger: .fallbackTimer, state: state, now: now)

        #expect(decision.mode == .idle)
        #expect(decision.fallbackInterval == 120)
    }

    @Test("active candidate keeps suspicious mode")
    func activeCandidateKeepsSuspiciousMode() {
        let policy = MeetingSignalRefreshPolicy()
        var state = MeetingSignalRefreshState()
        state.hasActiveCandidate = true

        let decision = policy.decision(trigger: .fallbackTimer, state: state, now: now)

        #expect(decision.mode == .suspicious)
        #expect(decision.fallbackInterval == 3)
    }
}

// Ported verbatim from Muesli-HQ/muesli
// (native/MuesliNative/Sources/MuesliNativeApp/MeetingSignalRefreshPolicy.swift).
// Not in the task's original file list — added because `MeetingMonitor.swift` builds a
// `MeetingSignalRefreshPolicy()` and reads `MeetingDetectionTrigger` (declared here) directly
// and cannot compile without it. Small, self-contained (Foundation only, pure logic) — part of
// the same detection engine, not an unrelated subsystem. See MeetingDetectionPortReport in this
// PR description / FORK-PATCHES.md for the full dependency-closure justification.
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

enum MeetingDetectionTrigger: Equatable {
    case startup
    case fallbackTimer
    case micChanged
    case cameraChanged
    case sensorAttributionChanged
    case workspaceActivated
    case calendarChanged
    case promptStateChanged
    case manualRefresh
}

enum MeetingDetectionMode: Equatable {
    case idle
    case suspicious
}

struct MeetingSignalRefreshState: Equatable {
    var lastAudioAttributionRefreshAt: Date?
    var lastBrowserRefreshAt: Date?
    var lastActiveTabFallbackAttemptAtByBundleID: [String: Date] = [:]
    var lastSuspicionAt: Date?
    var hasMicOrCameraSignal = false
    var hasRecentBrowserMeeting = false
    var hasActiveCandidate = false
    var hasPromptVisible = false
    var hasCalendarEvent = false
    var foregroundIsMeetingCapableApp = false
}

struct MeetingSignalRefreshDecision: Equatable {
    let mode: MeetingDetectionMode
    let refreshAudioAttribution: Bool
    let refreshBrowserMeetings: Bool
    let fallbackInterval: TimeInterval
}

struct MeetingSignalRefreshPolicy {
    let idleFallbackInterval: TimeInterval
    let suspiciousFallbackInterval: TimeInterval
    let debounceDelay: TimeInterval
    let suspicionTTL: TimeInterval
    let audioSuspiciousThrottle: TimeInterval
    let audioIdleThrottle: TimeInterval
    let browserSuspiciousThrottle: TimeInterval
    let browserIdleThrottle: TimeInterval
    let activeTabFallbackThrottle: TimeInterval

    init(
        idleFallbackInterval: TimeInterval = 120,
        suspiciousFallbackInterval: TimeInterval = 3,
        debounceDelay: TimeInterval = 0.5,
        suspicionTTL: TimeInterval = 12,
        audioSuspiciousThrottle: TimeInterval = 8,
        audioIdleThrottle: TimeInterval = 120,
        browserSuspiciousThrottle: TimeInterval = 3,
        browserIdleThrottle: TimeInterval = 120,
        activeTabFallbackThrottle: TimeInterval = 15
    ) {
        self.idleFallbackInterval = idleFallbackInterval
        self.suspiciousFallbackInterval = suspiciousFallbackInterval
        self.debounceDelay = debounceDelay
        self.suspicionTTL = suspicionTTL
        self.audioSuspiciousThrottle = audioSuspiciousThrottle
        self.audioIdleThrottle = audioIdleThrottle
        self.browserSuspiciousThrottle = browserSuspiciousThrottle
        self.browserIdleThrottle = browserIdleThrottle
        self.activeTabFallbackThrottle = activeTabFallbackThrottle
    }

    func decision(
        trigger: MeetingDetectionTrigger,
        state: MeetingSignalRefreshState,
        now: Date
    ) -> MeetingSignalRefreshDecision {
        let suspicious = isSuspicious(trigger: trigger, state: state, now: now)
        let mode: MeetingDetectionMode = suspicious ? .suspicious : .idle
        let fallbackInterval = suspicious ? suspiciousFallbackInterval : idleFallbackInterval

        return MeetingSignalRefreshDecision(
            mode: mode,
            refreshAudioAttribution: shouldRefreshAudioAttribution(trigger: trigger, state: state, mode: mode, now: now),
            refreshBrowserMeetings: shouldRefreshBrowserMeetings(trigger: trigger, state: state, mode: mode, now: now),
            fallbackInterval: fallbackInterval
        )
    }

    func allowsActiveTabFallbackProbe(for bundleID: String, state: MeetingSignalRefreshState, now: Date) -> Bool {
        guard let lastAttempt = state.lastActiveTabFallbackAttemptAtByBundleID[bundleID] else { return true }
        return now.timeIntervalSince(lastAttempt) >= activeTabFallbackThrottle
    }

    func suspicionDate(
        after trigger: MeetingDetectionTrigger,
        state: MeetingSignalRefreshState,
        now: Date,
        resolvedCandidate: MeetingCandidate?
    ) -> Date? {
        if resolvedCandidate != nil
            || state.hasMicOrCameraSignal
            || state.hasRecentBrowserMeeting
            || state.hasPromptVisible
            || state.hasCalendarEvent
            || state.foregroundIsMeetingCapableApp
            || isSuspicionTrigger(trigger) {
            return now
        }

        guard let lastSuspicionAt = state.lastSuspicionAt,
              now.timeIntervalSince(lastSuspicionAt) <= suspicionTTL else {
            return nil
        }
        return lastSuspicionAt
    }

    private func isSuspicious(
        trigger: MeetingDetectionTrigger,
        state: MeetingSignalRefreshState,
        now: Date
    ) -> Bool {
        if state.hasMicOrCameraSignal
            || state.hasRecentBrowserMeeting
            || state.hasActiveCandidate
            || state.hasPromptVisible
            || state.hasCalendarEvent
            || state.foregroundIsMeetingCapableApp
            || isSuspicionTrigger(trigger) {
            return true
        }

        guard let lastSuspicionAt = state.lastSuspicionAt else { return false }
        return now.timeIntervalSince(lastSuspicionAt) <= suspicionTTL
    }

    private func shouldRefreshAudioAttribution(
        trigger: MeetingDetectionTrigger,
        state: MeetingSignalRefreshState,
        mode: MeetingDetectionMode,
        now: Date
    ) -> Bool {
        if trigger == .startup || trigger == .micChanged || trigger == .sensorAttributionChanged {
            return isThrottleExpired(since: state.lastAudioAttributionRefreshAt, throttle: 0, now: now)
        }

        let throttle = mode == .suspicious ? audioSuspiciousThrottle : audioIdleThrottle
        guard mode == .suspicious || trigger == .fallbackTimer || trigger == .manualRefresh else {
            return false
        }
        return isThrottleExpired(since: state.lastAudioAttributionRefreshAt, throttle: throttle, now: now)
    }

    private func shouldRefreshBrowserMeetings(
        trigger: MeetingDetectionTrigger,
        state: MeetingSignalRefreshState,
        mode: MeetingDetectionMode,
        now: Date
    ) -> Bool {
        if trigger == .startup || trigger == .workspaceActivated || trigger == .calendarChanged {
            return isThrottleExpired(since: state.lastBrowserRefreshAt, throttle: 0, now: now)
        }

        let throttle = mode == .suspicious ? browserSuspiciousThrottle : browserIdleThrottle
        guard mode == .suspicious || trigger == .fallbackTimer || trigger == .manualRefresh else {
            return false
        }
        return isThrottleExpired(since: state.lastBrowserRefreshAt, throttle: throttle, now: now)
    }

    private func isThrottleExpired(since date: Date?, throttle: TimeInterval, now: Date) -> Bool {
        guard let date else { return true }
        return now.timeIntervalSince(date) >= throttle
    }

    private func isSuspicionTrigger(_ trigger: MeetingDetectionTrigger) -> Bool {
        switch trigger {
        case .micChanged, .cameraChanged, .sensorAttributionChanged, .calendarChanged:
            return true
        case .startup, .fallbackTimer, .workspaceActivated, .promptStateChanged, .manualRefresh:
            return false
        }
    }
}

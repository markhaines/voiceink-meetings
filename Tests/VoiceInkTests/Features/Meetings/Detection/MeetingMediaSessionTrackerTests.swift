// Ported verbatim from Muesli-HQ/muesli (native/MuesliNative/Tests/MuesliTests/MeetingMediaSessionTrackerTests.swift), adapted
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

@Suite("MeetingMediaSessionTracker")
struct MeetingMediaSessionTrackerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        browserMeetings: [BrowserMeetingContext] = [],
        audioInputProcesses: [AudioProcessActivity] = [],
        now: Date
    ) -> MeetingSignalSnapshot {
        MeetingSignalSnapshot(
            micActive: false,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [
                RunningAppInfo(bundleID: "com.google.Chrome", isActive: true),
            ],
            browserMeetings: browserMeetings,
            audioInputProcesses: audioInputProcesses,
            foregroundBundleID: "com.google.Chrome",
            now: now
        )
    }

    private func browserURLCandidate(
        id: String = "googleMeet:meet.google.com/pwm-txwq-txy",
        url: String = "meet.google.com/pwm-txwq-txy",
        now: Date
    ) -> MeetingCandidate {
        MeetingCandidate(
            id: id,
            platform: .googleMeet,
            appName: "Chrome",
            url: url,
            evidence: [.browserURL, .audioInputProcess],
            startedAt: now,
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 9876,
            suppressionID: "browser:com.google.Chrome:session:1800000000"
        )
    }

    private func browserAudioCandidate(now: Date) -> MeetingCandidate {
        MeetingCandidate(
            id: "browser:com.google.Chrome:session:\(Int(now.timeIntervalSince1970))",
            platform: .unknown,
            appName: "Chrome",
            url: nil,
            evidence: [.audioInputProcess],
            startedAt: now,
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 9876,
            suppressionID: "browser:com.google.Chrome:session:\(Int(now.timeIntervalSince1970))"
        )
    }

    @Test("browser URL and generic browser audio candidates share a stable media session")
    func browserURLAndGenericAudioShareSession() async {
        let tracker = MeetingMediaSessionTracker(quietWindow: 30)

        let first = await tracker.stabilize(
            candidate: browserURLCandidate(now: now),
            snapshot: snapshot(now: now)
        )
        let second = await tracker.stabilize(
            candidate: browserAudioCandidate(now: now.addingTimeInterval(10)),
            snapshot: snapshot(now: now.addingTimeInterval(10))
        )

        #expect(first?.id == "meeting-session:browser:com.google.Chrome:room:meet.google.com/pwm-txwq-txy:1800000000")
        #expect(second?.id == first?.id)
        #expect(second?.suppressionID == first?.suppressionID)
        #expect(second?.platform == .googleMeet)
        #expect(second?.url == "meet.google.com/pwm-txwq-txy")
        #expect(second?.evidence.contains(.browserURL) == true)
    }

    @Test("browser media session expires after quiet window")
    func browserSessionExpiresAfterQuietWindow() async {
        let tracker = MeetingMediaSessionTracker(quietWindow: 30)

        let first = await tracker.stabilize(
            candidate: browserURLCandidate(now: now),
            snapshot: snapshot(now: now)
        )
        let later = await tracker.stabilize(
            candidate: browserURLCandidate(now: now.addingTimeInterval(45)),
            snapshot: snapshot(now: now.addingTimeInterval(45))
        )

        #expect(first?.id == "meeting-session:browser:com.google.Chrome:room:meet.google.com/pwm-txwq-txy:1800000000")
        #expect(later?.id == "meeting-session:browser:com.google.Chrome:room:meet.google.com/pwm-txwq-txy:1800000045")
        #expect(later?.id != first?.id)
    }

    @Test("different browser rooms in the quiet window get different media sessions")
    func differentBrowserRoomsGetDifferentSessions() async {
        let tracker = MeetingMediaSessionTracker(quietWindow: 30)

        let first = await tracker.stabilize(
            candidate: browserURLCandidate(now: now),
            snapshot: snapshot(now: now)
        )
        let second = await tracker.stabilize(
            candidate: browserURLCandidate(
                id: "googleMeet:meet.google.com/abc-defg-hij",
                url: "meet.google.com/abc-defg-hij",
                now: now.addingTimeInterval(10)
            ),
            snapshot: snapshot(now: now.addingTimeInterval(10))
        )
        let genericAfterSecondRoom = await tracker.stabilize(
            candidate: browserAudioCandidate(now: now.addingTimeInterval(11)),
            snapshot: snapshot(now: now.addingTimeInterval(11))
        )

        #expect(first?.id == "meeting-session:browser:com.google.Chrome:room:meet.google.com/pwm-txwq-txy:1800000000")
        #expect(second?.id == "meeting-session:browser:com.google.Chrome:room:meet.google.com/abc-defg-hij:1800000010")
        #expect(second?.id != first?.id)
        #expect(genericAfterSecondRoom?.id == second?.id)
        #expect(genericAfterSecondRoom?.url == "meet.google.com/abc-defg-hij")
    }

    @Test("non-media browser URL candidate keeps original identity")
    func nonMediaBrowserCandidateKeepsOriginalIdentity() async {
        let tracker = MeetingMediaSessionTracker(quietWindow: 30)
        let candidate = MeetingCandidate(
            id: "googleMeet:meet.google.com/pwm-txwq-txy",
            platform: .googleMeet,
            appName: "Chrome",
            url: "meet.google.com/pwm-txwq-txy",
            evidence: [.browserURL, .foregroundApp],
            startedAt: now,
            meetingTitle: nil,
            sourceBundleID: "com.google.Chrome",
            sourcePID: 9876
        )

        let result = await tracker.stabilize(
            candidate: candidate,
            snapshot: snapshot(now: now)
        )

        #expect(result?.id == candidate.id)
        #expect(result?.suppressionID == candidate.id)
    }
}

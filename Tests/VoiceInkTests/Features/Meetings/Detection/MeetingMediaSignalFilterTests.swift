// Ported verbatim from Muesli-HQ/muesli (native/MuesliNative/Tests/MuesliTests/MeetingMediaSignalFilterTests.swift), adapted only
// to import VoiceInk instead of MuesliNativeApp — see below. `MeetingMediaSignalFilter` is
// declared inside `MeetingMonitor.swift` in both the donor and this fork (not a separate file),
// so this test file targets that type via the module import rather than a matching production
// file of the same name.
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

@Suite("MeetingMediaSignalFilter")
struct MeetingMediaSignalFilterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let selfBundleID = "com.muesli.app"

    private func audioProcess(
        bundleID: String,
        appName: String,
        isRunningOutput: Bool = false
    ) -> AudioProcessActivity {
        AudioProcessActivity(
            pid: 1234,
            bundleID: bundleID,
            appName: appName,
            isRunningInput: true,
            isRunningOutput: isRunningOutput
        )
    }

    private func sensorAttributions(
        micBundleIDs: Set<String> = [],
        cameraBundleIDs: Set<String> = []
    ) -> SensorAttributionSnapshot {
        SensorAttributionSnapshot(
            micBundleIDs: micBundleIDs,
            cameraBundleIDs: cameraBundleIDs,
            observedAt: now
        )
    }

    private func resolver() -> MeetingCandidateResolver {
        let resolver = MeetingCandidateResolver()
        resolver.selfBundleID = selfBundleID
        return resolver
    }

    @Test("Muesli dictation mic does not satisfy calendar meeting activity")
    func muesliDictationMicDoesNotSatisfyCalendarMeetingActivity() {
        let media = MeetingMediaSignalFilter.apply(
            deviceMicActive: true,
            cameraActive: false,
            audioInputProcesses: [
                audioProcess(bundleID: selfBundleID, appName: "Muesli"),
            ],
            sensorAttributions: sensorAttributions(micBundleIDs: [selfBundleID]),
            selfBundleID: selfBundleID
        )

        #expect(media.micActive == false)
        #expect(media.audioInputProcesses.isEmpty)
        #expect(media.hasMicOrCameraSignal == false)

        let candidate = resolver().resolve(MeetingSignalSnapshot(
            micActive: media.micActive,
            cameraActive: media.cameraActive,
            calendarEvent: CalendarEventContext(id: "evt-standup", title: "Standup"),
            runningApps: [
                RunningAppInfo(bundleID: "us.zoom.xos", isActive: false),
            ],
            browserMeetings: [],
            audioInputProcesses: media.audioInputProcesses,
            foregroundBundleID: nil,
            now: now
        ))

        #expect(candidate == nil)
    }

    @Test("external meeting mic still counts when Muesli is also using input")
    func externalMeetingMicStillCountsWhenMuesliIsAlsoUsingInput() {
        let media = MeetingMediaSignalFilter.apply(
            deviceMicActive: true,
            cameraActive: false,
            audioInputProcesses: [
                audioProcess(bundleID: selfBundleID, appName: "Muesli"),
                audioProcess(bundleID: "com.microsoft.teams2", appName: "Teams", isRunningOutput: true),
            ],
            sensorAttributions: sensorAttributions(micBundleIDs: [selfBundleID, "com.microsoft.teams2"]),
            selfBundleID: selfBundleID
        )

        #expect(media.micActive == true)
        #expect(media.audioInputProcesses.map(\.bundleID) == ["com.microsoft.teams2"])

        let candidate = resolver().resolve(MeetingSignalSnapshot(
            micActive: media.micActive,
            cameraActive: media.cameraActive,
            calendarEvent: CalendarEventContext(id: "evt-standup", title: "Standup"),
            runningApps: [
                RunningAppInfo(bundleID: "com.microsoft.teams2", isActive: false),
            ],
            browserMeetings: [],
            audioInputProcesses: media.audioInputProcesses,
            foregroundBundleID: nil,
            now: now
        ))

        #expect(candidate?.platform == .teams)
        #expect(candidate?.sourceBundleID == "com.microsoft.teams2")
    }

    @Test("Muesli camera does not satisfy calendar meeting activity")
    func muesliCameraDoesNotSatisfyCalendarMeetingActivity() {
        let media = MeetingMediaSignalFilter.apply(
            deviceMicActive: false,
            cameraActive: true,
            audioInputProcesses: [],
            sensorAttributions: sensorAttributions(cameraBundleIDs: [selfBundleID]),
            selfBundleID: selfBundleID
        )

        #expect(media.cameraActive == false)
        #expect(media.hasMicOrCameraSignal == false)

        let candidate = resolver().resolve(MeetingSignalSnapshot(
            micActive: media.micActive,
            cameraActive: media.cameraActive,
            calendarEvent: CalendarEventContext(id: "evt-standup", title: "Standup"),
            runningApps: [
                RunningAppInfo(bundleID: "us.zoom.xos", isActive: false),
            ],
            browserMeetings: [],
            audioInputProcesses: media.audioInputProcesses,
            foregroundBundleID: nil,
            now: now
        ))

        #expect(candidate == nil)
    }

    @Test("external camera attribution still counts")
    func externalCameraAttributionStillCounts() {
        let media = MeetingMediaSignalFilter.apply(
            deviceMicActive: false,
            cameraActive: true,
            audioInputProcesses: [],
            sensorAttributions: sensorAttributions(cameraBundleIDs: [selfBundleID, "us.zoom.xos"]),
            selfBundleID: selfBundleID
        )

        #expect(media.cameraActive == true)
        #expect(media.hasMicOrCameraSignal == true)
    }

    @Test("legacy global mic signal is preserved without self attribution")
    func legacyGlobalMicSignalIsPreservedWithoutSelfAttribution() {
        let media = MeetingMediaSignalFilter.apply(
            deviceMicActive: true,
            cameraActive: false,
            audioInputProcesses: [],
            sensorAttributions: sensorAttributions(),
            selfBundleID: selfBundleID
        )

        #expect(media.micActive == true)
        #expect(media.audioInputProcesses.isEmpty)
    }

    @Test("self helper audio input is treated as Muesli")
    func selfHelperAudioInputIsTreatedAsMuesli() {
        let media = MeetingMediaSignalFilter.apply(
            deviceMicActive: true,
            cameraActive: false,
            audioInputProcesses: [
                audioProcess(bundleID: "\(selfBundleID).helper", appName: "Muesli Helper"),
            ],
            sensorAttributions: sensorAttributions(),
            selfBundleID: selfBundleID
        )

        #expect(media.micActive == false)
        #expect(media.audioInputProcesses.isEmpty)
    }
}

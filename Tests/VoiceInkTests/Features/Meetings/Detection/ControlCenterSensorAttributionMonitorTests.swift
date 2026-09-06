// Ported verbatim from Muesli-HQ/muesli (native/MuesliNative/Tests/MuesliTests/ControlCenterSensorAttributionMonitorTests.swift),
// adapted only to import VoiceInk instead of MuesliNativeApp — see below.
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

@Suite("ControlCenterSensorAttributionMonitor")
struct ControlCenterSensorAttributionMonitorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("parses active mic and camera bundle attributions")
    func parsesActiveMicAndCameraBundleAttributions() {
        let snapshot = ControlCenterSensorAttributionMonitor.parseSnapshot(
            from: #"2026-05-01 ControlCenter[695] [com.apple.controlcenter:sensor-indicators] Active activity attributions changed to ["cam:com.google.Chrome", "mic:com.google.Chrome"]"#,
            now: now
        )

        #expect(snapshot?.micBundleIDs == ["com.google.Chrome"])
        #expect(snapshot?.cameraBundleIDs == ["com.google.Chrome"])
        #expect(snapshot?.observedAt == now)
    }

    @Test("parses empty active attribution list")
    func parsesEmptyActiveAttributionList() {
        let snapshot = ControlCenterSensorAttributionMonitor.parseSnapshot(
            from: #"2026-05-01 ControlCenter[695] [com.apple.controlcenter:sensor-indicators] Active activity attributions changed to []"#,
            now: now
        )

        #expect(snapshot?.micBundleIDs.isEmpty == true)
        #expect(snapshot?.cameraBundleIDs.isEmpty == true)
        #expect(snapshot?.observedAt == now)
    }

    @Test("ignores unrelated sensor log lines")
    func ignoresUnrelatedSensorLogLines() {
        let snapshot = ControlCenterSensorAttributionMonitor.parseSnapshot(
            from: #"2026-05-01 ControlCenter[695] [com.apple.controlcenter:sensor-indicators] Recent activity attributions changed to ["mic:com.google.Chrome"]"#,
            now: now
        )

        #expect(snapshot == nil)
    }
}

// Ported verbatim from Muesli-HQ/muesli
// (native/MuesliNative/Sources/MuesliNativeApp/RunningApplicationStore.swift).
// Not in the task's original file list — added because `MeetingMonitor.swift` constructs
// `RunningApplicationStore()` directly and cannot compile without it. Small, self-contained
// (AppKit + Foundation only, NSWorkspace notifications, no polling) — part of the same
// detection engine, not an unrelated subsystem. See MeetingDetectionPortReport in this PR
// description / FORK-PATCHES.md for the full dependency-closure justification.
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

import AppKit
import Foundation

struct RunningApplicationState {
    let runningApps: [RunningAppSnapshot]
    let foregroundBundleID: String?
}

@MainActor
final class RunningApplicationStore {
    var onChanged: ((MeetingDetectionTrigger) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var runningApps: [RunningAppSnapshot] = []
    private var foregroundBundleID: String?
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        refreshState()

        let notificationCenter = NSWorkspace.shared.notificationCenter
        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshState()
                self?.onChanged?(.workspaceActivated)
            }
        })

        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshState()
                self?.onChanged?(.workspaceActivated)
            }
        })

        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshState()
                self?.onChanged?(.workspaceActivated)
            }
        })
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        let notificationCenter = NSWorkspace.shared.notificationCenter
        observers.forEach { notificationCenter.removeObserver($0) }
        observers.removeAll()
        runningApps.removeAll()
        foregroundBundleID = nil
    }

    func snapshot() -> RunningApplicationState {
        RunningApplicationState(
            runningApps: runningApps,
            foregroundBundleID: foregroundBundleID
        )
    }

    private func refreshState() {
        runningApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return RunningAppSnapshot(
                bundleID: bundleID,
                appName: app.localizedName ?? MeetingCandidateResolver.browserApps[bundleID] ?? bundleID,
                processIdentifier: app.processIdentifier,
                isActive: app.isActive
            )
        }
        foregroundBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

// Ported verbatim from Muesli-HQ/muesli
// (native/MuesliNative/Sources/MuesliNativeApp/ControlCenterSensorAttributionMonitor.swift).
// Not in the task's original file list — added because `MeetingMonitor.swift` constructs
// `ControlCenterSensorAttributionMonitor()` directly and cannot compile without it. Small,
// self-contained (Foundation + os only) — part of the same detection engine, not an unrelated
// subsystem. See MeetingDetectionPortReport in this PR description / FORK-PATCHES.md for the
// full dependency-closure justification.
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
import os

struct SensorAttributionSnapshot: Equatable {
    let micBundleIDs: Set<String>
    let cameraBundleIDs: Set<String>
    let observedAt: Date?

    static let empty = SensorAttributionSnapshot(
        micBundleIDs: [],
        cameraBundleIDs: [],
        observedAt: nil
    )
}

final class ControlCenterSensorAttributionMonitor {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingDetection")
    private static let attributionRegex = try? NSRegularExpression(pattern: #""(mic|cam):([^"]+)""#)

    var onAttributionsChanged: (() -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var outputPipe: Pipe?
    private var lineBuffer = ""
    private var currentSnapshot = SensorAttributionSnapshot.empty

    func start() {
        lock.lock()
        let alreadyRunning = process != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--style",
            "compact",
            "--level",
            "debug",
            "--predicate",
            "subsystem == \"com.apple.controlcenter\" && category == \"sensor-indicators\" && eventMessage BEGINSWITH \"Active activity attributions changed to \"",
        ]
        process.standardOutput = pipe
        process.standardError = Pipe()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            self?.consume(text)
        }

        process.terminationHandler = { [weak self] _ in
            self?.clearProcess()
        }

        do {
            try process.run()
            Self.logger.notice("sensor_attribution_stream_started")
            lock.lock()
            self.process = process
            outputPipe = pipe
            lock.unlock()
        } catch {
            Self.logger.error("sensor_attribution_stream_failed error=\(String(describing: error), privacy: .public)")
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    func stop() {
        lock.lock()
        let runningProcess = process
        let pipe = outputPipe
        process = nil
        outputPipe = nil
        lineBuffer = ""
        currentSnapshot = .empty
        lock.unlock()

        pipe?.fileHandleForReading.readabilityHandler = nil
        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }

    func snapshot(maxAge: TimeInterval = 8, now: Date = Date()) -> SensorAttributionSnapshot {
        lock.lock()
        let snapshot = currentSnapshot
        lock.unlock()

        guard let observedAt = snapshot.observedAt,
              now.timeIntervalSince(observedAt) <= maxAge else {
            return .empty
        }
        return snapshot
    }

    private func consume(_ text: String) {
        let lines: [String]
        lock.lock()
        lineBuffer += text
        let parts = lineBuffer.split(separator: "\n", omittingEmptySubsequences: false)
        if lineBuffer.hasSuffix("\n") {
            lines = parts.map(String.init)
            lineBuffer = ""
        } else {
            lines = parts.dropLast().map(String.init)
            lineBuffer = parts.last.map(String.init) ?? ""
        }
        lock.unlock()

        for line in lines {
            guard let snapshot = Self.parseSnapshot(from: line) else { continue }
            lock.lock()
            currentSnapshot = snapshot
            let callback = onAttributionsChanged
            lock.unlock()
            logSnapshot(snapshot)
            callback?()
        }
    }

    private func clearProcess() {
        lock.lock()
        process = nil
        outputPipe = nil
        lineBuffer = ""
        lock.unlock()
    }

    private func logSnapshot(_ snapshot: SensorAttributionSnapshot) {
        let mic = snapshot.micBundleIDs.sorted().joined(separator: ",")
        let camera = snapshot.cameraBundleIDs.sorted().joined(separator: ",")
        if mic.isEmpty && camera.isEmpty {
            Self.logger.notice("sensor_attributions_cleared")
        } else {
            Self.logger.notice("sensor_attributions mic=\(mic, privacy: .public) camera=\(camera, privacy: .public)")
        }
    }

    static func parseSnapshot(from line: String, now: Date = Date()) -> SensorAttributionSnapshot? {
        guard let range = line.range(of: "Active activity attributions changed to [") else {
            return nil
        }

        let tail = line[range.upperBound...]
        guard let closingBracket = tail.firstIndex(of: "]") else { return nil }
        let payload = tail[..<closingBracket]

        var micBundleIDs = Set<String>()
        var cameraBundleIDs = Set<String>()
        guard let regex = attributionRegex else { return nil }
        let nsPayload = NSString(string: String(payload))
        let matches = regex.matches(
            in: String(payload),
            range: NSRange(location: 0, length: nsPayload.length)
        )

        for match in matches where match.numberOfRanges == 3 {
            let kind = nsPayload.substring(with: match.range(at: 1))
            let bundleID = nsPayload.substring(with: match.range(at: 2))
            if kind == "mic" {
                micBundleIDs.insert(bundleID)
            } else if kind == "cam" {
                cameraBundleIDs.insert(bundleID)
            }
        }

        return SensorAttributionSnapshot(
            micBundleIDs: micBundleIDs,
            cameraBundleIDs: cameraBundleIDs,
            observedAt: now
        )
    }
}

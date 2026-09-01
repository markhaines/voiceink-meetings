// Ported verbatim from Muesli-HQ/muesli (native/MuesliNative/Sources/MuesliNativeApp/MeetingChunkTimingTracker.swift).
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

struct MeetingChunkTimingSnapshot: Equatable, Sendable {
    let startSampleIndex: Int64
    let sampleCount: Int64

    var startTimeSeconds: TimeInterval {
        Double(startSampleIndex) / Double(MeetingChunkTimingTracker.sampleRate)
    }

    var durationSeconds: TimeInterval {
        Double(sampleCount) / Double(MeetingChunkTimingTracker.sampleRate)
    }
}

struct MeetingChunkTimingTracker: Sendable {
    static let sampleRate = 16_000

    private var currentChunkStartSampleIndex: Int64?
    private var currentChunkSampleCount: Int64 = 0

    mutating func start() {
        currentChunkStartSampleIndex = 0
        currentChunkSampleCount = 0
    }

    mutating func append(sampleCount: Int) {
        guard sampleCount > 0, currentChunkStartSampleIndex != nil else { return }
        currentChunkSampleCount += Int64(sampleCount)
    }

    mutating func rotate() -> MeetingChunkTimingSnapshot? {
        guard let currentChunkStartSampleIndex else { return nil }
        let snapshot = MeetingChunkTimingSnapshot(
            startSampleIndex: currentChunkStartSampleIndex,
            sampleCount: currentChunkSampleCount
        )
        self.currentChunkStartSampleIndex = currentChunkStartSampleIndex + currentChunkSampleCount
        currentChunkSampleCount = 0
        return snapshot
    }

    mutating func finish() -> MeetingChunkTimingSnapshot? {
        guard let startSampleIndex = currentChunkStartSampleIndex else { return nil }
        let snapshot = MeetingChunkTimingSnapshot(
            startSampleIndex: startSampleIndex,
            sampleCount: currentChunkSampleCount
        )
        currentChunkStartSampleIndex = nil
        currentChunkSampleCount = 0
        return snapshot
    }

    mutating func discard() {
        currentChunkStartSampleIndex = nil
        currentChunkSampleCount = 0
    }
}

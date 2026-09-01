// Extracted verbatim from Muesli-HQ/muesli
// (native/MuesliNative/Sources/MuesliNativeApp/MeetingSessionDiagnostics.swift, lines 5-52)
// into its own file. The rest of MeetingSessionDiagnostics.swift is NOT ported here — a
// reduced version of it lands in Stage 2. AudioSampleStatsSnapshot travels with it because
// AudioSampleStats.snapshot() returns one; they are not independently useful.
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

struct AudioSampleStatsSnapshot: Codable {
    let sampleCount: Int
    let zeroSampleCount: Int
    let rms: Double
    let peak: Double
}

struct AudioSampleStats: Codable {
    private(set) var sampleCount = 0
    private(set) var zeroSampleCount = 0
    private(set) var sumSquares: Double = 0
    private(set) var peak: Double = 0

    mutating func addInt16(_ samples: [Int16]) {
        for sample in samples {
            addInt16Sample(sample)
        }
    }

    mutating func addInt16Sample(_ sample: Int16) {
        let value = Double(sample) / 32768.0
        addNormalizedSample(value)
    }

    mutating func addFloats(_ samples: [Float]) {
        for sample in samples {
            addNormalizedSample(Double(sample))
        }
    }

    private mutating func addNormalizedSample(_ sample: Double) {
        sampleCount += 1
        if sample == 0 {
            zeroSampleCount += 1
        }
        sumSquares += sample * sample
        peak = max(peak, abs(sample))
    }

    func snapshot() -> AudioSampleStatsSnapshot {
        AudioSampleStatsSnapshot(
            sampleCount: sampleCount,
            zeroSampleCount: zeroSampleCount,
            rms: sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0,
            peak: peak
        )
    }
}

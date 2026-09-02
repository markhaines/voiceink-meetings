// Ported from Muesli-HQ/muesli (native/MuesliNative/Sources/MuesliNativeApp/MeetingSessionDiagnostics.swift).
// That donor file also declares AudioSampleStats/AudioSampleStatsSnapshot (already ported to
// this fork's AudioSampleStats.swift), SystemAudioCaptureDiagnosticsSnapshot (owned by the
// system-audio capture port), and the MeetingSessionDiagnostics aggregator class (owned by the
// MeetingSession integration port). This file carries only the AEC-owned slice: the types
// MeetingNeuralAec.swift's diagnosticsSnapshot depends on. Otherwise verbatim.
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

struct MeetingAecDiagnosticsSnapshot: Codable {
    let ready: Bool
    /// Active AEC backend name (`localvqe`, `dtln`, or nil when unloaded).
    let processor: String?
    /// Model hop/frame size in samples (LocalVQE=256, DTLN=512, 0=unloaded).
    let frameSize: Int
    let processedFrames: Int
    let fullReferenceFrames: Int
    let partialReferenceFrames: Int
    let missingReferenceFrames: Int
    let systemSamplesReceived: Int
    let micSamplesReceived: Int
    let bufferedSystemSamples: Int
    let bufferedMicSamples: Int
    let currentDelayMs: Int
    let delayHistory: [MeetingAecDelayObservation]
    let delaySkipHistory: [MeetingAecDelaySkip]
}

extension MeetingAecDiagnosticsSnapshot {
    private enum CodingKeys: String, CodingKey {
        case ready
        case processor
        case frameSize
        case processedFrames
        case fullReferenceFrames
        case partialReferenceFrames
        case missingReferenceFrames
        case systemSamplesReceived
        case micSamplesReceived
        case bufferedSystemSamples
        case bufferedMicSamples
        case currentDelayMs
        case delayHistory
        case delaySkipHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ready = try container.decode(Bool.self, forKey: .ready)
        processor = try container.decodeIfPresent(String.self, forKey: .processor)
        frameSize = try container.decodeIfPresent(Int.self, forKey: .frameSize) ?? 0
        processedFrames = try container.decode(Int.self, forKey: .processedFrames)
        fullReferenceFrames = try container.decode(Int.self, forKey: .fullReferenceFrames)
        partialReferenceFrames = try container.decode(Int.self, forKey: .partialReferenceFrames)
        missingReferenceFrames = try container.decode(Int.self, forKey: .missingReferenceFrames)
        systemSamplesReceived = try container.decode(Int.self, forKey: .systemSamplesReceived)
        micSamplesReceived = try container.decode(Int.self, forKey: .micSamplesReceived)
        bufferedSystemSamples = try container.decode(Int.self, forKey: .bufferedSystemSamples)
        bufferedMicSamples = try container.decode(Int.self, forKey: .bufferedMicSamples)
        currentDelayMs = try container.decode(Int.self, forKey: .currentDelayMs)
        delayHistory = try container.decode([MeetingAecDelayObservation].self, forKey: .delayHistory)
        delaySkipHistory = try container.decode([MeetingAecDelaySkip].self, forKey: .delaySkipHistory)
    }
}

struct MeetingAecDelayObservation: Codable {
    let delayMs: Int
    let appliedDelayMs: Int
    let score: Double
    let confidence: Double
    let comparedFrames: Int
    let decision: String
    let candidateScores: [MeetingAecDelayCandidateScore]
}

struct MeetingAecDelayCandidateScore: Codable {
    let delayMs: Int
    let score: Double
    let comparedFrames: Int
}

struct MeetingAecDelaySkip: Codable {
    let reason: String
    let micSamplesReceived: Int
    let systemSamplesReceived: Int
    let micHistoryStartSample: Int
    let systemHistoryStartSample: Int
    let comparableEndSample: Int?
    let validCandidateCount: Int
    let missingCandidateCount: Int
    let lowActiveCandidateCount: Int
    let systemWindowSamples: Int
    let systemPeak: Double?
}

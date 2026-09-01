// Extracted verbatim from Muesli-HQ/muesli
// (native/MuesliNative/Sources/MuesliNativeApp/MeetingSessionDiagnostics.swift, lines 54-70)
// into its own file, alongside AudioSampleStats.swift (same donor file, landed in Stage 0). The
// rest of MeetingSessionDiagnostics.swift is NOT ported here — it is MeetingSession-owned
// aggregation (AEC delay estimation, diarization counts, chunk health, the MeetingSessionDiagnostics
// class itself) and lands in a later stage. This slice is pulled forward because
// CoreAudioSystemRecorder.swift and SystemAudioRecorder.swift both conform to
// SystemAudioDiagnosticsProviding and return a SystemAudioCaptureDiagnosticsSnapshot from their
// `diagnosticsSnapshot` property — porting those two files verbatim (as this stage requires) is
// not possible without these two types existing. Both are pure, self-contained data/protocol
// declarations with no reference to AEC, diarization, or MeetingSession state, so extracting them
// now does not anticipate or collide with the later stage's design the way inventing a shape for
// a not-yet-built subsystem would.
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

struct SystemAudioCaptureDiagnosticsSnapshot: Codable {
    let backend: String
    let callbackCount: Int
    let bufferCount: Int
    let emptyBufferCount: Int
    let unsupportedFormatCount: Int
    let inputByteCount: Int
    let bytesWritten: Int
    let sourceSampleRate: Double
    let sourceChannels: UInt32
    let preConversion: AudioSampleStatsSnapshot
    let postConversion: AudioSampleStatsSnapshot
}

protocol SystemAudioDiagnosticsProviding {
    var diagnosticsSnapshot: SystemAudioCaptureDiagnosticsSnapshot { get }
}

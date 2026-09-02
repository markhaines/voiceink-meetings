// Extracted verbatim from Muesli-HQ/muesli
// (native/MuesliNative/Sources/MuesliNativeApp/TranscriptionRuntime.swift, lines 11-14)
// into its own file. MicTurnNormalizer and SystemTurnNormalizer both consume this type; the
// rest of TranscriptionRuntime.swift is not ported here. The donor's SpeechSegment field of
// this struct is this fork's existing VoiceInk/Features/Meetings/Models/SpeechSegment.swift
// (same three-field shape, already present for the parallel capture-core work), so only this
// wrapper needed extracting.
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

struct SpeechTranscriptionResult: Sendable {
    let text: String
    let segments: [SpeechSegment]
}

// Adapted from Muesli-HQ/muesli
// (native/MuesliNative/Tests/MuesliTests/PCMChunkRecorderTests.swift).
// Import line changed: `@testable import MuesliNativeApp` -> `@testable import VoiceInk`
// (this fork's module name). `rotatesChunks()` is otherwise byte-for-byte unchanged.
// `cancelRemovesTempFile()` is strengthened, not just adapted: the donor version only asserts
// `recorder.stop() == nil` after cancelling, which proves the recorder's in-memory state was
// reset but not that the temp WAV file was actually deleted from disk. This version also lists
// the scratch directory before and after `cancel()` to prove the file itself is gone, using a
// per-test UUID-suffixed directory name so the assertion can't be polluted by a leftover file
// from a previous run.
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

@Suite("PCMChunkRecorder")
struct PCMChunkRecorderTests {

    @Test("rotateFile finalizes the current chunk and starts a new one")
    func rotatesChunks() throws {
        let recorder = try PCMChunkRecorder(directoryName: "pcm-chunk-recorder-tests")
        recorder.append([100, 200, 300])

        let firstChunkURL = try #require(recorder.rotateFile())
        recorder.append([400, 500])
        let secondChunkURL = try #require(recorder.stop())

        #expect(try readMonoPCM16WAVSamples(from: firstChunkURL) == [100, 200, 300])
        #expect(try readMonoPCM16WAVSamples(from: secondChunkURL) == [400, 500])
    }

    @Test("cancel removes the in-progress chunk file")
    func cancelRemovesTempFile() throws {
        let directoryName = "pcm-chunk-recorder-tests-cancel-\(UUID().uuidString)"
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)

        let recorder = try PCMChunkRecorder(directoryName: directoryName)
        recorder.append([100, 200, 300])

        let filesBeforeCancel = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        #expect(filesBeforeCancel.count == 1)

        recorder.cancel()
        #expect(recorder.stop() == nil)

        let filesAfterCancel = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        #expect(filesAfterCancel.isEmpty)
    }

    private func readMonoPCM16WAVSamples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        let sampleBytes = data.subdata(in: 44..<data.count)
        return sampleBytes.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Int16.self)).map(Int16.init(littleEndian:))
        }
    }
}

// Adapted from Muesli-HQ/muesli
// (native/MuesliNative/Tests/MuesliTests/MeetingRecordingWriterTests.swift, 110 lines).
// Import line changed: `@testable import MuesliNativeApp` -> `@testable import VoiceInk`
// (this fork's module name). The five donor tests below `readMonoPCM16WAVSamples` (through
// `persistTemporaryRecordingTranscodesToM4AByDefault`) are otherwise byte-for-byte unchanged.
//
// Four tests added beyond the donor, per fork review: a transcode-failure path
// (`persistTemporaryRecordingSurfacesTranscodeFailure`), cancellation's in-memory state reset
// (`cancelResetsStateForSubsequentCalls`), cancellation's on-disk cleanup
// (`cancelDeletesTemporaryFileFromDisk`), and genuine two-queue concurrent appends
// (`concurrentAppendsPreserveOrderingAndCounts`). None need real audio hardware, so none use
// the `TEST_RUNNER_VOICEINK_CI` guard `AudioGraphExceptionBridgeTests.swift` uses. The suite is
// marked `.serialized` because two of the new tests diff `FileManager`'s listing of the shared
// `voiceinkmeetings-meeting-recordings` temp directory before and after an operation --
// `MeetingRecordingWriter.init()` takes no parameters (fixed donor API, not a fork-injectable
// directory like `PCMChunkRecorder(directoryName:)`), so every writer in this suite shares one
// directory, and Swift Testing's default parallel test execution would let one test's create/
// delete steps land inside another's before/after snapshot window.
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

import AVFoundation
import Foundation
import Testing
@testable import VoiceInk

@Suite("MeetingRecordingWriter", .serialized)
struct MeetingRecordingWriterTests {

    @Test("streaming writer merges mic and system samples incrementally")
    func writerMergesIncrementally() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1000, 2000, 3000, 4000])
        writer.appendSystem([3000, -2000])
        writer.appendSystem([500, 1500])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [2000, 0, 1750, 2750])
    }

    @Test("streaming writer flushes single-track tail on stop")
    func writerFlushesSingleTrackTail() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1200, -800, 400])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [1200, -800, 400])
    }

    @Test("pause boundary prevents unmatched samples from mixing across pause")
    func pauseBoundaryFlushesPendingSamples() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1000, 3000])
        writer.markPauseBoundary()
        writer.appendSystem([5000, 7000])

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == [1000, 3000, 5000, 7000])
    }

    @Test("persistTemporaryRecording moves the temp wav when WAV is selected")
    func persistTemporaryRecordingMovesWAVFile() async throws {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem([1200, -800, 400])
        let tempURL = try #require(writer.stop())
        let supportDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        let savedURL = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: tempURL,
            meetingTitle: "Weekly Product Sync! With Very Long Title Extra Words",
            startedAt: startedAt,
            supportDirectory: supportDirectory,
            fileFormat: .wav
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
        #expect(savedURL.deletingLastPathComponent().lastPathComponent == "meeting-recordings")
        #expect(savedURL.lastPathComponent.hasSuffix("-weekly-product-sync-with-very-long.wav"))
        #expect(try readMonoPCM16WAVSamples(from: savedURL) == [1200, -800, 400])
    }

    @Test("persistTemporaryRecording transcodes to M4A by default")
    func persistTemporaryRecordingTranscodesToM4AByDefault() async throws {
        let writer = try MeetingRecordingWriter()
        writer.appendSystem(Array(repeating: Int16(1200), count: 16_000))
        let tempURL = try #require(writer.stop())
        let supportDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        let savedURL = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
            from: tempURL,
            meetingTitle: "Weekly Product Sync",
            startedAt: startedAt,
            supportDirectory: supportDirectory
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
        #expect(savedURL.pathExtension == "m4a")
        #expect(savedURL.deletingLastPathComponent().lastPathComponent == "meeting-recordings")
        #expect(savedURL.lastPathComponent.hasSuffix("-weekly-product-sync.m4a"))

        let file = try AVAudioFile(forReading: savedURL)
        #expect(file.length > 0)
    }

    @Test("persistTemporaryRecording throws and preserves the temp recording when the M4A transcode fails")
    func persistTemporaryRecordingSurfacesTranscodeFailure() async throws {
        let sourceDirectory = makeTemporaryDirectory()
        let tempURL = sourceDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try Data("not a real wav file".utf8).write(to: tempURL)
        let supportDirectory = makeTemporaryDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_711_000_000)

        await #expect(throws: (any Error).self) {
            _ = try await MeetingRecordingWriter.persistTemporaryRecordingAsync(
                from: tempURL,
                meetingTitle: "Broken Recording",
                startedAt: startedAt,
                supportDirectory: supportDirectory
            )
        }

        // The temp recording must survive a failed transcode -- it is the only copy of the
        // meeting, and losing it on a failed export would make the recording unrecoverable.
        #expect(FileManager.default.fileExists(atPath: tempURL.path) == true)

        let recordingsDirectory = supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        let leftoverM4As = (try? FileManager.default.contentsOfDirectory(atPath: recordingsDirectory.path))?
            .filter { $0.hasSuffix(".m4a") } ?? []
        #expect(leftoverM4As.isEmpty)
    }

    @Test("cancel resets in-memory state so a later stop returns nil and further appends stay inert")
    func cancelResetsStateForSubsequentCalls() throws {
        let writer = try MeetingRecordingWriter()
        writer.appendMic([1000, 2000])

        writer.cancel()
        #expect(writer.stop() == nil)

        // Appends after cancel must not resurrect a file handle or crash.
        writer.appendMic([100])
        writer.appendSystem([200])
        #expect(writer.stop() == nil)
    }

    @Test("cancel deletes the in-progress temporary recording file from disk")
    func cancelDeletesTemporaryFileFromDisk() throws {
        let recordingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceinkmeetings-meeting-recordings", isDirectory: true)
        let filesBefore = existingFileNames(in: recordingsDirectory)

        let writer = try MeetingRecordingWriter()
        writer.appendMic([1000, 2000, 3000])

        let createdFiles = existingFileNames(in: recordingsDirectory).subtracting(filesBefore)
        #expect(createdFiles.count == 1)
        let createdFileName = try #require(createdFiles.first)
        let createdFileURL = recordingsDirectory.appendingPathComponent(createdFileName)
        #expect(FileManager.default.fileExists(atPath: createdFileURL.path) == true)

        writer.cancel()

        #expect(FileManager.default.fileExists(atPath: createdFileURL.path) == false)
    }

    @Test("concurrent mic and system appends from separate queues do not lose or reorder samples")
    func concurrentAppendsPreserveOrderingAndCounts() throws {
        let writer = try MeetingRecordingWriter()
        let sampleCount = 4000
        let micSamples: [Int16] = (0..<sampleCount).map { Int16($0 % 1000) }
        let systemSamples: [Int16] = (0..<sampleCount).map { Int16(($0 % 1000) + 2000) }
        let expectedMixed: [Int16] = (0..<sampleCount).map { Int16(($0 % 1000) + 1000) }

        let micQueue = DispatchQueue(label: "meeting-recording-writer-tests.mic")
        let systemQueue = DispatchQueue(label: "meeting-recording-writer-tests.system")
        let group = DispatchGroup()

        group.enter()
        micQueue.async {
            var index = 0
            while index < micSamples.count {
                let end = min(index + 37, micSamples.count)
                writer.appendMic(Array(micSamples[index..<end]))
                index = end
            }
            group.leave()
        }

        group.enter()
        systemQueue.async {
            var index = 0
            while index < systemSamples.count {
                let end = min(index + 61, systemSamples.count)
                writer.appendSystem(Array(systemSamples[index..<end]))
                index = end
            }
            group.leave()
        }

        group.wait()

        let tempURL = try #require(writer.stop())
        let samples = try readMonoPCM16WAVSamples(from: tempURL)

        #expect(samples == expectedMixed)
    }

    private func existingFileNames(in directory: URL) -> Set<String> {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return Set(contents)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-writer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readMonoPCM16WAVSamples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        #expect(String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        let sampleBytes = data.subdata(in: 44..<data.count)
        let count = sampleBytes.count / MemoryLayout<Int16>.size
        return sampleBytes.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: Int16.self)
            return Array(buffer.prefix(count)).map(Int16.init(littleEndian:))
        }
    }
}

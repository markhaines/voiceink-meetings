// New for this fork (Stage 2c fix round, cross-vendor review finding B1). Not a port.
//
// B1's PROOF requirement was object-instance identity ("show that the meeting path obtains the
// SAME instance dictation uses"). Stated plainly: that specific proof is NOT possible in this
// environment. `FluidAudioMeetingSegmentTranscriber.resolveSharedManager()` and
// `TranscribeCppMeetingSegmentTranscriber.transcribe(chunkAt:)` both reach a real loaded model
// only by calling into `FluidAudioTranscriptionService.sharedAsrManager(for:)` /
// `OfflineTranscribeCppService.borrowModel(for:)`, which require real Parakeet CoreML models /
// a real transcribe-cpp GGUF file on disk -- neither is present in this environment, and this
// suite does not fake that (a faked identity check would prove nothing about the real path).
//
// What CAN be proven, and is proven here, is the structural half of B1: that neither adapter
// file constructs its OWN independent model/manager anymore. This is the same "cheap,
// deterministic static text scan" pattern `MeetingVadStreamsTests.swift` already uses in this
// repo for an analogous "a bypass must not exist in production code" property -- not a parser,
// a substring scan, with the same disclosed limits (does not catch a call reached only through a
// stored or partially-applied reference).

import Foundation
import Testing
@testable import VoiceInk

@Suite("Meeting transcription seam does not duplicate dictation's loaded models")
struct SharedModelDuplicationTests {

    @Test("FluidAudioMeetingSegmentTranscriber.swift no longer constructs its own AsrManager or loads its own AsrModels")
    func fluidAudioAdapterDoesNotLoadItsOwnModels() throws {
        let offenders = try Self.scanFile("FluidAudioMeetingSegmentTranscriber.swift", forSubstrings: [
            "AsrModels.load(",
            "AsrManager(config:",
        ])

        #expect(
            offenders.isEmpty,
            """
            FluidAudioMeetingSegmentTranscriber.swift appears to construct its own AsrManager/AsrModels \
            again, which is exactly the permanent model duplication B1 fixed:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("FluidAudioMeetingSegmentTranscriber.swift reaches models only through the shared accessor")
    func fluidAudioAdapterUsesTheSharedAccessor() throws {
        let contents = try Self.readFile("FluidAudioMeetingSegmentTranscriber.swift")
        #expect(contents.contains("sharedService.sharedAsrManager(for:"))
    }

    @Test("TranscribeCppMeetingSegmentTranscriber.swift no longer constructs its own native Model or initializes backends itself")
    func transcribeCppAdapterDoesNotLoadItsOwnModel() throws {
        // Needles are actual call-site shapes (constructor / static-function calls), not bare
        // lock-property names -- those names legitimately appear in this file's own explanatory
        // header comment (describing what B1/B2 fixed), which would false-positive a plain
        // substring scan.
        let offenders = try Self.scanFile("TranscribeCppMeetingSegmentTranscriber.swift", forSubstrings: [
            "Model(path:",
            "Transcribe.initBackends(",
            ".modelInitializationLock.withLock",
            ".backendInitializationLock.withLock",
        ])

        #expect(
            offenders.isEmpty,
            """
            TranscribeCppMeetingSegmentTranscriber.swift appears to construct its own native Model \
            and/or call its own process-wide init locks again -- exactly the permanent duplication \
            AND the parallel-lock bypass B1/B2 fixed:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("TranscribeCppMeetingSegmentTranscriber.swift reaches its model only through the shared borrow accessor")
    func transcribeCppAdapterUsesTheSharedAccessor() throws {
        let contents = try Self.readFile("TranscribeCppMeetingSegmentTranscriber.swift")
        #expect(contents.contains("sharedService.borrowModel(for:"))
        #expect(contents.contains("borrowed.release()"))
    }

    // MARK: - Scan helpers

    private static func scanFile(_ fileName: String, forSubstrings needles: [String]) throws -> [String] {
        let contents = try readFile(fileName)
        return needles.compactMap { contents.contains($0) ? "\(fileName): \($0)" : nil }
    }

    private static func readFile(_ fileName: String) throws -> String {
        // Resolve the repo root from this test file's own path, so this works regardless of
        // where the repo is checked out (a local Mac vs. a CI runner).
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()  // SharedModelDuplicationTests.swift -> Transcription/
            .deletingLastPathComponent()  // Transcription/ -> Meetings/
            .deletingLastPathComponent()  // Meetings/ -> Features/
            .deletingLastPathComponent()  // Features/ -> VoiceInkTests/
            .deletingLastPathComponent()  // Tests/VoiceInkTests -> Tests/
            .deletingLastPathComponent()  // Tests/ -> repo root
        let path = repoRoot
            .appendingPathComponent("VoiceInk/Features/Meetings/Transcription", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)

        guard FileManager.default.fileExists(atPath: path.path) else {
            Issue.record("could not resolve \(fileName) from #filePath -- repo layout may have changed")
            return ""
        }
        return try String(contentsOf: path, encoding: .utf8)
    }
}

// New for this fork (Stage 2c fix round, cross-vendor review finding B1). Not a port.
//
// WHAT THIS SUITE IS, AND EXPLICITLY IS NOT. It is a regression tripwire over the TEXT of two
// adapter files. It is NOT an identity proof, and review has already recorded that it cannot be
// one -- indirection defeats a substring scan (a call reached through a stored or
// partially-applied reference matches nothing here), and no static scan can show that a
// composition root injects the same instance into dictation and into the meeting seam. That
// language is deliberate and must not be upgraded: the accepted position is that this catches a
// regression, not that it proves the property.
//
// The identity proof B1 originally asked for ("show the meeting path obtains the SAME instance
// dictation uses") is not possible here: both accessors only produce a real manager against real
// Parakeet CoreML models / a real transcribe-cpp GGUF file, neither of which exists in this
// environment, and this suite does not fake that -- a faked identity check would prove nothing
// about the real path.
//
// The structural half that IS proven elsewhere, and is much stronger than this scan:
// `scripts/negative-controls/FluidAudioSharedModelAttacks.swift` is compiled into the app target
// on every CI run and MUST NOT COMPILE. That is a compiler-enforced statement that the
// eviction-capable methods on `FluidAudioTranscriptionService` are unreachable, which no amount
// of text scanning could establish. This file covers the complementary, weaker question of
// whether the adapters have started doing their own loading again.

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

    @Test("FluidAudioMeetingSegmentTranscriber.swift reaches models only through the borrow-only accessor")
    func fluidAudioAdapterUsesTheSharedAccessor() throws {
        let contents = try Self.readFile("FluidAudioMeetingSegmentTranscriber.swift")
        // `borrowedAsrManager()` takes no argument by construction (fix round 3, B1): there is
        // no version to pass, so the meeting seam cannot request a switch. Asserting the exact
        // no-argument call shape means reintroducing a parameterised accessor would fail here as
        // well as failing the negative control.
        #expect(contents.contains("borrowing.borrowedAsrManager()"))
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

    @Test("FluidAudioMeetingSegmentTranscriber.swift holds the narrow capability, never the concrete service")
    func fluidAudioAdapterHoldsOnlyTheCapability() throws {
        // B4.1. Round 3's third guarantee ("it calls nothing ... those remain private") was false
        // while this file stored `FluidAudioTranscriptionService`, because `cleanup()` is
        // internal. The enforced version of that guarantee is that the adapter is handed
        // `any MeetingAsrManagerBorrowing` instead, whose surface is one getter -- see
        // `scripts/negative-controls/FluidAudioSharedModelAttacks.swift`, which is the actual
        // enforcement. This scan is the cheap tripwire for the storage type going back.
        let contents = try Self.readFile("FluidAudioMeetingSegmentTranscriber.swift")
        #expect(contents.contains("borrowing: any MeetingAsrManagerBorrowing"))
        #expect(contents.contains("private nonisolated let borrow: MeetingAsrManagerBorrow"))

        let offenders = try Self.scanFile("FluidAudioMeetingSegmentTranscriber.swift", forSubstrings: [
            ": FluidAudioTranscriptionService",
        ])
        #expect(
            offenders.isEmpty,
            """
            FluidAudioMeetingSegmentTranscriber.swift stores the concrete transcription service \
            again, which re-exposes cleanup()/loadModel(for:) to the meeting seam:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("FluidAudioMeetingDiarizer.swift does not retroactively conform a FluidAudio package type to Sendable")
    func diarizerDoesNotRetroactivelyConformAPackageType() throws {
        // B3. Round 2 shipped `extension DiarizerManager: @unchecked Sendable {}` in production
        // code: a MODULE-WIDE promise about a third-party mutable class, inherited silently by
        // every future FluidAudio bump, no matter what the comment above it said.
        //
        // This is a TEXT SCAN and nothing more, for a reason worth recording rather than
        // glossing: the natural compile-time control ("assert `DiarizerManager` is not
        // `Sendable`") does not work in this target, which builds in the Swift 5 language mode
        // where a missing `Sendable` conformance is a warning, not an error. It was tried in
        // `scripts/negative-controls/FluidAudioSharedModelAttacks.swift` and produced no
        // diagnostic at all. So this catches the exact regression by name; it does not prove the
        // absence of every possible retroactive conformance.
        // The needle is anchored to a line start, for the same reason the transcribe-cpp scan
        // above uses call-site shapes: the file's own header comment quotes the offending
        // declaration verbatim while explaining what B3 was, and a bare substring scan
        // false-positived on that prose (it did, on the first run of this test).
        let offenders = try Self.scanFile(
            "FluidAudioMeetingDiarizer.swift",
            forSubstrings: ["\nextension DiarizerManager"]
        )

        #expect(
            offenders.isEmpty,
            """
            FluidAudioMeetingDiarizer.swift extends a FluidAudio package type again. B3 was \
            specifically about `extension DiarizerManager: @unchecked Sendable {}`; the scoped \
            `LoadedDiarizerBox` wrapper exists so that is not needed:
            \(offenders.joined(separator: "\n"))
            """
        )
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

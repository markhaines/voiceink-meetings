// Structural negative control for `TranscriptedAudioExporter`'s fault-injection seam.
//
// Compiled INTO THE APP TARGET by scripts/verify-meeting-store-isolation.sh, because the realistic
// attacker is same-module code: `@testable import` is not needed to reach an `internal` type, and
// the caller that will eventually drive this exporter lives in this very module.
//
// WHAT THIS DEFENDS. `export` takes a `faults:` parameter so the recovery branches in `commit` can
// be tested by FORCING their failures. An earlier design made that parameter a struct of
// `@Sendable` closures, and review defeated it in one line three separate ways -- a `move` that
// returned success without moving anything, a `move` that deleted the source and reported success,
// and a copy-then-delete substituted for `rename(2)` -- each of which let `export` return SUCCESS
// with the previous export silently destroyed, i.e. lose meeting audio without failing.
//
// The fix was to remove the capability rather than document it away: `FaultInjection` is a value
// type carrying NO CODE, so it can declare that a rename throws and nothing else. This file is the
// proof that the three attacks are no longer things nobody writes but things that DO NOT COMPILE.
// It is the fourth time on this project that a test-only seam was defended as safe-by-convention
// and then broken, which is why the guarantee is asserted by the compiler on every CI run instead
// of being asserted in a comment.

import Foundation

/// The three behaviours an attacker would need to substitute. They are ordinary, valid functions:
/// nothing here is malformed, and that is the point. The attacks below fail because there is
/// nowhere to PUT them, not because they are badly written.
enum TranscriptedAudioExportSeamAttackBehaviours {
    /// Attack 1: report success without moving anything.
    static func noOpMove(_ source: URL, _ destination: URL) throws {}

    /// Attack 2: delete the source and report success.
    static func destructiveMove(_ source: URL, _ destination: URL) throws {
        try FileManager.default.removeItem(at: source)
    }

    /// Attack 3: substitute a non-atomic copy-then-delete for `rename(2)`, voiding the atomicity
    /// the whole commit design rests on.
    static func copyThenDeleteMove(_ source: URL, _ destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.removeItem(at: source)
    }
}

enum TranscriptedAudioExportSeamAttacks {
    /// A1. The old behaviour-substituting type is gone entirely, so the shape that carried all
    /// three attacks cannot even be named.
    static func attackViaOldOperationsType() {
        // expect-error: type 'TranscriptedAudioExporter' has no member 'FileOperations'
        _ = TranscriptedAudioExporter.FileOperations.live
    }

    /// A2. NO-OP SUCCESSFUL MOVE, via assigning the operation onto the injected value.
    static func attackNoOpMoveByMemberAssignment(faults: inout TranscriptedAudioExporter.FaultInjection) {
        // expect-error: value of type 'TranscriptedAudioExporter.FaultInjection' has no member 'move'
        faults.move = TranscriptedAudioExportSeamAttackBehaviours.noOpMove
    }

    /// A3. DESTRUCTIVE SUCCESSFUL MOVE, via the initialiser.
    static func attackDestructiveMoveByInitialiser() {
        // expect-error: argument passed to call that takes no arguments
        _ = TranscriptedAudioExporter.FaultInjection(move: TranscriptedAudioExportSeamAttackBehaviours.destructiveMove)
    }

    /// A4. COPY-THEN-DELETE INSTEAD OF RENAME, by handing the operation straight to the parameter
    /// `export` actually accepts.
    static func attackCopyThenDeleteByParameterType() {
        // expect-error: cannot convert value of type '(URL, URL) throws -> ()' to specified type 'TranscriptedAudioExporter.FaultInjection'
        let faults: TranscriptedAudioExporter.FaultInjection = TranscriptedAudioExportSeamAttackBehaviours.copyThenDeleteMove
        _ = faults
    }

    /// A5. Bypass the seam entirely by calling the commit sequence directly.
    static func attackByCallingCommitDirectly(staging: URL, final: URL) throws {
        // expect-error: 'commit' is inaccessible due to 'private' protection level
        try TranscriptedAudioExporter.commit(stagingDirectory: staging, to: final, faults: .none)
    }

    /// A6. Bypass it by calling the single rename primitive directly.
    static func attackByCallingMoveDirectoryDirectly(source: URL, destination: URL) throws {
        // expect-error: 'moveDirectory' is inaccessible due to 'private' protection level
        try TranscriptedAudioExporter.moveDirectory(from: source, to: destination, faults: .none)
    }
}

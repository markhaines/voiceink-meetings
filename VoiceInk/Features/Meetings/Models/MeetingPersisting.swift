// Fork-only file, no donor equivalent: the donor (Muesli-HQ/muesli) has no persistence layer at
// all, so it has nothing to abstract here.
//
// WHY THIS EXISTS -- read before "simplifying" it back to a concrete `MeetingStore`.
//
// `MeetingEngine` previously took a `persistenceGateForTesting: (@Sendable ([SpeechSegment],
// MeetingSegmentChannel) async -> Void)?` closure on its initialiser purely so a test could
// suspend one persistence attempt and observe what `stop()` did while it was outstanding.
// Review rejected that seam: the stored property was `private`, but the INITIALISER PARAMETER
// was module-internal and accepted an arbitrary non-returning async closure, so any caller
// inside the app target -- production code included -- could suspend persistence, and with it
// `stop()`, indefinitely. A parameter whose only capability is "wedge the engine open" has no
// production purpose, so it is gone, not merely narrowed.
//
// What replaces it is an ordinary dependency-injection point of the kind `MeetingEngine`
// already has three of (`transcriptionCoordinator`, `meetingMicRecorder`,
// `systemAudioRecorderOverride`): the engine names its persistence dependency by protocol
// instead of by concrete type. `MeetingStore` conforms with no changes to `MeetingStore.swift`
// (that file, and its isolation guarantee, are untouched by this), so every production call
// site keeps passing a real `MeetingStore` and behaves exactly as before.
//
// The residual, stated plainly rather than glossed: a caller inside the app target can pass a
// hostile conforming type and make persistence hang or fail. That is inherent to dependency
// injection and is the SAME residual the engine already carries for its three other injected
// dependencies -- a hostile `MeetingTranscriptionCoordinating` can hang `stop()` just as well.
// The difference from the seam this replaces is that there is no longer any parameter that
// exists solely to suspend the engine and does nothing else: suspending persistence now costs a
// whole alternative persistence implementation, and every caller must supply SOMETHING here
// regardless, so the injection point is legible as a dependency rather than hidden as a hook.
//
// Deliberately NOT solved with `#if DEBUG`: the test bundle links the app target built in the
// same configuration a developer runs the app in, so a Debug-only seam is present in exactly
// the build the next integrator writes code against.

import Foundation

/// The persistence operations `MeetingEngine` needs. Exactly `MeetingStore`'s public surface,
/// no more: this is a naming indirection over the existing store, not a new abstraction layer
/// with its own opinions.
///
/// `Sendable` because `MeetingEngine` calls across concurrency domains (chunk tasks, the
/// rotation queue, `stop()`), matching `MeetingStore`'s own `Sendable` conformance.
protocol MeetingPersisting: Sendable {
    @discardableResult
    func startMeeting(title: String, audioDirectoryPath: String, startDate: Date) async throws -> MeetingHandle

    @discardableResult
    func appendSegment(
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        speakerLabel: String,
        text: String,
        sourceChannel: MeetingSegmentChannel,
        to meeting: MeetingHandle
    ) async throws -> MeetingSegmentHandle

    func updateDuration(_ duration: TimeInterval, for meeting: MeetingHandle) async throws
    func updateState(_ state: MeetingState, for meeting: MeetingHandle) async throws
    func finish(_ meeting: MeetingHandle, endDate: Date) async throws
    func markFailed(_ meeting: MeetingHandle) async throws
}

/// Conformance only -- every requirement is already satisfied by `MeetingStore`'s existing
/// methods, so this adds no code to the store and changes none of its behaviour. It cannot
/// weaken `MeetingStore`'s isolation guarantee either: the protocol exposes only methods that
/// were already `internal` on the struct, and reaches nothing `private` inside it.
extension MeetingStore: MeetingPersisting {}

// SHARED FOUNDATION TYPE — four parallel Stage-1 agents (capture core, mic+route, AEC,
// transcription-support) compile against this. Do not edit without coordinating across all
// of them; a signature or behavior change here can silently break work landing in parallel.
//
// Fork-local equivalent of Muesli-HQ/muesli's SpeechSegment
// (native/MuesliNative/Sources/MuesliNativeApp/TranscriptionRuntime.swift:5), NOT a verbatim
// port — it's an independent, tiny re-declaration of the same three-field shape, not copied
// text, so it carries no MIT attribution header. The donor task description called it
// "MuesliCore.SpeechSegment"; the real type actually lives in MuesliNativeApp, not the
// MuesliCore library target — worth noting since anyone re-reading the donor to extend this
// should look there, not in MuesliCore.
//
// Confirmed against every donor construction site (AudioFileImportController,
// AppleSpeechAnalyzerBackend, MeetingSession, MicTurnNormalizer, SystemTurnNormalizer,
// TranscriptFormatter, TranscriptReconciler, TranscriptionRuntime): always built with the
// same three labeled fields below, no additional stored state or methods anywhere. This is
// the whole type — resist adding anything to it speculatively.

import Foundation

struct SpeechSegment: Sendable {
    let start: Double
    let end: Double
    let text: String
}

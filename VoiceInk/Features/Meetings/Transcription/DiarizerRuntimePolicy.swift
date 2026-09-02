// Ported verbatim from Muesli-HQ/muesli (native/MuesliNative/Sources/MuesliNativeApp/DiarizerRuntimePolicy.swift),
// WITH ONE FLAGGED DEVIATION, called out again at its exact location below: this fork has no
// TelemetryDeck dependency (grep of Package.resolved / project.pbxproj confirms it — VoiceInk
// has no telemetry system at all yet), so `import TelemetryDeck` is dropped.
//
// The donor's `DiarizerPreloadDiagnostics.init` (donor lines 176-186) defaults `signalSink` to:
//   signalSink: @escaping SignalSink = { event, parameters in
//       TelemetryDeck.signal(event, parameters: parameters)
//   }
// That default cannot be ported verbatim — TelemetryDeck is out of scope this round (adding it
// would mean editing project.pbxproj and the package-trust file, both owned elsewhere). A prior
// round of this fork replaced it with a no-op closure; independent review correctly flagged that
// as an unacceptable silent behavior change — every production caller that relies on the default
// (i.e. every caller, since none of them pass an explicit sink) would lose every preload
// started/ready/failed/interrupted diagnostic with nothing to show it was ever dropped. Per that
// review's required fix, `signalSink` stays defaulted (matching the donor's own signature, so no
// call site is forced to change) but the default now emits through this fork's existing
// `os.Logger` facility instead of TelemetryDeck or nothing — the same
// `Logger(subsystem: "com.hainesy.voiceinkmeetings", category: ...)` convention used throughout
// the rest of the app (see e.g. `VoiceInk/App/VoiceInk.swift`). See `defaultSignalLogger` below
// for the exact substitution. Every call site in the ported test suite still supplies its own
// `signalSink`, so this default is only ever exercised by production code that hasn't been given
// one. Recorded in FORK-PATCHES.md's `phase-1-vad-chunking` section as well. Everything else,
// including every comment and the M1/macOS-15.1 GPU-avoidance branch, is byte-for-byte identical
// to the donor.
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

import CoreML
import Darwin
import FluidAudio
import Foundation
import os

enum DiarizerComputePolicy: String, Sendable, Equatable {
    case all
    case cpuAndNeuralEngine = "cpu_and_neural_engine"

    var computeUnits: MLComputeUnits {
        switch self {
        case .all:
            return .all
        case .cpuAndNeuralEngine:
            return .cpuAndNeuralEngine
        }
    }
}

enum DiarizerPreloadFailure: Error {
    case operationTimedOut
}

struct DiarizerRuntimeEnvironment: Sendable {
    let cpuBrand: String?
    let hardwareModel: String?
    let operatingSystemVersion: OperatingSystemVersion

    static func current(processInfo: ProcessInfo = .processInfo) -> DiarizerRuntimeEnvironment {
        DiarizerRuntimeEnvironment(
            cpuBrand: sysctlString("machdep.cpu.brand_string"),
            hardwareModel: sysctlString("hw.model"),
            operatingSystemVersion: processInfo.operatingSystemVersion
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }

        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(validatingCString: value)
    }
}

struct DiarizerRuntimePolicy: Sendable, Equatable {
    static let defaultCompatibilityRule = "default_v1"
    static let m1MacOS151CompatibilityRule = "m1_macos_15_1_gpu_avoidance_v1"

    // Fallback identifiers are used only if the CPU brand sysctl is unavailable.
    // The CPU brand remains the primary signal because it covers M1, M1 Pro, M1 Max,
    // and M1 Ultra without trying to infer the chip from every Mac product identifier.
    private static let m1HardwareModels: Set<String> = [
        "MacBookAir10,1",
        "MacBookPro17,1",
        "MacBookPro18,1",
        "MacBookPro18,2",
        "MacBookPro18,3",
        "MacBookPro18,4",
        "Macmini9,1",
        "iMac21,1",
        "iMac21,2",
        "Mac13,1",
        "Mac13,2",
    ]

    let computePolicy: DiarizerComputePolicy
    let compatibilityRule: String

    static func resolve(for environment: DiarizerRuntimeEnvironment) -> DiarizerRuntimePolicy {
        let version = environment.operatingSystemVersion
        let isMacOS151 = version.majorVersion == 15 && version.minorVersion == 1
        let isM1Family = environment.cpuBrand.map(isM1CPUBrand)
            ?? environment.hardwareModel.map(m1HardwareModels.contains)
            ?? false

        // Issue #344's crash stack enters MPSGraph/Metal while FluidAudio loads
        // the diarizer on M1 + macOS 15.1.x. Excluding GPU here leaves CoreML free
        // to use CPU/ANE fallbacks without slowing unaffected hardware and OSes.
        if isMacOS151, isM1Family {
            return DiarizerRuntimePolicy(
                computePolicy: .cpuAndNeuralEngine,
                compatibilityRule: m1MacOS151CompatibilityRule
            )
        }

        return DiarizerRuntimePolicy(
            computePolicy: .all,
            compatibilityRule: defaultCompatibilityRule
        )
    }

    var modelConfiguration: MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computePolicy.computeUnits
        return configuration
    }

    private static func isM1CPUBrand(_ value: String) -> Bool {
        let brand = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return brand == "Apple M1" || brand.hasPrefix("Apple M1 ")
    }
}

enum DiarizerPreloadTrigger: String, Sendable {
    case appLaunch = "app_launch"
    case audioImport = "audio_import"
    case backendChange = "backend_change"
    case meetingStart = "meeting_start"
    case modelLibrary = "model_library"
    case onboarding
    case retranscription
    case unspecified
}

enum DiarizerModelCacheState: String, Sendable {
    case absent
    case partial
    case complete

    static func resolve(
        directory: URL = DiarizerModels.defaultModelsDirectory(),
        requiredModelNames: Set<String> = DiarizerModels.requiredModelNames,
        fileManager: FileManager = .default
    ) -> DiarizerModelCacheState {
        let presentCount = requiredModelNames.reduce(into: 0) { count, modelName in
            if fileManager.fileExists(atPath: directory.appendingPathComponent(modelName).path) {
                count += 1
            }
        }

        if presentCount == 0 { return .absent }
        if presentCount == requiredModelNames.count { return .complete }
        return .partial
    }
}

struct DiarizerPreloadContext: Sendable {
    static let telemetrySchemaVersion = "1"
    // Keep synchronized with the exact FluidAudio pin in Package.swift.
    static let fluidAudioVersion = "0.15.1"

    let trigger: DiarizerPreloadTrigger
    let policy: DiarizerRuntimePolicy
    let cacheState: DiarizerModelCacheState

    var telemetryParameters: [String: String] {
        [
            "schema_version": Self.telemetrySchemaVersion,
            "trigger": trigger.rawValue,
            "compute_policy": policy.computePolicy.rawValue,
            "compatibility_rule": policy.compatibilityRule,
            "cache_state": cacheState.rawValue,
            "model_set": "pyannote_streaming",
            "fluid_audio_version": Self.fluidAudioVersion,
        ]
    }
}

struct DiarizerPreloadDiagnostics {
    typealias SignalSink = (_ event: String, _ parameters: [String: String]) -> Void

    private struct PendingAttempt: Codable {
        let startedAt: TimeInterval
        let parameters: [String: String]
    }

    static let pendingAttemptKey = "diarizerPreload.pendingAttempt.v1"

    // FLAGGED DEVIATION from the donor (see file-header note): stands in for
    // `TelemetryDeck.signal(event, parameters: parameters)` (donor lines 179-181), which this
    // fork cannot call — no TelemetryDeck dependency. Logs at `.default` level so preload
    // diagnostics remain visible in Console.app / `log stream --predicate 'subsystem ==
    // "com.hainesy.voiceinkmeetings"'` rather than vanishing, until a real telemetry backend
    // replaces this default. Interpolated with `privacy: .public` because event names and
    // parameter values here are all from the fixed, privacy-safe allowlist
    // `DiarizerPreloadContext.telemetryParameters` documents (schema_version/trigger/
    // compute_policy/compatibility_rule/cache_state/model_set/fluid_audio_version/
    // duration_bucket/failure_category) — never raw error text or user data.
    private static let defaultSignalLogger = Logger(
        subsystem: "com.hainesy.voiceinkmeetings",
        category: "DiarizerPreloadDiagnostics"
    )

    private let defaults: UserDefaults
    private let now: () -> Date
    private let signalSink: SignalSink

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        // FLAGGED DEVIATION from the donor (see file-header note): the donor's default here is
        // `{ event, parameters in TelemetryDeck.signal(event, parameters: parameters) }`. This
        // fork has no TelemetryDeck dependency yet, so the default logs through
        // `defaultSignalLogger` instead — a real, observable emission, never a no-op. Every
        // caller in the ported test suite supplies its own sink.
        signalSink: @escaping SignalSink = { event, parameters in
            Self.defaultSignalLogger.log("\(event, privacy: .public) \(String(describing: parameters), privacy: .public)")
        }
    ) {
        self.defaults = defaults
        self.now = now
        self.signalSink = signalSink
    }

    func reportInterruptedAttemptIfNeeded() {
        guard let data = defaults.data(forKey: Self.pendingAttemptKey),
              let pending = try? JSONDecoder().decode(PendingAttempt.self, from: data) else {
            clearPendingAttempt()
            return
        }

        clearPendingAttempt()
        var parameters = pending.parameters
        parameters["duration_bucket"] = Self.durationBucket(
            now().timeIntervalSince1970 - pending.startedAt
        )
        signalSink("diarizer.preload.interrupted", parameters)
    }

    @discardableResult
    func begin(_ context: DiarizerPreloadContext) -> Date {
        let startedAt = now()
        let pending = PendingAttempt(
            startedAt: startedAt.timeIntervalSince1970,
            parameters: context.telemetryParameters
        )
        if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: Self.pendingAttemptKey)
            // This marker must outlive an immediate SIGABRT during CoreML loading.
            // Preloads are rare enough that forcing this tiny preferences write is acceptable.
            defaults.synchronize()
        }
        signalSink("diarizer.preload.started", context.telemetryParameters)
        return startedAt
    }

    func ready(_ context: DiarizerPreloadContext, startedAt: Date) {
        finish(
            event: "diarizer.preload.ready",
            context: context,
            startedAt: startedAt,
            additionalParameters: [:]
        )
    }

    func failed(_ context: DiarizerPreloadContext, startedAt: Date, error: Error) {
        finish(
            event: "diarizer.preload.failed",
            context: context,
            startedAt: startedAt,
            additionalParameters: ["failure_category": Self.failureCategory(for: error)]
        )
    }

    func skipped(_ context: DiarizerPreloadContext, reason: String) {
        var parameters = context.telemetryParameters
        parameters["skip_reason"] = reason
        signalSink("diarizer.preload.skipped", parameters)
    }

    private func finish(
        event: String,
        context: DiarizerPreloadContext,
        startedAt: Date,
        additionalParameters: [String: String]
    ) {
        clearPendingAttempt()
        var parameters = context.telemetryParameters
        parameters["duration_bucket"] = Self.durationBucket(now().timeIntervalSince(startedAt))
        parameters.merge(additionalParameters) { _, new in new }
        signalSink(event, parameters)
    }

    private func clearPendingAttempt() {
        defaults.removeObject(forKey: Self.pendingAttemptKey)
        defaults.synchronize()
    }

    static func durationBucket(_ duration: TimeInterval) -> String {
        switch max(0, duration) {
        case ..<1: return "under_1s"
        case ..<5: return "1_to_5s"
        case ..<15: return "5_to_15s"
        case ..<60: return "15_to_60s"
        default: return "60s_or_more"
        }
    }

    static func failureCategory(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if error is DiarizerPreloadFailure { return "timeout" }
        if error is URLError { return "network" }

        if let diarizerError = error as? DiarizerError {
            switch diarizerError {
            case .modelDownloadFailed:
                return "model_download"
            case .modelCompilationFailed:
                return "model_compilation"
            case .memoryAllocationFailed:
                return "memory"
            case .notInitialized:
                return "not_initialized"
            case .embeddingExtractionFailed:
                return "embedding_extraction"
            case .invalidAudioData:
                return "invalid_audio"
            case .processingFailed, .invalidArrayBounds:
                return "processing"
            }
        }

        let nsError = error as NSError
        if nsError.domain.localizedCaseInsensitiveContains("coreml") {
            return "coreml"
        }
        if nsError.domain == NSCocoaErrorDomain,
           (NSFileErrorMinimum...NSFileErrorMaximum).contains(nsError.code) {
            return "filesystem"
        }
        return "other"
    }
}

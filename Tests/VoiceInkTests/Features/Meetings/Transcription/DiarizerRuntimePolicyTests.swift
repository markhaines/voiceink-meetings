// Adapted from Muesli-HQ/muesli
// (native/MuesliNative/Tests/MuesliTests/DiarizerRuntimePolicyTests.swift).
//
// Two suites ported verbatim below (`Diarizer runtime policy`, `Diarizer preload diagnostics`),
// with only the `@testable import MuesliNativeApp` -> `@testable import VoiceInk` module-name
// change. Neither suite ever relies on `DiarizerPreloadDiagnostics`'s default `signalSink`
// argument — every test constructs its own `SignalRecorder` and passes `signalSink:` explicitly
// — so they are unaffected by this fork's one flagged deviation in the production file (see
// DiarizerRuntimePolicy.swift's header: no TelemetryDeck dependency yet).
//
// The donor's third suite, `Diarizer preload coordination` (DiarizerPreloadCoordinationTests),
// is deliberately NOT ported here. It exercises `TranscriptionCoordinator` and `BackendOption`,
// which belong to the donor's TranscriptionRuntime/adapter layer that this stage was explicitly
// told not to build (that is a later stage's work). This is a disclosed exclusion, not a silent
// drop — see the Stage-1 vad-chunking report.
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

@Suite("Diarizer runtime policy")
struct DiarizerRuntimePolicyTests {
    @Test("M1 family on macOS 15.1 avoids GPU compute")
    func m1OnMacOS151UsesCPUAndNeuralEngine() {
        for cpuBrand in ["Apple M1", "Apple M1 Pro", "Apple M1 Max", "Apple M1 Ultra"] {
            let policy = DiarizerRuntimePolicy.resolve(
                for: environment(cpuBrand: cpuBrand, os: (15, 1, 1))
            )

            #expect(policy.computePolicy == .cpuAndNeuralEngine)
            #expect(policy.compatibilityRule == DiarizerRuntimePolicy.m1MacOS151CompatibilityRule)
        }
    }

    @Test("hardware model identifies M1 when CPU brand is unavailable")
    func hardwareModelFallback() {
        let policy = DiarizerRuntimePolicy.resolve(
            for: environment(
                cpuBrand: nil,
                hardwareModel: "MacBookPro17,1",
                os: (15, 1, 1)
            )
        )

        #expect(policy.computePolicy == .cpuAndNeuralEngine)
    }

    @Test("M1 on newer macOS keeps the default policy")
    func m1OnNewerMacOSUsesDefault() {
        let policy = DiarizerRuntimePolicy.resolve(
            for: environment(cpuBrand: "Apple M1", os: (15, 2, 0))
        )

        #expect(policy.computePolicy == .all)
        #expect(policy.compatibilityRule == DiarizerRuntimePolicy.defaultCompatibilityRule)
    }

    @Test("newer Apple silicon on macOS 15.1 keeps the default policy")
    func m2OnMacOS151UsesDefault() {
        let policy = DiarizerRuntimePolicy.resolve(
            for: environment(cpuBrand: "Apple M2", os: (15, 1, 1))
        )

        #expect(policy.computePolicy == .all)
    }

    @Test("cache state distinguishes absent, partial, and complete models")
    func cacheState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiarizerRuntimePolicyTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requiredModels: Set<String> = ["segmentation.mlmodelc", "embedding.mlmodelc"]

        #expect(
            DiarizerModelCacheState.resolve(
                directory: directory,
                requiredModelNames: requiredModels
            ) == .absent
        )

        try Data().write(to: directory.appendingPathComponent("segmentation.mlmodelc"))
        #expect(
            DiarizerModelCacheState.resolve(
                directory: directory,
                requiredModelNames: requiredModels
            ) == .partial
        )

        try Data().write(to: directory.appendingPathComponent("embedding.mlmodelc"))
        #expect(
            DiarizerModelCacheState.resolve(
                directory: directory,
                requiredModelNames: requiredModels
            ) == .complete
        )
    }

    private func environment(
        cpuBrand: String?,
        hardwareModel: String? = nil,
        os: (Int, Int, Int)
    ) -> DiarizerRuntimeEnvironment {
        DiarizerRuntimeEnvironment(
            cpuBrand: cpuBrand,
            hardwareModel: hardwareModel,
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: os.0,
                minorVersion: os.1,
                patchVersion: os.2
            )
        )
    }
}

@Suite("Diarizer preload diagnostics")
struct DiarizerPreloadDiagnosticsTests {
    private final class SignalRecorder {
        var events: [(String, [String: String])] = []

        func record(_ event: String, parameters: [String: String]) {
            events.append((event, parameters))
        }
    }

    @Test("uncleared attempt is reported as interrupted on next launch")
    func interruptedAttempt() throws {
        let suiteName = "DiarizerPreloadDiagnosticsTests.interrupted.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = SignalRecorder()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let context = makeContext()

        DiarizerPreloadDiagnostics(
            defaults: defaults,
            now: { startedAt },
            signalSink: recorder.record
        ).begin(context)
        DiarizerPreloadDiagnostics(
            defaults: defaults,
            now: { startedAt.addingTimeInterval(8) },
            signalSink: recorder.record
        ).reportInterruptedAttemptIfNeeded()

        #expect(recorder.events.map(\.0) == [
            "diarizer.preload.started",
            "diarizer.preload.interrupted",
        ])
        #expect(recorder.events.last?.1["duration_bucket"] == "5_to_15s")
        #expect(recorder.events.last?.1["compute_policy"] == "cpu_and_neural_engine")

        DiarizerPreloadDiagnostics(
            defaults: defaults,
            signalSink: recorder.record
        ).reportInterruptedAttemptIfNeeded()
        #expect(recorder.events.count == 2)
    }

    @Test("successful load clears the interruption marker")
    func readyClearsMarker() throws {
        let suiteName = "DiarizerPreloadDiagnosticsTests.ready.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = SignalRecorder()
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let diagnostics = DiarizerPreloadDiagnostics(
            defaults: defaults,
            now: { startedAt.addingTimeInterval(2) },
            signalSink: recorder.record
        )
        let context = makeContext()

        diagnostics.begin(context)
        diagnostics.ready(context, startedAt: startedAt)
        diagnostics.reportInterruptedAttemptIfNeeded()

        #expect(recorder.events.map(\.0) == [
            "diarizer.preload.started",
            "diarizer.preload.ready",
        ])
        #expect(recorder.events.last?.1["duration_bucket"] == "1_to_5s")
    }

    @Test("corrupt pending attempt is discarded without a signal")
    func corruptPendingAttempt() throws {
        let suiteName = "DiarizerPreloadDiagnosticsTests.corrupt.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = SignalRecorder()
        defaults.set(
            Data("not json".utf8),
            forKey: DiarizerPreloadDiagnostics.pendingAttemptKey
        )

        DiarizerPreloadDiagnostics(defaults: defaults, signalSink: recorder.record)
            .reportInterruptedAttemptIfNeeded()

        #expect(recorder.events.isEmpty)
        #expect(defaults.data(forKey: DiarizerPreloadDiagnostics.pendingAttemptKey) == nil)
    }

    @Test("failure telemetry is categorical and excludes raw error text")
    func failureIsCategorical() throws {
        let suiteName = "DiarizerPreloadDiagnosticsTests.failure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = SignalRecorder()
        let diagnostics = DiarizerPreloadDiagnostics(
            defaults: defaults,
            signalSink: recorder.record
        )
        let context = makeContext()
        let startedAt = diagnostics.begin(context)

        diagnostics.failed(
            context,
            startedAt: startedAt,
            error: URLError(.notConnectedToInternet)
        )

        let parameters = try #require(recorder.events.last?.1)
        #expect(parameters["failure_category"] == "network")
        #expect(!parameters.keys.contains("error"))
        #expect(!parameters.values.contains { $0.localizedCaseInsensitiveContains("internet") })
    }

    @Test("base telemetry uses an explicit privacy-safe allowlist")
    func telemetryAllowlist() {
        let parameters = makeContext().telemetryParameters

        #expect(Set(parameters.keys) == [
            "schema_version",
            "trigger",
            "compute_policy",
            "compatibility_rule",
            "cache_state",
            "model_set",
            "fluid_audio_version",
        ])
    }

    @Test(
        "duration buckets are stable",
        arguments: [
            (-30.0, "under_1s"),
            (0.5, "under_1s"),
            (1.0, "1_to_5s"),
            (5.0, "5_to_15s"),
            (15.0, "15_to_60s"),
            (60.0, "60s_or_more"),
        ]
    )
    func durationBuckets(argument: (TimeInterval, String)) {
        #expect(DiarizerPreloadDiagnostics.durationBucket(argument.0) == argument.1)
    }

    @Test("only Cocoa file errors are classified as filesystem failures")
    func cocoaFailureCategories() {
        let fileError = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let validationError = NSError(domain: NSCocoaErrorDomain, code: NSKeyValueValidationError)

        #expect(DiarizerPreloadDiagnostics.failureCategory(for: fileError) == "filesystem")
        #expect(DiarizerPreloadDiagnostics.failureCategory(for: validationError) == "other")
        #expect(
            DiarizerPreloadDiagnostics.failureCategory(
                for: DiarizerPreloadFailure.operationTimedOut
            ) == "timeout"
        )
    }

    private func makeContext() -> DiarizerPreloadContext {
        DiarizerPreloadContext(
            trigger: .appLaunch,
            policy: DiarizerRuntimePolicy(
                computePolicy: .cpuAndNeuralEngine,
                compatibilityRule: DiarizerRuntimePolicy.m1MacOS151CompatibilityRule
            ),
            cacheState: .complete
        )
    }
}

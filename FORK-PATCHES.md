# Fork Patches

Log of every change made to files owned by upstream (`Beingpax/VoiceInk`), so future merges
from `upstream/main` can see at a glance what diverged and why. New code that lives entirely
under `Features/Meetings/` (Phase 2+) does not need an entry here — this file is for edits to
files that already existed upstream.

Entries are grouped by branch/PR. This is `phase-0-fork-hygiene`.

## phase-0-fork-hygiene

### 1. Bundle identity: `com.prakashjoshipax.VoiceInk` → `com.hainesy.VoiceInkMeetings`

Mechanical, case-preserving find/replace of `com.prakashjoshipax.VoiceInk` →
`com.hainesy.VoiceInkMeetings` and `com.prakashjoshipax.voiceink` → `com.hainesy.voiceinkmeetings`
across every tracked file that contained it (71 files). This covers:

- App bundle id, debug variant (`.dev`), XPC service bundle id (`.RefineXPC`), test bundle ids
  (`VoiceInk.xcodeproj/project.pbxproj`), the shared XPC service-name/error-domain constants
  (`Shared/VoiceInkRefineXPCProtocol.swift`), the local-build Keychain service name
  (`VoiceInk/Infrastructure/Credentials/KeychainService.swift`), and `scripts/release.sh`'s
  `EXPECTED_BUNDLE_ID`.
- `os.Logger(subsystem:)` strings and a handful of `DispatchQueue` / notification-name label
  strings across ~65 Infrastructure/Feature files. These are Console.app log-filtering labels
  only, not functionally load-bearing, but they read as the same identity string so they moved
  too rather than leaving a mix of old/new prefixes.
- The on-disk Application Support folder name and WhisperModels path
  (`VoiceInk/App/VoiceInk.swift`).

Not touched: `Tests/**/*.swift` file-header comments ("Created by Prakash Joshi…") — left as
original-authorship attribution, not a functional identity reference. Also not touched:
`VoiceInk/Features/Dictionary/QuickAdd/DictionaryQuickAddPanel.swift`'s placeholder copy
`"e.g. Prakash, VoiceInk"` — a cosmetic example string in a dictionary-entry text field,
unrelated to app identity.

### 2. Sparkle auto-update neutralized (`VoiceInk/Info.plist`)

Removed the `SUFeedURL` and `SUPublicEDKey` keys entirely (upstream's feed URL
`https://beingpax.github.io/VoiceInk/appcast.xml` and their EdDSA public key). Without a feed
URL, Sparkle's `SPUUpdater` has nothing to probe and cannot discover, download, or install an
upstream build — this fork can never auto-update into upstream's app. `SUEnableAutomaticChecks`
was already `false` upstream; left as-is. `SUEnableInstallerLauncherService` (unrelated, XPC
plumbing for Sparkle's installer helper) left as-is.

Note: `VoiceInk/App/Updates/UpdaterViewModel.swift`'s `checkForUpdatesIfDue()` still runs on
Dashboard appear by default (`checksForUpdatesWhenDashboardAppears` defaults to `true`,
inherited from upstream's pre-fork Sparkle preference key). With no feed URL this just fails
silently — Sparkle handles a missing feed URL as an error, not a crash — but Phase 5 (when the
fork gets its own Sparkle keys/appcast) should decide whether to default this off instead until
a real feed exists.

### 3. Code signing identity stripped

- `DEVELOPMENT_TEAM = V6J6A3VWY2;` → `DEVELOPMENT_TEAM = "";` in all 4 build configurations in
  `VoiceInk.xcodeproj/project.pbxproj` (App Debug/Release, XPC Debug/Release). No Developer ID
  is set up for this fork yet; deferred to Phase 5.
- `scripts/release.sh`: removed the hardcoded fallback
  `Developer ID Application: Prakash Joshi (V6J6A3VWY2)` for `DEVELOPER_IDENTITY` — it now
  requires `VOICEINK_DEVELOPER_IDENTITY` to be set explicitly (`${VAR:?message}`, fails loudly
  instead of silently defaulting to upstream's identity). Also updated `RELEASE_BASE_URL`'s
  default to `markhaines/voiceink-meetings` releases, `NOTARY_PROFILE`/`SPARKLE_ACCOUNT`
  defaults to fork-named values, and `EXPECTED_FEED_URL` to `""` (there is no feed URL in
  `Info.plist` anymore to compare against). This script is not runnable end-to-end until Phase 5
  wires up a real Developer ID, notarization profile, and Sparkle account for the fork — it was
  not runnable in this environment either way (no Xcode, no signing identity), so this pass only
  removes the upstream literals; it does not attempt a working rebuild of the release flow.

### 4. iCloud container removed

- `VoiceInk/VoiceInk.entitlements`: removed `com.apple.developer.icloud-container-identifiers`
  (`iCloud.com.hainesy.VoiceInkMeetings`), `com.apple.developer.icloud-services` (`CloudKit`),
  and `com.apple.developer.aps-environment` (paired push entitlement, only meaningful together
  with the CloudKit container). None of these three are usable without a real Apple-issued App
  ID/provisioning profile, which this fork doesn't have yet.
- `VoiceInk/App/VoiceInk.swift` (`createPersistentContainer`): the `dictionary.store` (vocabulary
  + word-replacement SwiftData store) was CloudKit-synced upstream via
  `.private("iCloud.com.prakashjoshipax.VoiceInk")` in Release builds, and local-only
  (`.none`) under `#if DEBUG || LOCAL_BUILD`. With the entitlement gone, the CloudKit branch
  would fail at runtime, so it's now unconditionally `.none` — dictionary data stays local-only
  on this Mac until Phase 5 sets up the fork's own iCloud container and re-enables sync. No
  crash, no data loss: this only removes cross-device sync of the dictionary store.
- Test/local entitlements (`VoiceInk.debug.entitlements`, `VoiceInk.local.entitlements`) had no
  iCloud keys to begin with — only the `keychain-access-groups` bundle id needed updating
  (handled by the bundle-identity sweep above for `.debug`; `.local` has no bundle-id string in
  it at all).

### 5. Licensing removed

Deleted entirely: `VoiceInk/Features/Licensing/` (State/LicenseViewModel, Components/ProBadge,
Views/ConfettiCelebrationOverlay, Views/LicenseView, Views/LicenseManagementView,
Views/TrialMessageView) and `VoiceInk/Infrastructure/Licensing/` (LicenseManager, PolarService,
LicenseKeychainAccessibilityMigration) — Polar.sh license-key validation, trial-state tracking,
and the license-management UI. Also deleted `VoiceInk/Features/Onboarding/Views/
OnboardingLicenseScreen.swift` and `VoiceInk/Features/Onboarding/Components/
OnboardingLicenseCards.swift` (onboarding's license-activation step UI — verified via grep that
both structs they define are referenced nowhere else).

Follow-on edits to strip now-dead references, all in upstream files:

- `VoiceInk/Features/Recording/Workflows/TranscriptionDelivery.swift`: `deliverableText(from:)`
  was the trial-nag injection point — it prepended `LicenseViewModel.shared
  .usageRestrictionMessage` (which upstream already suppressed under `#if LOCAL_BUILD`) ahead of
  every pasted/custom-command transcript. Now a straight passthrough, unconditionally, for every
  build configuration — matches the task brief exactly.
- `VoiceInk/Features/Onboarding/State/OnboardingPermissionModels.swift`: removed the `.license`
  case from `OnboardingStage` (was step 8, "Buy VoiceInk License").
- `VoiceInk/Features/Onboarding/State/OnboardingCoordinator.swift`: removed the
  `licenseViewModel`/`licenseKeyDraft` published state; removed the `#if LOCAL_BUILD` bypass in
  `stage` (was: a persisted `"license"` stage snaps back to `.trust`) and in `totalStepCount`
  (was: `+1` under LOCAL_BUILD, `+2` otherwise) — now always the LOCAL_BUILD-era behavior
  (`.trust` is the last onboarding step, `+1`) for every build configuration, since there is no
  license step in this fork at all.
- `VoiceInk/Features/Onboarding/State/OnboardingFlowController.swift`: deleted
  `goToLicenseStep`, `goToPreviousLicenseStep`, `startLicenseTrial`, `activateLicense`; removed
  `.license` from the `reconcileStage` stage-guard list; `completeOnboarding`'s `#if LOCAL_BUILD`
  final-stage check collapsed to the LOCAL_BUILD branch unconditionally (`.trust` is final).
- `VoiceInk/Features/Onboarding/Views/OnboardingView.swift`: the Trust step's "Continue" button
  branched on `#if LOCAL_BUILD` between finishing onboarding directly vs. advancing to the
  license step; now always finishes onboarding. Removed the `case .license:` switch arm entirely.
- `VoiceInk/App/Navigation/ContentView.swift`: removed `.license = "VoiceInk Pro"` from the
  `ViewType` sidebar enum and its `case .license: LicenseManagementView()` detail-view mapping.
- `VoiceInk/App/Navigation/AppSidebar.swift`: removed `.license` from `secondaryItems` and from
  the `icon`/`sidebarIconStyle` switches. The `#if DEBUG` assert
  (`assertSidebarItemsCoverAllCases`) still passes — it's driven off `ViewType.allCases`, which
  shrank along with the sidebar arrays.
- `VoiceInk/Features/Dashboard/Views/DashboardView.swift` /
  `VoiceInk/Features/Dashboard/Views/DashboardContent.swift`: removed the `licenseState`/
  `onAddLicenseKey` init parameters and the `licenseStatusMessage` banner (the trial-nag /
  "Activate a license" / "N days left" strip shown above the Dashboard greeting). Removed
  `navigateToLicenseManagement()` from `DashboardView` (posted `navigateToDestination` →
  `"VoiceInk Pro"`, now unreachable).
- `VoiceInk/App/VoiceInk.swift`: removed the `licenseViewModel` `@StateObject`, the
  `.confettiCelebrationPresenter()` modifier (fired on `.licenseCelebrationRequested`, i.e. a
  successful license activation — unreachable now), and the `onReceive` block that called
  `licenseViewModel.refreshLicenseState()` on wake/foreground.
- `VoiceInk/App/Notifications/AppNotifications.swift`: removed the now-unused
  `licenseCelebrationRequested` notification name. `navigateToDestination` itself was left in
  place — it's genuine shared infra with unrelated callers (`AppDelegate`,
  `ImportExportService`).
- `VoiceInk/Features/Settings/Diagnostics/SystemInfoService.swift`: removed the
  `License Status: …` line from the copyable diagnostics report and its `getLicenseStatus()`
  helper.

**Not touched, deliberately:** `AppTheme.Sidebar.license` (a `Color` token in
`VoiceInk/DesignSystem/Theme/AppTheme.swift`) was left defined under its original name. It's a
green "success" color reused by two unrelated call sites (`GitHubStarPromptCard`'s starred
state, `DashboardContent`'s "Copy System Info" copied-confirmation) that have nothing to do with
licensing — renaming it would touch those two call sites for no functional reason.
`VoiceInk/Infrastructure/Privacy/Obfuscator.swift` was also left untouched: it's dead code
(zero call sites anywhere in the app — confirmed via grep) whose doc comment says "Uses the same
logic as PolarService for consistency," but `PolarService` itself never actually called it.
Nothing to delicense here, just a stale comment on an already-unused utility.

`VoiceInk/Infrastructure/Credentials/KeychainService.swift`'s `#if LOCAL_BUILD` branches were
**not** touched — they're unrelated to licensing (they select `kSecUseDataProtectionKeychain`
Keychain behavior that requires a real provisioning profile, vs. a legacy-UserDefaults fallback
for team-less builds). Since this fork has no Developer Team for the foreseeable future, CI
builds it via the same `LOCAL_BUILD`-flagged path upstream already built for exactly this case
(see the CI workflow).

### 6. CI (`.github/workflows/ci.yml`) and `Makefile`

Not a change to an upstream *file's behavior*, but recorded here because it's the mechanism
that makes the fork buildable without a human clicking through Xcode dialogs:

- **Runner image and Xcode version**: `runs-on: macos-26` (not the `macos-15` this workflow
  started on), with a "Select Xcode" step that additionally picks the newest `Xcode_26*.app`
  present under `/Applications` (belt-and-braces over relying on the image's default). Two
  compounding reasons, found by iterating against real CI failures rather than guessed up
  front:
  1. One transitive SPM dependency (`mlx-swift-lm` → `LLMkit`) declares
     `// swift-tools-version: 6.2`, which `macos-15`'s *default* Xcode (16.4, Swift 6.1) rejects
     outright (`package 'llmkit' … is using Swift tools version 6.2.0 but the installed version
     is 6.1.0`) — this is why an Xcode-selection step exists at all.
  2. `macos-15`'s *newest available* Xcode is 26.3 (Swift tools 6.2.4) — still not enough.
     `mlx-swift` at the version actually locked in `Package.resolved` (0.31.6) declares
     `// swift-tools-version: 6.3`, and CI said so plainly: `package 'mlx-swift' @ 0.31.6 is
     using Swift tools version 6.3.0 but the installed version is 6.2.4`. No Xcode on
     `macos-15` can build this dependency graph at all.
  `macos-26` (GitHub Actions runner image, arm64) ships Xcode 26.6 (build 17F113) as its
  **default** — which happens to be the exact same build this Mac's local toolchain now runs
  (also 26.6/17F113, Swift 6.3.3), confirmed by comparing `xcodebuild -version` output on both.
  So CI and local aren't just "same major generation" any more, they're the same Xcode build.
- **`-skipMacroValidation`** (passed to both `xcodebuild` invocations, and to `make local` via
  the new `LOCAL_XCODEBUILD_FLAGS` Makefile variable): **a security-relevant weakening, kept
  deliberately, narrowed to the minimum, and justified here.**

  *What breaks without it.* `mlx-swift-lm` ships a Swift macro target, `MLXHuggingFaceMacros`.
  Xcode gates the first use of any package macro behind a one-time interactive "Trust & Enable"
  dialog, and a headless runner has no way to answer it. CI run **33442033271** (commit
  `0614d43`, no flags) failed with:

  > `/…/SourcePackages/checkouts/mlx-swift-lm/Package.swift:PACKAGE-TARGET:MLXHuggingFaceMacros:`
  > `error: Macro “MLXHuggingFaceMacros” from package “mlx-swift-lm” must be enabled before it can be used`

  So this is a real, reproduced headless blocker, not a symptom of some other fault. (The
  separate local `xcodebuild -resolvePackageDependencies` hang is unrelated — its sampled stack
  sits in `waitForRemoteSourcePackagesToFinishLoading`, i.e. package-graph loading, and never
  reaches macro validation. Neither problem masks the other; see §7.)

  *What did not work.* The first attempt (commit `c523224`) set the undocumented default
  `defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES`.
  CI run **33443041941** produced the identical macro error, so that commit's change was inert
  and has been removed. It is worth naming plainly: that commit weakened a security-adjacent
  setting *and did not even achieve the thing it was added for*.

  *Narrowed to one flag.* Commit `f38bdc3` used **two** flags, `-skipMacroValidation` **and**
  `-skipPackagePluginValidation`. Only the first is needed: the reproduced error names a macro
  target, not a build-tool plugin, and this dependency graph runs no build-tool plugins.
  `-skipPackagePluginValidation` was therefore dropped, and CI confirms the build and tests
  still pass without it. The remaining flag is Apple's own documented `xcodebuild` option for
  exactly this case; its help text is explicit that it "can be a security risk if they are not
  from trusted sources".

  *Why it is an acceptable risk here.* The flag skips a **fingerprint/consent prompt**, not a
  signature or integrity check, and it changes nothing about *which* code is fetched. What code
  runs is decided by `Package.resolved`, which pins every dependency to an exact commit hash,
  and by `-onlyUsePackageVersionsFromResolvedFile`, which forbids `xcodebuild` from resolving to
  anything else. Every macro-shipping package in this graph (`mlx-swift-lm`, `swift-syntax`) is
  a transitive dependency of *upstream* VoiceInk's own lockfile — the fork adds no new trust
  surface, it only removes a click a build machine cannot perform. The residual risk is the one
  that already exists for anyone who clicks "Trust & Enable" locally: a compromised upstream
  dependency at a pinned hash. The mitigation that actually matters is the pinning, and it is
  in place. Mark's interactive `make local` is unaffected (`LOCAL_XCODEBUILD_FLAGS` defaults to
  empty), so on a desk Mac Xcode still shows the prompt as normal.
- `Makefile`: added `LOCAL_XCODEBUILD_FLAGS ?=` (empty by default) and appended
  `$(LOCAL_XCODEBUILD_FLAGS)` to the `local` target's `xcodebuild` invocation, so CI/scripted
  callers can inject the flags above without duplicating the whole recipe. No effect on
  `make local`'s default (interactive) behavior.
- Whisper.xcframework caching: `actions/cache@v4`'s combined step silently **skips its save**
  whenever any later step in the same job fails — discovered the hard way after two CI runs
  each spent ~10 minutes rebuilding whisper.xcframework from scratch (verified via the GitHub
  Actions Jobs API: `Post Cache whisper.xcframework` showed `conclusion: skipped` on both failed
  runs, and `GET .../actions/caches` listed zero caches). First fix was `save-always: true`, but
  GitHub's own deprecation notice on that input says it "does not work as intended and will be
  removed" — so the workflow now uses the documented replacement instead: separate
  `actions/cache/restore@v4` + `actions/cache/save@v4` steps, with the save placed immediately
  after the whisper build (before any step that could fail), rather than relying on a combined
  action's post-job hook.
- **`-onlyUsePackageVersionsFromResolvedFile`** (added to both `xcodebuild` invocations,
  including via `LOCAL_XCODEBUILD_FLAGS`): CI's from-scratch SPM resolution (no prior
  `.local-build/SourcePackages` cache — every CI run starts from a clean checkout) was resolving
  the transitive `mlx-swift` dependency to **0.31.4** — the floor of `mlx-swift-lm`'s own
  `.upToNextMinor(from: "0.31.4")` requirement — instead of **0.31.6**, the version actually
  pinned in the committed `Package.resolved`. 0.31.4 is missing the `MLXArray.maskFill`/
  `DType.greatestFiniteMagnitudeArray` APIs that `mlx-swift-lm`'s pinned revision
  (`cd1ab3dd98ceb…`, 2026-07-31) calls, so the build failed with `type 'MLXArray' has no member
  'maskFill'`. Confirmed by diffing: `git show 0.31.4:Source/MLX/MLXArray+maskFill.swift` in a
  from-scratch checkout of `mlx-swift` fails ("exists on disk, but not in '0.31.4'"); the file
  was added later, before 0.31.6. This is a pre-existing upstream `Package.resolved`/manifest
  inconsistency (mlx-swift-lm's pinned revision needs an mlx-swift newer than its own manifest's
  floor guarantees) — not something this fork introduced, and not something Phase 0 should "fix"
  by bumping a pin (out of scope; Phase 0 is hygiene, not dependency maintenance).
  `-onlyUsePackageVersionsFromResolvedFile` makes `xcodebuild` treat the committed lock as
  authoritative instead of re-resolving, which is the correct fix regardless of the underlying
  manifest looseness. Phase 1+ should consider whether to bump `mlx-swift-lm`'s pin (or add an
  explicit `mlx-swift` pin) to make the manifest itself consistent, so a *local* build with no
  existing lock also doesn't hit this.
- **Test step runs `-configuration Debug`** (and `-skip-testing:VoiceInkUITests`). This was the
  last thing standing between the fork and a green CI, and it is worth recording precisely
  because the symptom pointed somewhere misleading. Runs **33446687461**, **33448390850** and
  **33449207129** all "died in `ComputeTargetDependencyGraph`" as far as the visible log tail
  showed. That reading was wrong. Pulling the full 22,831-line log and mapping the step
  boundaries shows the **app build succeeded** in every one of those runs, as did the fork
  identity assertion; only the final `xcodebuild test` step failed, with exit code 65:

  > `Tests/VoiceInkTests/VoiceInkTests.swift:9:18: error: unable to resolve Swift module`
  > `dependency to a compatible module: 'VoiceInk'`
  > `note: found incompatible module '…/Build/Products/Release/VoiceInk.swiftmodule/arm64-apple-macos.swiftmodule'`

  Cause: the shared scheme's `TestAction` is set to `buildConfiguration = "Release"`, but
  `ENABLE_TESTABILITY = YES` appears exactly once in `project.pbxproj` and only on **Debug**.
  A Release test build therefore emits a `VoiceInk.swiftmodule` with no testing information, and
  `@testable import VoiceInk` cannot resolve against it. This is a latent upstream defect — the
  scheme as shipped cannot run its own tests in any environment — that this fork is the first
  thing to exercise. Fixed at the CI invocation rather than by editing the scheme, keeping the
  upstream-file touch count down: Debug is also the configuration the project already wires for
  testing (its `TEST_HOST` points at `VoiceInk Dev.app`, which is what a Debug build produces).
  The UI test bundle is skipped because `VoiceInkUITests` launches a real `XCUIApplication`, and
  VoiceInk needs Accessibility and microphone consent to clear onboarding — a GitHub runner
  grants neither. `VoiceInkTests` does run.
- **`scripts/assert-fork-identity.sh`** (new file) — the guard that stops the fork
  auto-updating into upstream's build. It fails if `CFBundleIdentifier` is not this fork's, if
  `SUFeedURL` points at upstream's appcast **host**, or if that host appears anywhere else in
  the bundle (nested plists, resources, or the executable itself — `grep -a`, so binaries are
  scanned too).

  Two deliberate strengthenings over the inline check it replaces. First, the old check compared
  `SUFeedURL` for **exact string equality** with upstream's appcast URL, so a merely *renamed*
  feed on the same host (`…/VoiceInk/appcast-v2.xml`) would have passed. The match is now
  host-level. Second, and more important, CI now **verifies the assertion itself** on every run,
  in a `Self-test the fork-identity assertion` step that runs before the real check: four
  fabricated bundles it must reject (upstream URL, renamed URL on upstream's host, upstream
  bundle id, host hidden in a nested resource) and one clean bundle it must accept. An assertion
  that can never fire is worse than no assertion, because it reads as green forever. This
  self-test was itself checked by sabotage: reverting the script to the old exact-URL comparison
  makes the self-test fail on the renamed-feed control, and stubbing the script to `exit 0`
  makes it fail on the first control.


## Architecture budget note

The instruction for this project caps ongoing upstream touchpoints (outside the new
`Features/Meetings/` slice) at roughly 6. That budget is for Phase 1+ feature work layered on
top of a clean base — it does not describe Phase 0 itself, whose entire job is editing
upstream-owned files (identity, signing, Sparkle, delicensing) exactly once, up front, so later
phases don't have to. This entry is long because Phase 0 is supposed to be long; Phase 1 onward
should look nothing like this.

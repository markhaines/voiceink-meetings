# Fork Patches

Log of every change made to files owned by upstream (`Beingpax/VoiceInk`), so future merges
from `upstream/main` can see at a glance what diverged and why. New code that lives entirely
under `Features/Meetings/` (Phase 2+) does not need an entry here — this file is for edits to
files that already existed upstream.

Entries are grouped by branch/PR. This is `phase-0-fork-hygiene`.

## Fork point: `711297b`

The fork point is upstream commit **`711297b`** ("Separate Xcode debug app identity from
production", authored by Prakash Joshi Pax). That is the merge-base, and it is the ONLY
correct base for enumerating what this fork changed:

```bash
git merge-base upstream/main origin/phase-0-fork-hygiene   # -> 711297b6c8b918fd73665fbbea4736369ac655a9
git diff --name-only 711297b..origin/phase-0-fork-hygiene  # -> 107 paths, matching the Appendix below
```

**Diff from the merge-base, not from an older upstream commit.** A review generated from an
earlier base (`9f95226`) attributed upstream's own `711297b` to this fork, and so reported
`BUILDING.md`, `LocalBuild.xcconfig` and `VoiceInk.xcscheme` as undocumented fork changes and
this document's "the scheme is byte-identical to upstream" statement as false. Both readings
were artefacts of the wrong base: `711297b` is upstream's commit, it touches exactly those
files, and the `LaunchAction` Release -> Debug change in the scheme is upstream's, not ours.
The Appendix at the end of this file is generated from the command above.


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

### 2b. Upstream remote-config channel removed (`AnnouncementsService`)

Found by the hardened CI guard, not by inspection — and worth recording because the original
Phase 0 pass reported *"No feed URL anywhere in the repo now — confirmed by a full-repo grep
after the edit"*. That grep looked for the **appcast URL**. It did not look for the **host**,
and so it missed this:

```swift
// VoiceInk/Infrastructure/RemoteConfig/AnnouncementsService.swift:13
private let announcementsURL = URL(string: "https://beingpax.github.io/VoiceInk/announcements.json")!
```

The Sparkle feed was not the only thing pointing at upstream. `AnnouncementsService` polled
upstream's GitHub Pages site **every 4 hours, starting 5 seconds after launch**, with
`enableAnnouncements` registered as `true` by default (`AppDefaults.swift`). It decoded whatever
JSON it got and displayed it as a floating in-app banner with a "Learn More" button that opens
an **arbitrary upstream-supplied URL** (`AnnouncementManager.showAnnouncement`). So a fork built
from this tree would phone home to upstream on every launch and render upstream-controlled
content, with a clickable link, inside Mark's app.

That is the same class of problem as the Sparkle feed — an upstream-controlled channel into a
fork that is supposed to be independent — so it gets the same treatment as the licensing code:
removed, not disabled. Deleted `Infrastructure/RemoteConfig/AnnouncementsService.swift`,
`App/Notifications/AnnouncementManager.swift` and `App/Notifications/Views/AnnouncementView.swift`
(the manager and view had no other callers), plus the `start()`/`stop()` wiring in
`App/VoiceInk.swift`, the `enableAnnouncements` default in `App/Configuration/AppDefaults.swift`,
and the "Show Announcements" toggle in `Features/Settings/Views/SettingsView.swift`.

The general lesson, now encoded in the guard: **check the host, and check the built product, not
the source.** This string was compiled into `Contents/MacOS/VoiceInk`, so only a scan of the
built bundle (`grep -a`, binaries included) would have caught it. CI run **33486598551** did,
failing with:

```
error: upstream appcast host 'beingpax.github.io' is referenced inside /Users/runner/Downloads/VoiceInk.app:
    /Users/runner/Downloads/VoiceInk.app/Contents/MacOS/VoiceInk
```

### 2c. GitHub star prompt removed (`GitHubStarPromptCoordinator`, `GitHubCLIStarService`)

The reviewer asked whether the retained star prompt performs network access to something
upstream controls, or merely opens a URL on click. It is not merely a URL: it makes an
automatic, credentialed network call on the user's behalf, about upstream's repository,
without anyone clicking anything.

`GitHubStarPromptCoordinator.scheduleIfNeeded(modelContainer:)` was called from
`VoiceInk.swift`'s `.onAppear`. Three seconds after the main window appears, once the user
has 30 completed sessions, it called `GitHubCLIStarService.checkRemoteStarState()`, which
locates the `gh` binary (probing Homebrew paths, then sourcing the user's `.zshrc` for
`PATH`) and runs:

```
gh api --include user/starred/Beingpax/VoiceInk
```

That is an authenticated request to the GitHub API using **the user's own `gh`
credentials**, disclosing to GitHub that this account is running the app and reading whether
they have starred upstream's repo. Clicking the card then ran
`gh api -X PUT user/starred/Beingpax/VoiceInk`, a **write to the user's GitHub account**.
The host is GitHub's, not upstream's, but the repo, the trigger and the benefit are
upstream's, and no consent is asked for the automatic check.

Removed on the same reasoning as `AnnouncementsService`: deleted
`Features/Dashboard/State/GitHubStarPromptCoordinator.swift`,
`Features/Dashboard/Components/GitHubStarPromptCard.swift` and
`Infrastructure/ExternalServices/GitHubCLIStarService.swift`, the `.onAppear` hook in
`VoiceInk.swift`, the overlay in `DashboardView.swift`, and the footer button plus its label
builder in `DashboardContent.swift`. A de-branded private fork promoting upstream's star
count was dead weight regardless; the credentialed call is what made it worth removing
rather than leaving.

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
- **Build-time macro and plugin trust.** Swift package **macros** and **build-tool plugins**
  are executables that Xcode compiles and *runs on the build machine*, with the build user's
  privileges, during every build. Xcode gates the first use of each behind an interactive
  "Trust & Enable" dialog that a headless runner cannot answer, so CI used to pass both
  `-skipMacroValidation` and `-skipPackagePluginValidation`.

  *State the blast radius honestly.* An earlier version of this section described those flags
  as removing "a click a build machine cannot perform". That understated it. The flags are
  not scoped to the two components that needed them: they disable the trust gate for **every**
  macro and build-tool plugin in the resolved graph, including any that a future transitive
  dependency bump silently introduces. Pinning in `Package.resolved` gives reproducibility,
  not review: it guarantees you run the same code every time, not that anyone looked at it.
  Two things changed as a result.

  **One flag is gone, by taking the macro out of the build graph.** `-skipMacroValidation` was
  required only for `MLXHuggingFaceMacros`, and that macro target is a dependency of exactly
  one target in `mlx-swift-lm`: `MLXHuggingFace`. This project linked the `MLXHuggingFace`
  product for a single expression, `#huggingFaceTokenizerLoader()`, in
  `VoiceInkRefineXPC/VoiceInkRefineInferenceEngine.swift`. That macro's entire expansion is
  mechanical adapter code -- an `MLXLMCommon.TokenizerLoader` calling
  `Tokenizers.AutoTokenizer.from(modelFolder:)`, wrapped in a bridge conforming
  `Tokenizers.Tokenizer` to `MLXLMCommon.Tokenizer`. It is now written out, verbatim from the
  macro's own source at the pinned revision `cd1ab3dd98ce`, in the new fork-owned file
  `VoiceInkRefineXPC/HuggingFaceTokenizerLoader.swift`, and the `MLXHuggingFace` product
  dependency is dropped from the `VoiceInkRefineXPC` target. `MLXLLM` and `MLXLMCommon` do not
  depend on `MLXHuggingFace`, so the MLX inference path is unchanged and the XPC service still
  runs the local model. **No macro is built at all now**, and CI proves it rather than
  asserting it: the flag is simply not passed, so if a macro ever re-enters the graph the
  build fails with `Macro "MLXHuggingFaceMacros" ... must be enabled before it can be used`
  (the exact failure seen in run **33442033271**) instead of quietly trusting it.

  **The other flag stays, and is now bounded by a check that fails when the trusted sources
  change.** `-skipPackagePluginValidation` is still required for one component: `mlx-swift`
  attaches its `CudaBuild` build-tool plugin unconditionally to `Cmlx`, the core C++ target
  that every MLX product depends on, so it cannot be excluded without forking `mlx-swift`
  itself -- which would mean vendoring its several-hundred-megabyte vendored MLX/mlx-c/fmt
  tree to delete one line of manifest. Dropping the flag fails the build
  (`Validate plug-in "CudaBuild" in package "mlx-swift"` -> `** BUILD FAILED **`, run
  **33486090430**). Xcode offers no durable, per-identity CI trust store to use instead: the
  only SwiftPM security state on a developer Mac is
  `~/Library/org.swift.swiftpm/security/fingerprints/`, a TOFU record of package *versions*,
  not a plugin allowlist, and the undocumented
  `IDESkipPackagePluginFingerprintValidatation` default was already tried and proved inert
  (run **33443041941**).

  So the blanket flag is kept and bounded, by `scripts/verify-package-trust.sh` +
  `package-trust.json`, which run **before anything is built** (all 28 packages, by shallow
  blobless `git fetch` of each pinned revision: no `xcodebuild`, nothing compiled, nothing
  executed, ~30 seconds).

  **The first version of that guard enumerated the dangerous things, and that was unsound.**
  It ran a regular expression over each package manifest looking for `.macro(name: "X")` /
  `.plugin(name: "X")` and required every match to be an allowlisted, hash-pinned component.
  A `Package.swift` is executable Swift, not data: a target can be declared through a helper
  function, a variable, a loop, `#if` logic, or simply formatting the pattern does not match.
  A package whose manifest declared a build-tool plugin in any of those forms produced zero
  matches, contributed no component to check, and, because a package with no recognised
  components was not itself required to be allowlisted, passed. Reproduced before the rewrite,
  against the real 28-package graph plus one added package whose manifest builds its plugin
  target via `func buildToolTarget(_:) -> Target`:

  ```
  scanned 29 pinned packages; 4 macro/plugin target(s) declared in the graph
  OK: every macro/plugin target in the graph is reviewed and unchanged     [exit 0]
  ```

  The same hole let a pinned revision move unnoticed on any package that declared no
  recognised component: moving `zip`'s pin to a different real commit also printed `OK`,
  exit 0.

  **Trust is now bound to the whole resolved input, not to what a regex can find inside it.**
  `package-trust.json` gained a `graph` section, and the check fails on any of:

  - **the package set.** Every pin in `Package.resolved` must be one recorded in `graph`, and
    every recorded package must still be pinned. A new package entering the graph is a hard
    failure whatever it does or does not declare, which is the property the regex could not
    provide. A recorded package leaving the graph also fails, because a trust file that no
    longer describes the graph is not a reviewed one.
  - **the pinned revision and location.** A git revision is a hash over that package's entire
    tree, so an unchanged revision is a cryptographic guarantee that not one byte of that
    package (manifest, plugin source, anything) has changed. A moved pin, or a `location`
    repointed at a different repository, is a hard failure.
  - **the tree and the manifests, recorded explicitly.** Per package the file also carries the
    root tree object id and the blob object id of every root `Package*.swift`. These are
    implied by the revision; recording them makes the review record legible on its own terms
    and names exactly which manifest changed when one does.
  - **`Package.resolved` itself,** by sha256 of its bytes, so an edit to a field the script
    does not otherwise model still forces a re-bless. When only the bytes moved and no
    package, pin or manifest did, the failure says so, because the review needed there is a
    glance at `git diff` rather than reading a dependency.
  - **an unmodelled pin kind.** Only `remoteSourceControl` pins are understood; a registry or
    local-path pin fails rather than being waved through.

  The per-component records are kept, as **additional review evidence rather than as the
  mechanism**: for each macro/plugin target the regex can see, the path and git tree id of its
  sources plus the note recording what reading them found. They still fail on an unreviewed
  match, a moved revision, a source tree that changed, or a companion path that vanished.

  A second CI step re-checks `Package.resolved` **after** the build and test steps and fails if
  it changed, so a build-time re-resolution cannot add a package behind the pre-build check.

  **Re-blessing the package trust file.** After any legitimate dependency change (a pin bump, a
  new package, an Xcode-rewritten `Package.resolved`) the check will fail, by design. The fix
  is one command:

  ```bash
  scripts/verify-package-trust.sh --update   # rewrites package-trust.json from the current pins
  git diff package-trust.json                # THIS DIFF IS THE REVIEW RECORD - read it
  ```

  `--update` prints what it is blessing (`+ package X @ rev`, `~ package X: old -> new`,
  `- package X (left the graph)`) before writing, preserves the `note` on every existing
  component, and marks any newly discovered component `PENDING REVIEW` so an unread one is
  visible in the diff. What "reviewing" means in practice: for a pin bump, read the upstream
  diff for that package's manifest and for any macro or plugin sources it touches; for a new
  package, read its manifest and note what build-time-executable targets it declares. Then
  replace `PENDING REVIEW` with what you found and commit both files together. `--help` prints
  the script's own reasoning.

  Four components are declared in the current graph and each was read before being recorded:
  `mlx-swift/CudaBuild` (buildTool), `mlx-swift-lm/MLXHuggingFaceMacros` (macro, declared but
  no longer built here), and `swift-argument-parser`'s `GenerateManual` and
  `GenerateDoccReference` (both capability `.command`, which never run during a build).
  Worth recording about the one plugin that does have build-tool capability: `CudaBuild`'s
  `createBuildCommands` opens with `guard isCudaEnabled()`, and `isCudaEnabled()` is
  `#if os(Linux) ... #else return false #endif`. On macOS it prints "CUDA is disabled" and
  returns an empty command list -- it emits no build commands and never invokes its `encuda`
  helper. The reviewed hashes cover the plugin sources and `Source/Encuda`.

  Residual risk, stated plainly: the plugin still runs, unprompted, as part of the build. What
  the guard buys is that the build can only ever run *this* reviewed plugin at *this* reviewed
  revision, out of *this* reviewed set of 28 packages, and that nothing else can arrive without
  a human re-blessing the trust file first. It does not read the plugin for you; it guarantees
  that what you read last is what runs. `make local` on a desk Mac is unaffected --
  `LOCAL_XCODEBUILD_FLAGS` defaults to empty, so Xcode still prompts there.
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
- **`scripts/assert-fork-identity.sh`** (new file) -- the guard that stops the fork
  auto-updating into upstream's build, or quietly carrying upstream's identity. It runs in two
  modes, because the evidence lives in two places.

  *Product mode* (`assert-fork-identity.sh <path-to-.app>`) inspects the built app: the
  top-level `CFBundleIdentifier` must be the fork's, **every nested bundle** (XPC service,
  plugins, embedded frameworks) must be under the fork's identifier, and nothing anywhere in
  the bundle may reference upstream's appcast **host**, upstream's bundle-id prefix, upstream's
  Apple Developer team id `V6J6A3VWY2`, or upstream's Sparkle public EdDSA key. The scan is
  `grep -r -a`, so compiled-in strings are caught: that is how `AnnouncementsService` was
  found, hidden in `Contents/MacOS/VoiceInk` with nothing in any plist.

  *Project mode* (`assert-fork-identity.sh --project <repo-root>`) inspects the repository's
  build configuration, and it exists because two of those things are invisible to the product
  scan. The unit and UI **test bundles are never inside the .app**, so their
  `PRODUCT_BUNDLE_IDENTIFIER` can only be checked in `project.pbxproj`; and `DEVELOPMENT_TEAM`
  is a signing setting, not a built-product string, so restoring `V6J6A3VWY2` would not have
  failed the old guard at all. Project mode asserts positively that every configured
  `PRODUCT_BUNDLE_IDENTIFIER` is under the fork's, and fails if the file is somehow empty of
  them (a vacuous check is not a passing one).

  *A suppressed error is not an absence of matches.* `grep` exits 0 on a match, 1 on no match
  and **>1 on an error** -- an unreadable path, an I/O failure. The previous implementation
  ran the bundle-wide scan with `2>/dev/null`, which collapses "the scan could not complete"
  into "the scan found nothing", so a single unreadable file could take part of the tree out
  of the scan while the check still reported success. Every scan now captures grep's exit
  status and treats anything above 1 as a hard failure, prints any warning grep emitted, and
  never swallows stderr.

  *The assertion is verified on every run.* A check that can never fire is worse than no
  check, because it reads as green forever. The `Self-test the fork-identity assertion` step
  runs before the real one, against **twelve** controls: two that must be accepted (a clean
  bundle, a clean project) and ten that must be rejected -- upstream appcast URL; a *renamed*
  appcast on upstream's host (the near-miss an exact-string comparison waved through);
  upstream bundle id; the host hidden in a nested resource; upstream's Sparkle public key;
  upstream's team id inside the bundle; a nested XPC bundle outside the fork's identifier; an
  **unreadable file**, which must fail the scan rather than be skipped; upstream's
  `DEVELOPMENT_TEAM` restored in the project; and an upstream **test-bundle** identifier. If
  any control is accepted, CI fails there rather than at the real check.
- **whisper.cpp pinned (`whisper-cpp.rev`, `Makefile`, CI).** CI used to resolve
  `git ls-remote https://github.com/ggerganov/whisper.cpp.git HEAD` at run time and `make
  setup` built whatever that returned. whisper.cpp is compiled into `whisper.xcframework` and
  linked into the shipped app, so that made an unreviewed, remotely mutable native-code input
  part of every build: the same commit could produce a different binary tomorrow, and nothing
  would record it. The revision now lives in `whisper-cpp.rev`
  (`eacbd8234c6654cdbf2c377f72b2106875479bdc`, the revision the last green run built), and
  **both** consumers read that one file -- the Makefile's `whisper` target fetches and checks
  out exactly that sha instead of `git pull`ing, and CI's cache key is derived from it, so
  cache and build cannot diverge. CI additionally asserts that the restored checkout's `HEAD`
  is the pinned sha, rather than trusting the cache key. Bumping it is now a reviewed commit.
- **All GitHub Actions pinned to full commit shas.** `actions/checkout@v4`,
  `actions/cache/restore@v4`, `actions/cache/save@v4` and `actions/upload-artifact@v4` were
  floating major tags. A tag is a mutable pointer the action's owner can repoint at will, so
  `uses: ...@v4` means "run whatever code that account publishes next, in this workflow, with
  this workflow's token". Each is now pinned to the commit sha that tag resolved to, with the
  release version in a trailing comment so bumps stay reviewable:
  `actions/checkout@11d5960a...` (v4.4.0), `actions/cache/{restore,save}@0057852b...` (v4.3.0),
  `actions/upload-artifact@ea165f8d...` (v4.6.2).
- **The shared scheme is not modified by this fork** -- worth stating because it was queried.
  `VoiceInk.xcodeproj/xcshareddata/xcschemes/VoiceInk.xcscheme` does not appear in
  `git diff --name-only 711297b..HEAD` at all; it is byte-identical to upstream. Its
  `LaunchAction buildConfiguration = "Debug"` is upstream's own value, not a fork change (its
  `TestAction` is `"Release"`, which is the latent defect the CI test step works around on the
  command line, exactly so the scheme need not be touched).

## Appendix: every upstream file this branch touches

Acceptance criterion 5 asks for the complete list, not a summary: at merge time the
question is always "did upstream change one of *these* files", and a count with example
paths cannot answer it. The grouping below is generated from git, not typed by hand --
regenerate it with `git diff --name-status 711297b..HEAD` (that commit is the fork
point, `git merge-base HEAD upstream/main`) and re-sort into these five groups.

Totals: 60 identity-only edits, 15 behavioural edits, 8 build/project changes, 17 deletions, 10 new fork-only files (110 paths).

This appendix started as a Phase 0 inventory, but it is maintained past Phase 0 for anything
UPSTREAM-OWNED that a later stage touches -- that is the question it exists to answer at merge
time, and a later stage quietly editing an upstream file without appearing here would defeat the
whole point. Files created by this fork under `Features/Meetings/` are still out of scope by this
file's own rule; `.gitignore` (A3) is the first post-Phase-0 addition.

### A1. Identity-only edits (60 files)

Mechanical: every changed line in these files is one of the identity strings -- the
`Logger(subsystem:)` name `com.prakashjoshipax.voiceink` -> `com.hainesy.voiceinkmeetings`,
a Keychain service name, or an application-support path component. No logic changed, so a
conflicting upstream change to any of them can be taken wholesale and re-swept.

- `Shared/VoiceInkRefineXPCProtocol.swift`
- `VoiceInk/App/Lifecycle/ModelPrewarmService.swift`
- `VoiceInk/App/Windows/WindowManager.swift`
- `VoiceInk/Features/AudioImport/Workflows/AudioFileTranscriptionManager.swift`
- `VoiceInk/Features/Dictionary/Workflows/DictionaryService.swift`
- `VoiceInk/Features/Enhancement/Workflows/AIEnhancementService.swift`
- `VoiceInk/Features/History/Presentation/HistoryWindowController.swift`
- `VoiceInk/Features/History/Workflows/AudioFileTranscriptionService.swift`
- `VoiceInk/Features/ModelLibrary/State/CustomAIProviderManager.swift`
- `VoiceInk/Features/ModelLibrary/State/CustomCloudModelManager.swift`
- `VoiceInk/Features/ModelLibrary/State/FluidAudioModelManager.swift`
- `VoiceInk/Features/ModelLibrary/State/TranscribeCppModelManager.swift`
- `VoiceInk/Features/ModelLibrary/State/TranscriptionModelManager.swift`
- `VoiceInk/Features/ModelLibrary/State/VoiceInkRefineService.swift`
- `VoiceInk/Features/ModelLibrary/State/WhisperModelManager.swift`
- `VoiceInk/Features/Recording/Capture/Recorder.swift`
- `VoiceInk/Features/Recording/Presentation/MiniRecorderPanel.swift`
- `VoiceInk/Features/Recording/Presentation/MiniWindowManager.swift`
- `VoiceInk/Features/Recording/Presentation/NotchRecorderPanel.swift`
- `VoiceInk/Features/Recording/Presentation/NotchWindowManager.swift`
- `VoiceInk/Features/Recording/Presentation/RecorderUIManager.swift`
- `VoiceInk/Features/Recording/Streaming/StreamingTranscriptionService.swift`
- `VoiceInk/Features/Recording/Workflows/TranscriptionPipeline.swift`
- `VoiceInk/Features/Recording/Workflows/TranscriptionServiceRegistry.swift`
- `VoiceInk/Features/Recording/Workflows/TranscriptionSession.swift`
- `VoiceInk/Features/Recording/Workflows/VoiceInkEngine.swift`
- `VoiceInk/Features/Shortcuts/Coordination/ShortcutMonitor.swift`
- `VoiceInk/Infrastructure/Audio/AudioFileProcessor.swift`
- `VoiceInk/Infrastructure/Audio/CoreAudioRecorder.swift`
- `VoiceInk/Infrastructure/Audio/Devices/AudioDeviceConfiguration.swift`
- `VoiceInk/Infrastructure/Audio/Devices/AudioDeviceManager.swift`
- `VoiceInk/Infrastructure/Audio/SoundPlaybackEngine.swift`
- `VoiceInk/Infrastructure/Credentials/APIKeyManager.swift`
- `VoiceInk/Infrastructure/Credentials/KeychainService.swift`
- `VoiceInk/Infrastructure/Diagnostics/LogExporter.swift`
- `VoiceInk/Infrastructure/Persistence/Cleanup/TranscriptionAutoCleanupService.swift`
- `VoiceInk/Infrastructure/Persistence/Migrations/SessionMetricMigrationService.swift`
- `VoiceInk/Infrastructure/Persistence/Statistics/DashboardStatsSnapshotStore.swift`
- `VoiceInk/Infrastructure/Persistence/Statistics/SessionMetricRecorder.swift`
- `VoiceInk/Infrastructure/Providers/Enhancement/VoiceInkRefine/VoiceInkRefineModelDownloader.swift`
- `VoiceInk/Infrastructure/Providers/Enhancement/VoiceInkRefine/VoiceInkRefineXPCClient.swift`
- `VoiceInk/Infrastructure/Providers/Transcription/AppleSpeech/NativeAppleSpeechAssetManager.swift`
- `VoiceInk/Infrastructure/Providers/Transcription/AppleSpeech/NativeAppleTranscriptionService.swift`
- `VoiceInk/Infrastructure/Providers/Transcription/FluidAudio/FluidAudioTranscriptionService.swift`
- `VoiceInk/Infrastructure/Providers/Transcription/FluidAudio/Streaming/FluidAudioNemotronStreamingProvider.swift`
- `VoiceInk/Infrastructure/Providers/Transcription/FluidAudio/Streaming/FluidAudioStreamingProvider.swift`
- `VoiceInk/Infrastructure/Providers/Transcription/FluidAudio/Streaming/FluidAudioUnifiedStreamingProvider.swift`
- `VoiceInk/Infrastructure/Providers/Transcription/TranscribeCpp/OfflineTranscribeCppService.swift`
- `VoiceInk/Infrastructure/Providers/Transcription/TranscribeCpp/TranscribeCppModelCatalog.swift`
- `VoiceInk/Infrastructure/Providers/Transcription/Whisper/LibWhisper.swift`
- `VoiceInk/Infrastructure/Providers/Transcription/Whisper/VADModelManager.swift`
- `VoiceInk/Infrastructure/Providers/Transcription/Whisper/WhisperTranscriptionService.swift`
- `VoiceInk/Infrastructure/SystemIntegration/Accessibility/SelectedTextService.swift`
- `VoiceInk/Infrastructure/SystemIntegration/Context/ActiveWindowService.swift`
- `VoiceInk/Infrastructure/SystemIntegration/Context/BrowserURLService.swift`
- `VoiceInk/Infrastructure/SystemIntegration/Hardware/ClamshellStateMonitor.swift`
- `VoiceInk/Infrastructure/SystemIntegration/LaunchAtLoginManager.swift`
- `VoiceInk/Infrastructure/SystemIntegration/Paste/CursorPaster.swift`
- `VoiceInk/Infrastructure/SystemIntegration/Processes/CustomCommandDeliveryRunner.swift`
- `VoiceInk/Infrastructure/SystemIntegration/Processes/ShellCommandEnvironment.swift`

### A2. Behavioural edits (15 files)

These changed what the app does. Read the reason before merging upstream changes here.

- `VoiceInk/App/Configuration/AppDefaults.swift` -- dropped the `enableAnnouncements` default (the upstream remote-config channel is gone)
- `VoiceInk/App/Navigation/AppSidebar.swift` -- removed the `.license` sidebar item and its icon/colour cases
- `VoiceInk/App/Navigation/ContentView.swift` -- removed the `.license` destination (`LicenseManagementView`); logging subsystem renamed
- `VoiceInk/App/Notifications/AppNotifications.swift` -- removed the `licenseCelebrationRequested` notification name
- `VoiceInk/App/VoiceInk.swift` -- removed `LicenseViewModel`, the announcements start-up hook and the star-prompt scheduling; CloudKit container forced to `.none` (fork has no iCloud container); support paths and logging subsystem renamed
- `VoiceInk/Features/Dashboard/Views/DashboardContent.swift` -- removed the GitHub star footer button and its label builder
- `VoiceInk/Features/Dashboard/Views/DashboardView.swift` -- removed the star-prompt overlay; the view is now just `DashboardContent`
- `VoiceInk/Features/Onboarding/State/OnboardingCoordinator.swift` -- removed the licensing step from the onboarding flow
- `VoiceInk/Features/Onboarding/State/OnboardingFlowController.swift` -- removed the licensing step and its transitions
- `VoiceInk/Features/Onboarding/State/OnboardingPermissionModels.swift` -- removed the `.license` step case (title, icon, ordering, copy)
- `VoiceInk/Features/Onboarding/Views/OnboardingView.swift` -- removed the licensing screen from the onboarding switch
- `VoiceInk/Features/Recording/Workflows/TranscriptionDelivery.swift` -- `deliverableText(from:)` is now a passthrough -- it used to prepend `LicenseViewModel.usageRestrictionMessage` to transcripts; logging subsystem renamed
- `VoiceInk/Features/Settings/Diagnostics/SystemInfoService.swift` -- dropped the License Status line and `getLicenseStatus()` from the diagnostics dump
- `VoiceInk/Features/Settings/Views/SettingsView.swift` -- removed the "Show Announcements" toggle and its start/stop wiring
- `VoiceInkRefineXPC/VoiceInkRefineInferenceEngine.swift` -- dropped `import MLXHuggingFace` and swapped `#huggingFaceTokenizerLoader()` for the fork-owned `HuggingFaceTokenizerLoader()` -- this is what takes the macro out of the build graph (section 6)

### A3. Build and project configuration (8 files)

- `Makefile` -- added `LOCAL_XCODEBUILD_FLAGS ?=` for CI, and pinned the whisper.cpp checkout to `whisper-cpp.rev` instead of `git pull`ing upstream HEAD
- `README.md` -- fork header, build instructions, upstream attribution
- `VoiceInk.xcodeproj/project.pbxproj` -- bundle identifiers for app/XPC/tests/UI-tests, `DEVELOPMENT_TEAM` emptied, iCloud entitlement removals, and the `MLXHuggingFace` package product dependency dropped
- `VoiceInk/Info.plist` -- `SUFeedURL` and `SUPublicEDKey` removed, automatic update checks disabled
- `VoiceInk/VoiceInk.debug.entitlements` -- same, for the debug configuration
- `VoiceInk/VoiceInk.entitlements` -- iCloud/CloudKit container entitlements removed
- `scripts/release.sh` -- notarisation/signing identifiers pointed at the fork
- `.gitignore` -- five build-scratch ignore lines appended (stage2-models-store escalation round, section 9)

### A4. Deleted upstream files (17 files)

- `VoiceInk/App/Notifications/AnnouncementManager.swift` -- announcements state, no other callers
- `VoiceInk/App/Notifications/Views/AnnouncementView.swift` -- announcements banner UI
- `VoiceInk/Features/Dashboard/Components/GitHubStarPromptCard.swift` -- star-prompt card UI
- `VoiceInk/Features/Dashboard/State/GitHubStarPromptCoordinator.swift` -- scheduled that call automatically after 30 sessions (section 2c)
- `VoiceInk/Features/Licensing/Components/ProBadge.swift` -- licensing (section 5)
- `VoiceInk/Features/Licensing/State/LicenseViewModel.swift` -- licensing (section 5)
- `VoiceInk/Features/Licensing/Views/ConfettiCelebrationOverlay.swift` -- licensing (section 5)
- `VoiceInk/Features/Licensing/Views/LicenseManagementView.swift` -- licensing (section 5)
- `VoiceInk/Features/Licensing/Views/LicenseView.swift` -- licensing (section 5)
- `VoiceInk/Features/Licensing/Views/TrialMessageView.swift` -- licensing (section 5)
- `VoiceInk/Features/Onboarding/Components/OnboardingLicenseCards.swift` -- licensing (section 5)
- `VoiceInk/Features/Onboarding/Views/OnboardingLicenseScreen.swift` -- licensing (section 5)
- `VoiceInk/Infrastructure/ExternalServices/GitHubCLIStarService.swift` -- ran `gh api user/starred/Beingpax/VoiceInk` with the user's own credentials (section 2c)
- `VoiceInk/Infrastructure/Licensing/LicenseKeychainAccessibilityMigration.swift` -- licensing (section 5)
- `VoiceInk/Infrastructure/Licensing/LicenseManager.swift` -- licensing (section 5)
- `VoiceInk/Infrastructure/Licensing/PolarService.swift` -- licensing (section 5)
- `VoiceInk/Infrastructure/RemoteConfig/AnnouncementsService.swift` -- polled upstream's GitHub Pages host every 4 hours and rendered upstream-supplied content with a clickable link (section 2b)

### A5. New fork-only files (10 files)

- `.github/workflows/ci.yml` -- the CI pipeline (section 6)
- `FORK-PATCHES.md` -- this file
- `NOTICE` -- upstream attribution and licence notice
- `VoiceInkRefineXPC/HuggingFaceTokenizerLoader.swift` -- the fork's own copy of the `#huggingFaceTokenizerLoader()` expansion, which is what removes mlx-swift-lm's macro from the build graph (section 6)
- `package-trust.json` -- the reviewed build-time input: the whole pinned package graph (every pin's location, revision, root tree and manifest blob ids, plus sha256 of `Package.resolved`), and the reviewed macro/build-tool plugin components with their source-tree hashes (section 6)
- `scripts/assert-fork-identity.sh` -- the fork-identity guard, run against the built app and the project configuration (section 6)
- `scripts/verify-package-trust.sh` -- enforces `package-trust.json` before anything is built (section 6)
- `scripts/verify-meeting-store-isolation.sh` + `scripts/negative-controls/` -- source files that MUST NOT COMPILE, re-attacking `MeetingStore`'s isolation boundary on every CI run (stage2-models-store escalation round, section 4)
- `whisper-cpp.rev` -- the pinned whisper.cpp revision (section 6)


## phase-1-foundation (Stage 0: Meetings slice foundation)

Ported from Muesli-HQ/muesli into the new `VoiceInk/Features/Meetings/` slice, verbatim
(comments, branches and constants unchanged, MIT header + minimal import trims only):
`Capture/PCMChunkRecorder.swift` (donor 101 lines), `Capture/MeetingChunkTimingTracker.swift`
(58), `Capture/WavWriter.swift` (donor's full `WavWriter.swift`, pulled in unscoped because
`PCMChunkRecorder` calls it directly and every Stage-1 capture cluster needs it too),
`Capture/AudioSampleStats.swift` (extracted from `MeetingSessionDiagnostics.swift` lines 5-52,
along with `AudioSampleStatsSnapshot` since `.snapshot()` returns one), and the
`AudioGraphExceptionBridge` ObjC pair (`.h`/`.m`, ported from the donor's separate SwiftPM
target of the same name — see section 1 below for why that needed a bridging header).

Two fork-owned (not verbatim — the task descriptions of the donor equivalents were slightly
off, corrected after reading the real donor code) shared types in `Models/`:
- **`SpeechSegment.swift`**: three fields (`start: Double`, `end: Double`, `text: String`),
  `Sendable`. Donor's real type lives at `MuesliNativeApp/TranscriptionRuntime.swift:5`, not in
  the `MuesliCore` library target as the task brief assumed. Confirmed against all 11 donor
  construction sites — every one uses exactly this shape, nothing else.
- **`MeetingRuntimePaths.swift`**: donor's `RuntimePaths.swift` is actually about app-bundle
  resource resolution (icons), unrelated to meeting audio — not ported. What Stage-1 capture
  code needs instead comes from `MeetingSession.swift` (chunk-scratch directory names) and
  `MeetingRecordingWriter.swift` (permanent recording directory). The permanent directory is
  `~/Library/Application Support/<Bundle.main.bundleIdentifier>/MeetingRecordings/` — a
  sibling of VoiceInkEngine's own `Recordings/`, scoped by the running build's actual bundle
  identifier (not a hardcoded literal, so the Debug build — `com.hainesy.VoiceInkMeetings.dev`
  — and the Release build — `com.hainesy.VoiceInkMeetings`, both confirmed in this file's own
  `PRODUCT_BUNDLE_IDENTIFIER` settings — never share a meeting-audio directory). It is
  structurally exempt from BOTH of VoiceInk's existing audio-cleanup mechanisms: (1)
  `AudioCleanupManager` only ever deletes paths it reads from `Transcription.audioFileURL` in
  SwiftData, never scans a directory; (2)
  `TranscriptionAutoCleanupService.cleanupOrphanAudioFiles()` — the second, easy-to-miss
  mechanism, which also deletes files with no matching `Transcription` record — only lists its
  own hardcoded `Recordings/` directory, so a sibling directory is outside its scan by
  construction. Both read and confirmed directly, not assumed.

`MeetingPromptStateMachine.swift` was in scope but is NOT ported — see the dedicated section
below. Every fact needed to understand this stage's changes is above, in this document; this
entry covers the one upstream-file touch, against the ~6-touchpoint budget the note below sets
for Phase 1+.

### 1. `project.pbxproj`: `SWIFT_OBJC_BRIDGING_HEADER` added (VoiceInk target, Debug + Release)

`AudioGraphExceptionBridge` is ObjC (an `installTap` exception boundary AVFAudio needs, since
Swift cannot catch the NSExceptions it raises). In the donor it is its own SwiftPM module
target; VoiceInk.xcodeproj is a plain Xcode app target with no prior ObjC/Swift interop and no
bridging header at all. Calling ObjC from Swift within a single app target requires one, so
both `buildSettings` blocks for the `VoiceInk` native target (not the XPC service, not the
test targets) gained:

```
SWIFT_OBJC_BRIDGING_HEADER = "VoiceInk/Features/Meetings/Capture/VoiceInk-Bridging-Header.h";
```

Landed once, here, deliberately: had this been left for Stage 1, at least two of the four
parallel clusters (capture core, mic+route — both call into `installTap`) would likely have
needed the same setting independently, which is exactly the kind of `project.pbxproj`
collision this Stage-0 pass exists to avoid. `VoiceInk-Bridging-Header.h` itself is a new
fork-owned file (not from the donor), and only `#import`s the ported `AudioGraphExceptionBridge.h`.
No other upstream file was touched — new files under `VoiceInk/Features/Meetings/` and
`Tests/VoiceInkTests/Features/Meetings/` join their targets automatically
(`PBXFileSystemSynchronizedRootGroup`, confirmed for both `VoiceInk` and `VoiceInkTests`
before this stage began).

### Known gap: `MeetingPromptStateMachine.swift` NOT ported

Task scope named this as one of four "smallest verbatim ports" for `Detection/`. It doesn't
compile standalone: it references `MeetingCandidate` (id, suppressionID, evidence set),
defined in the donor's `MeetingCandidateResolver.swift` — 666 lines, a full meeting-detection
feature (platform enum, evidence enum, resolution logic), not a small shared primitive and not
in this task's scope. Porting `MeetingPromptStateMachine.swift` alone would either break the
build or require inventing a placeholder `MeetingCandidate` here that would collide with the
real one when the Detection cluster later ports `MeetingCandidateResolver.swift` for real.
Left unported; `VoiceInk/Features/Meetings/Detection/` currently holds only `.gitkeep`.
Recommendation for whichever Stage-1 cluster owns Detection: port
`MeetingPromptStateMachine.swift` and `MeetingCandidateResolver.swift` together, verbatim, in
the same change, under the same non-negotiable porting rules (every comment, every branch).

## phase-1-mic-route (Stage 1: mic capture and audio route control)

### 1. `.github/workflows/ci.yml`: `TEST_RUNNER_VOICEINK_CI` added to the "Run test targets" step

This stage's port (`MeetingMicRecording`, `StreamingMicRecorder`, `AudioRouteController`,
`MeetingMicHealthTracker`, `MeetingMicRecoveryCoordinator`, `AudioQueueInputRecorder`,
`FallbackStreamingDictationRecorder`, verbatim, plus their donor tests) is itself hardware-free
by construction: none of it constructs a real `AVAudioEngine`, `AudioQueueRef`, or performs
live CoreAudio device enumeration — every test doubles as a fake (`FakeMeetingMicRecorder`,
`FakeCoreAudioDeviceInspector`, `FakeFallbackStreamingRecorder`). Landing it, however, added
enough concurrent test load to a shared xctest bundle to reliably expose a pre-existing hazard
in Stage 0's `AudioGraphExceptionBridgeTests.swift`: its two tests each construct a real
`AVAudioEngine` and touch `engine.inputNode`, which blocks for ~600s negotiating against GitHub
Actions' specific CoreAudio device inventory. Verified empirically across three CI runs —
33555297407, 33561167080, 33565271509 — not assumed: a device-count guard
(`CoreAudioDeviceInspector().availableInputDevices()` non-empty) was tried first and disproven
when it evaluated true on the runner (which does enumerate at least one input-capable object,
contradicting "no audio hardware at all") while the calls still hung; a plain
`GITHUB_ACTIONS`/`CI` environment-variable guard was tried next and disproven locally, before
ever reaching CI, when setting either variable on the invoking `xcodebuild` process had no
effect on the value read inside the actual test run.

The fix needed a way for a test body to tell "GitHub Actions' runner" apart from "a developer
Mac" from *inside* the actual xctest host process, which does not inherit the invoking shell's
environment (`xcodebuild test` launches it via a LaunchServices-mediated path — see the
`CodeSign`/`RegisterExecutionPolicyException` steps around it in any CI log). Xcode's
documented mechanism for exactly this — any environment variable on the process that invokes
`xcodebuild` prefixed `TEST_RUNNER_` is forwarded into the launched test host with the prefix
stripped — was verified empirically before landing, not assumed: `env
TEST_RUNNER_VOICEINK_CI=1 xcodebuild test ...` locally flips
`ProcessInfo.processInfo.environment["VOICEINK_CI"]` from absent to `"1"` inside the actual
test run (confirmed both directions: present → the three gated tests report `skipped`, 0.000s;
absent → they execute for real and `pass`, ~0.05-2s). Passing `TEST_RUNNER_VOICEINK_CI=1` as a
trailing `xcodebuild` argument instead (a build-setting override, not a process environment
variable) does **not** work — confirmed by the same experiment failing until moved to a real
`env:`.

The change is a step-level `env:` block, additive only, touching no other step and no other
job:

```yaml
- name: Run test targets
  env:
    TEST_RUNNER_VOICEINK_CI: 1
  run: |
    xcodebuild test \
      ...
```

This is the only change to `.github/workflows/ci.yml` in this stage, authorised specifically
for this fix by the reviewer of PR #3's first CI-failure round (change request logged in the
PR; not a general license to edit CI). `AudioGraphExceptionBridgeTests.swift`'s guard reads
`VOICEINK_CI` (the `TEST_RUNNER_` prefix already stripped) via
`ProcessInfo.processInfo.environment["VOICEINK_CI"] != nil`, gating all three of its tests
(the two donor tests plus the previously-reverted `installTapExceptionIsContained`, restored
under the same guard in this same change). None of this stage's own 7 ported source files or 6
ported test files needed any change to reach this fix.
## phase-1-vad-chunking (Stage 1: VAD chunking and transcript assembly)

Ported verbatim into `VoiceInk/Features/Meetings/Transcription/`:
`StreamingVadController.swift` (donor 225 lines, byte-identical), `TranscriptFormatter.swift`
(donor 226, only `import MuesliCore` dropped), `TranscriptReconciler.swift` (donor 321, same),
and `DiarizerRuntimePolicy.swift` (donor 306, one flagged deviation below). This section exists
even though these files live entirely under `Features/Meetings/` — normally exempt per this
file's header — because an independent review round required the one deviation below to be
recorded here explicitly, not just in the file's own header comment.

### `DiarizerRuntimePolicy.swift`: `DiarizerPreloadDiagnostics`'s default `signalSink`

The donor's `DiarizerPreloadDiagnostics.init` (donor `DiarizerRuntimePolicy.swift:176-186`)
defaults `signalSink` to:

```swift
signalSink: @escaping SignalSink = { event, parameters in
    TelemetryDeck.signal(event, parameters: parameters)
}
```

This fork has no `TelemetryDeck` dependency (confirmed by grepping `Package.resolved` and
`project.pbxproj` — 28 pinned packages, none of them TelemetryDeck; VoiceInk has no telemetry
system at all yet), and adding one is out of scope for this stage: it would mean editing
`project.pbxproj` (forbidden for this cluster) and `package-trust.json` (owned by a different
concurrent change). The verbatim default cannot compile as-is.

**First attempt (reverted): a no-op default.** An earlier pass of this file replaced the default
with `{ _, _ in }`. Independent cross-vendor review correctly flagged this as an unacceptable
silent behavior change: every production caller that relies on the default (which is every real
caller — none inject an explicit sink) would silently lose every preload
started/ready/failed/interrupted diagnostic, with nothing anywhere signaling that anything had
been dropped. A silent no-op default is not acceptable in any form, per that review.

**Fix applied.** `signalSink` stays a defaulted parameter — same shape as the donor, so no call
site is forced to change — but the default now logs through this fork's existing `os.Logger`
facility (`Logger(subsystem: "com.hainesy.voiceinkmeetings", category: "DiarizerPreloadDiagnostics")`,
the same convention used throughout the rest of the app, e.g. `VoiceInk/App/VoiceInk.swift`)
instead of calling `TelemetryDeck.signal` or doing nothing. Preload diagnostics remain observable
in Console.app / `log stream` until a real telemetry backend replaces this default. Every call
site in the ported test suite (`DiarizerRuntimePolicyTests.swift`) already supplies its own
explicit `signalSink`, so this default is only ever exercised by production code that hasn't been
given one — no test behavior depends on it. Everything else in the file, including every comment
and the M1/macOS-15.1 GPU-avoidance branch (FluidAudio issue #344), remains byte-for-byte
identical to the donor.

### `MeetingVadStreams.swift` and `ADAPTER-HANDOVER.md`: new fork-owned files, not ports

Added in the same review round, for a different finding: `StreamingVadController.processAudio(_:)`
takes an untyped `[Float]`, so nothing in this cluster's own code enforced the donor's
AEC-cleaned-mic-only / raw-system-only split (`MeetingSession.swift:1226-1233` and
`:1257-1262`) once a later adapter stage started wiring real audio in. `MeetingVadStreams.swift`
adds `MicVadStream`/`SystemVadStream`, a facade over the (unedited) ported
`StreamingVadController`, with distinct nominal wrapper types (`RawMicSamples`,
`RawSystemSamples`) so feeding the wrong stream to the wrong VAD is a compile error. `MicVadStream`
additionally owns the AEC call itself (`MicEchoCanceller`), so there is no API by which raw mic
samples can reach the mic VAD un-cancelled: the facade takes raw samples and runs the canceller
itself, and `AECCleanedMicSamples` is an unforgeable receipt it hands back rather than an input a
caller constructs. Two earlier designs that instead restricted who could CONSTRUCT that type were
both defeated (a trapping protocol witness; a cross-file extension initializer assigning an
internal stored property) -- see that file's header comment for both defeats, and
`MeetingVadStreamsTests.swift` for the full attack list with each verbatim compiler error. The two
residual holes are stated there and accepted: passing a no-op canceller, and `unsafeBitCast`.
`ADAPTER-HANDOVER.md`, alongside it in the same directory, is the self-contained (in-repo, no
`.tandem/` dependency) handover document for the next stage, covering AEC/VAD wiring, rotation
inputs/outputs, reconcile-before-format ordering, and diarizer preload/cancellation semantics,
all cited against donor file/line references.
## phase-1-aec-dtln (Stage 1: Acoustic Echo Cancellation, DTLN path)

Ports the donor's meeting AEC engine, DTLN path only (LocalVQE deferred; Apple Voice Processing
I/O rejected — both settled by the Phase 1 AEC de-risk investigations at
`.tandem/884f6ef6905c4e2aa4e2ca28c34ea629/{dtln-aec-viability,vpio-aec-spike}.md`, outside this
repo): `Capture/MeetingNeuralAec.swift` (donor 796 lines, DTLN-only excision — 4 points: the
`preload()` LocalVQE-first branch removed, `MeetingAecProcessorSelection` trimmed 3→1 case, the
`localvqe` special case in `referenceDelaySamples()` dropped, `LocalVQEProcessor.swift`/
`LocalVQEBridge` never ported at all — delay estimator and buffer/trim machinery kept verbatim,
load-bearing on DTLN), `Capture/MeetingAecDiagnostics.swift` (extracted from
`MeetingSessionDiagnostics.swift` donor lines 72-156: `MeetingAecDiagnosticsSnapshot` +
its `Decodable` extension, `MeetingAecDelayObservation`, `MeetingAecDelayCandidateScore`,
`MeetingAecDelaySkip` — same donor file as `Capture/AudioSampleStats.swift` (lines 5-52, Stage 0)
and capture-core's `SystemAudioCaptureDiagnostics.swift` (lines 54-71), three different slices of
one donor file ported independently by three different agents; the `MeetingSessionDiagnostics`
aggregator class itself, donor line 158+, is not ported — MeetingSession integration owns it),
and `Tests/.../MeetingNeuralAecTests.swift` (15 of the donor's 17 `@Test`s; 2 dropped —
`localVQEBridgeRejectsEmptyModelPath`, `localVQEBridgeReportsMissingLibraryPath` — called the
`LocalVQEBridge` C target directly and would no longer compile).

Adds `MeetingAecRouteBypassSource`, a small protocol (new, not from the donor — the donor never
gated meeting AEC on route) letting a headphone-like audio route bypass DTLN per mic chunk;
seamed for the MeetingSession integration owner to wire to the real `AudioRouteClassifier`
(ported separately, for dictation today).

### 2. `project.pbxproj`: `dtln-aec-coreml` package reference + `DTLNAecCoreML`/`DTLNAec512` product links (VoiceInk target)

This is an upstream-owned-file touch outside the `Features/Meetings/` slice, so it counts against
the Phase 1+ budget the note below sets — and, same as section 1's bridging-header entry, it is
logged here as a deliberate, one-time addition rather than left implicit in a diff.

**Why this one is unavoidable, not a workaround.** Linking a Swift Package product into an Xcode
target's build graph is not expressible any other way in a plain `.xcodeproj` (this project has
no root-level `Package.swift` for the app itself — every dependency is an Xcode-managed
`XCRemoteSwiftPackageReference`/`XCSwiftPackageProductDependency` pair, entirely inside
`project.pbxproj`). There is no `xcodebuild` verb to add a package reference; only Xcode's GUI or
a direct pbxproj edit can do it, and both mutate the same bytes. Confirmed empirically before
touching anything: with `dtln-aec-coreml` pinned in `Package.resolved` and both new Swift files
in place (picked up automatically via `PBXFileSystemSynchronizedRootGroup`, no pbxproj edit
needed for those), the *only* build error in the whole log was
`MeetingNeuralAec.swift:53:8: error: Unable to resolve module dependency: 'DTLNAecCoreML'`.

**Why this Stage-1 cluster specifically, and not left for a later serial merge.** The four
parallel Stage-1 agents (capture core, mic+route, AEC, VAD chunking) were each told not to touch
`project.pbxproj`, to avoid a four-way collision on one shared file. Checked before editing: the
capture-core cluster had already finished and had not touched it; mic+route and vad-chunking were
both instructed not to and have no reason to (neither adds an SPM dependency). With no live
collision risk, adding it here — once, minimally — is cheaper than adding a fifth, purely
mechanical hand-off step whose only job would be this exact 6-hunk edit.

**The edit, and confirmation every hunk was read.** Six additive hunks, no reformatting, no
`objectVersion`/`preferredProjectObjectVersion` change, modeled directly on the existing
`swift-huggingface` entry (same `exactVersion` requirement shape) and on `mlx-swift-lm` (same
one-package/two-products shape, there `MLXLLM`+`MLXLMCommon`, here `DTLNAecCoreML`+`DTLNAec512`):

1. `PBXBuildFile` section: 2 new entries (`DTLNAecCoreML in Frameworks`, `DTLNAec512 in
   Frameworks`), each `productRef`-linked to its `XCSwiftPackageProductDependency`.
2. `VoiceInk` target's `Frameworks` build phase `files` list: the same 2 entries appended.
3. `VoiceInk` target's `packageProductDependencies`: 2 entries appended (test targets and
   `VoiceInkRefineXPC` untouched — nothing in this port is referenced outside the `VoiceInk`
   app target; the ported test file uses `@testable import VoiceInk` only, never
   `import DTLNAecCoreML` directly).
4. `PBXProject.packageReferences`: 1 entry appended
   (`XCRemoteSwiftPackageReference "dtln-aec-coreml"`).
5. `XCRemoteSwiftPackageReference` section: 1 new block, `repositoryURL =
   "https://github.com/MimicScribe/dtln-aec-coreml.git"`, originally `requirement = { kind =
   exactVersion; version = 0.7.0; }` — pinned exact, not `upToNextMajorVersion`, since this
   package is archived and will never publish a compatible newer tag to float onto. **Repinned
   to `{ kind = revision; revision = ecb641dcb4b152fd10b1261a869aaa1e8acf0174; }` shortly after
   — see the dedicated subsection below — for a LICENSE fix found during review, not for any
   code reason.**
6. `XCSwiftPackageProductDependency` section: 2 new blocks (`DTLNAecCoreML`, `DTLNAec512`), both
   `package`-linked to the one reference above.

`git diff VoiceInk.xcodeproj/project.pbxproj` was read in full after the edit — all 6 hunks are
attributable to exactly this package link, nothing else. `xcodebuild -resolvePackageDependencies`
afterward resolved `DTLNAecCoreML` at `0.7.0` and left `Package.resolved` byte-identical to the
version already committed (the manual pin added ahead of this edit — see the AEC task report —
matched exactly what a real Xcode resolution produces). `scripts/verify-package-trust.sh` passed
unchanged. Debug build and the full local test run (`xcodebuild test`, CI's exact invocation)
both succeeded afterward — see the AEC task report,
`.tandem/884f6ef6905c4e2aa4e2ca28c34ea629/aec-dtln.md`, for the literal commands and output.

### 3. `dtln-aec-coreml` repinned from tag `0.7.0` to commit `ecb641d`, for a LICENSE fix

The review that produced section 2's pin found that `LICENSE` at tag `0.7.0` read verbatim
`Copyright (c) 2026 Anthropic` — not MimicScribe, the actual publisher — unchanged since the
repo's first commit and identical at the donor's older `0.6.0-beta` pin, with the same
misattribution in `DTLNAecCoreML.podspec` (`s.author`, `s.homepage`, `s.source` all pointing at
an unrelated `anthropics/` GitHub org). An MIT grant is only worth what the granting party can
actually grant. The maintainer's very next commit, `ecb641d` — one commit past the `0.7.0` tag,
and the current archived HEAD — fixes exactly that (LICENSE and podspec renamed to MimicScribe)
and nothing else functional, and additionally adds the archive notice to the README.

**Verified docs-only before repinning**, so this costs nothing in code: `git diff
0.7.0..ecb641d --stat` touches exactly 4 files (`DTLNAecCoreML.podspec`,
`Documentation/GettingStarted.md`, `LICENSE`, `README.md`) — zero changes under `Sources/`, to
`Package.swift`, under `ThirdPartyLicenses/`, or to any `.mlpackage` resource. Confirmed by git
object identity, not just diff absence: the `Sources/` tree
(`9d3f71f8f9ab8ac185c4b79425f913c27edd7067`) and the `Package.swift` blob
(`e41c9ef8064ee1cd1ad964e9ce23e1dce05f8f07`) are byte-identical at both revisions. Nothing in
`MeetingNeuralAec.swift` or its tests needed to change.

**The pbxproj edit for the repin** was a single-hunk, one-line-pair change to the existing
`XCRemoteSwiftPackageReference "dtln-aec-coreml"` block's `requirement`, from `kind =
exactVersion; version = 0.7.0;` to `kind = revision; revision =
ecb641dcb4b152fd10b1261a869aaa1e8acf0174;` (pinning a commit rather than a tag requires the
`revision` requirement kind). Read in full; nothing else in the file changed.
`xcodebuild -resolvePackageDependencies` resolved `DTLNAecCoreML` at `ecb641d` afterward;
`scripts/verify-package-trust.sh --update` re-blessed the moved pin; Debug build and the full
local test run both succeeded again. Full history of the LICENSE finding, kept rather than
discarded, lives in the `dtln-aec-coreml` entry's `note` field in `package-trust.json` and in
the AEC task report.

### 4. `scripts/verify-package-trust.sh`: plain-package `note` field now survives `--update`

Found while writing the note above: `--update` already preserves an existing `note` across runs
for the `components` section (`entry.get("note", "PENDING REVIEW")`), but rebuilds each plain
package's `graph.packages` record from scratch every time, with no equivalent preservation. A
`note` manually added to a package (as done here, twice, once for each pin) would be silently
dropped by the very next `--update` for a completely unrelated pin bump elsewhere in the graph
— and `verify` mode would keep passing, since it only compares `location`/`revision`/`tree`/
`manifests`, not `note`, so nobody would notice. Fixed surgically: in the same loop that builds
each package's record, look up the previously-trusted record for that identity and carry its
`note` forward if one exists (mirrors the components pattern; does *not* default-inject
`"PENDING REVIEW"` onto every plain package, since most carry no note and don't need one).

**Proved with a real, reversible test**, not just reasoning about the code: temporarily bumped
`KeySender`'s pin in `Package.resolved` to a different, real commit on its own repo
(`bd01c54755b337ea63211656dab916afe7e40357`, an unrelated package to `dtln-aec-coreml`), ran
`scripts/verify-package-trust.sh --update`, and confirmed both halves of the result: KeySender's
own record genuinely changed (`~ package keysender: 99584bf1a03a -> bd01c54755b3`, proving this
was a real re-bless, not a no-op), and `dtln-aec-coreml`'s `note` survived intact (present,
correct length, revision unchanged) despite having nothing to do with the pin that moved. Then
reverted KeySender's pin back to its correct committed revision and ran `--update` once more to
restore the clean, correct final state — confirmed with `scripts/verify-package-trust.sh`
(verify mode) passing and `git diff --stat` showing no residual KeySender change anywhere.

## Architecture budget note

The instruction for this project caps ongoing upstream touchpoints (outside the new
`Features/Meetings/` slice) at roughly 6. That budget is for Phase 1+ feature work layered on
top of a clean base — it does not describe Phase 0 itself, whose entire job is editing
upstream-owned files (identity, signing, Sparkle, delicensing) exactly once, up front, so later
phases don't have to. This entry is long because Phase 0 is supposed to be long; Phase 1 onward
should look nothing like this.

## phase-1-capture-core (Stage 1: system audio capture core)

### 1. `VoiceInk/Info.plist`: `NSAudioCaptureUsageDescription` added

The CoreAudio process-tap path (`CoreAudioSystemRecorder.swift`) triggers the system "would
like to record audio from other applications" dialog only if `NSAudioCaptureUsageDescription`
is present in `Info.plist` — otherwise the tap creation call fails outright rather than
prompting. Key was not already present (`NSMicrophoneUsageDescription`,
`NSAppleEventsUsageDescription` and `NSScreenCaptureUsageDescription` were; this one wasn't).
Added, matching the existing string style:

```
<key>NSAudioCaptureUsageDescription</key>
<string>VoiceInk captures system audio from other applications during meeting recordings.</string>
```

This is the ~2nd of the ~6-touchpoint Phase 1+ budget the note above sets. Confirmed against
the donor's own `scripts/build_native_app.sh` (which injects the same key at build time with
`$APP_DISPLAY_NAME captures system audio from other applications during meeting recordings.`)
and `REVIEW.md` ("System audio capture through the CoreAudio tap path uses audio-capture TCC
(`kTCCServiceAudioCapture`) and does not require Screen Recording") — the permission this key
gates is `kTCCServiceAudioCapture`, a distinct TCC service from `NSScreenCaptureUsageDescription`
(Screen Recording), which the app already requests for a different feature (screen context).

### Note: new fork-only file not from the donor

`VoiceInk/Features/Meetings/Capture/SystemAudioCaptureDiagnostics.swift` is new, not upstream —
no entry needed under the rule at the top of this file ("New code that lives entirely under
`Features/Meetings/` ... does not need an entry here"). Logged anyway for visibility: it
extracts `SystemAudioCaptureDiagnosticsSnapshot` and `SystemAudioDiagnosticsProviding` verbatim
from the donor's `MeetingSessionDiagnostics.swift` (lines 54-70), the same donor file
`AudioSampleStats.swift` was already extracted from in Stage 0. Both `CoreAudioSystemRecorder.swift`
and `SystemAudioRecorder.swift` conform to `SystemAudioDiagnosticsProviding` and cannot compile
without it; the rest of `MeetingSessionDiagnostics.swift` (AEC delay estimation, diarization
counts, chunk health, the `MeetingSessionDiagnostics` class itself) is NOT ported and remains
Stage-2/MeetingSession-owned. The extraction was judged in-scope, rather than logged as a
"Known gap", because those 17 lines are pure declarations (one snapshot value type and one
protocol) that two ported files cannot compile without, and because Stage 0 set exactly this
precedent by extracting `AudioSampleStats.swift` from the same donor file. It is distinct from
the Stage 0 decision NOT to port `MeetingPromptStateMachine.swift`: that would have required
inventing a placeholder for `MeetingCandidate`, a type belonging to a detection subsystem that
has not been designed yet, which is a different act from lifting declarations verbatim.
should look nothing like this. Stage 1's own touchpoint count so far: 2 (Stage 0's bridging
header, this stage's package link) — both one-time additions to a target's build graph, not
recurring edits, and both logged with the same rationale: confirmed unavoidable, confirmed
minimal, confirmed no live collision with a parallel agent.

## stage2-models-store (Stage 2a: meeting data layer)

Adds `Meeting.swift`, `MeetingSegment.swift` (both `Models/`), `MeetingSegmentPersistenceActor.swift`
(`Models/`, renamed from `MeetingSegmentPersistenceService.swift` in the fix round below) and
`MeetingState.swift` (`State/`) — all new, entirely under `Features/Meetings/`, so none of them
need an entry here under this file's own rule. This section covers the upstream-file touches
this stage makes: `VoiceInk/App/VoiceInk.swift` here, and `.gitignore` added in the escalation
round below (section 9). Two in total. Nothing else upstream-owned is edited by this stage.

### 1. `VoiceInk/App/VoiceInk.swift`: a 4th SwiftData store, `meetings.store`

Follows the existing three-store pattern (`default.store` / `dictionary.store` / `stats.store`,
`createPersistentContainer`/`createInMemoryContainer` around lines 211-274) exactly, rather than
inventing a new one:

- `Meeting.self` and `MeetingSegment.self` appended to the top-level `schema` array passed to
  `ModelContainer(for:configurations:...)`, after `SessionMetric.self` — same "append new models
  after synced entities" ordering the existing comment there already asks for.
- A fourth `ModelConfiguration("meetings", schema: Schema([Meeting.self, MeetingSegment.self]),
  url: meetingsStoreURL, cloudKitDatabase: .none)` in `createPersistentContainer`, `meetingsStoreURL`
  = `<AppSupport>/meetings.store`, sibling of the other three store files. `.none` for CloudKit,
  matching `statsConfig`/`transcriptConfig` (this fork has no iCloud container yet — see the
  Phase 0 "iCloud container removed" section above; `dictionaryConfig` is the one exception, and
  that exception is itself already logged there).
- The matching in-memory `ModelConfiguration("meetings", schema: ..., isStoredInMemoryOnly: true)`
  added to `createInMemoryContainer`, and both `ModelContainer(for:configurations:...)` calls
  updated to pass the new config — so the existing in-memory-fallback-with-alert behavior (an
  `NSAlert` warning the user their data won't persist, wired in `init()`, not touched by this
  change) applies to meetings storage exactly the same way it already does to the other three.

Why a fourth store rather than folding `Meeting`/`MeetingSegment` into `default.store`
(`Transcription`'s store): meeting audio and metadata are a structurally separate concern from
dictation transcripts (see `MeetingRuntimePaths.swift`'s header on why meeting audio already
lives in a sibling directory, exempt from both of VoiceInk's audio-cleanup mechanisms), and a
separate store keeps that separation true at the persistence layer too — a future retention or
export policy for meetings can target `meetings.store` without needing a predicate that
distinguishes model types within a shared store.

No other upstream file was touched. `Meeting.self`/`MeetingSegment.self` join the `VoiceInk` and
`VoiceInkTests` targets automatically via the existing synchronized root groups, same as every
other Stage 1 addition under `Features/Meetings/`.

### Note: `MeetingState` is intentionally not `RecordingState`

`VoiceInk/Features/Meetings/State/MeetingState.swift` is a new, separate enum — it does not
extend, wrap, or otherwise touch `VoiceInk/Core/Recording/RecordingState.swift` or
`VoiceInkEngine`. See that file's own header comment for the reasoning: `RecordingState` is
upstream's flat 6-case dictation lifecycle, consumed exhaustively elsewhere, and a meeting
recording's lifecycle (pausable; a distinct "finalizing" step) doesn't map onto it cleanly
enough to be worth the collision risk of adding cases to a type six call sites already switch
over exhaustively.

### Note: unit tests need no `TEST_RUNNER_VOICEINK_CI` gating

`Tests/VoiceInkTests/Features/Meetings/Models/MeetingModelTests.swift` and
`MeetingSegmentPersistenceActorTests.swift` run entirely against an in-memory SwiftData
`ModelContainer` (`ModelConfiguration(isStoredInMemoryOnly: true)`) — no `AVAudioEngine`, no
`AudioQueueRef`, no CoreAudio device enumeration, nothing that touches the hardware inventory
`AudioGraphExceptionBridgeTests.swift`'s CI-only skip (`phase-1-mic-route` section above) exists
to work around. Confirmed by running the full local suite with `TEST_RUNNER_VOICEINK_CI` both
set and unset: identical pass/fail results either way. No new gating was added.

## stage2-models-store fix round (review response)

Independent review of the PR above returned CHANGES-REQUIRED on one blocking issue
(concurrency safety was contractual, not enforced) and one test-honesty issue (the
"crash loses nothing" test proved cross-context object visibility inside one live container,
not durability across a process death). Both are fixed here, in the same two files this
stage already owned (`MeetingSegmentPersistenceService.swift`, renamed to
`MeetingSegmentPersistenceActor.swift`, and its test file, likewise renamed, plus a new
`MeetingSegmentPersistenceActorDurabilityTests.swift`). No third upstream-file touch was
needed; `VoiceInk/App/VoiceInk.swift` is unchanged from the entry above, and the reviewer's own
correction — that listing `Meeting.self`/`MeetingSegment.self` in both the aggregate `Schema`
and `meetingsConfig` does NOT create store ambiguity, because the aggregate schema isn't a
store assignment mechanism — is recorded here so it isn't re-litigated: that wiring is
untouched, and should stay untouched.

### 1. Concurrency: `MeetingSegmentPersistenceService` (struct wrapping a caller-supplied
`ModelContext`) → `MeetingSegmentPersistenceActor` (`@ModelActor`, `PersistentIdentifier` in
and out)

The struct's real defect: it accepted any `ModelContext` and exposed synchronous methods
taking/returning managed `Meeting` objects, with only a doc comment telling callers to "hop to
the context's own actor" first — a documented contract, not a structural one, and the project's
own hard-won lesson (two earlier "safe" type boundaries elsewhere in this codebase were each
defeated in one line by review because the guarantee was documented rather than compiler-
enforced) says that doesn't count as fixed.

**Fix.** `@ModelActor actor MeetingSegmentPersistenceActor` — SwiftData's purpose-built tool for
this exact problem (<https://developer.apple.com/documentation/swiftdata/modelactor>). The
macro synthesizes the actor's own `ModelContext` from a `ModelContainer` passed to the generated
`init(modelContainer:)`, so the type is now constructed from a container, never handed someone
else's context, matching the reviewer's explicit direction. Every public method takes and
returns `PersistentIdentifier` (`Sendable`, `Hashable`, `Codable`) instead of a managed
`Meeting`/`MeetingSegment` — no managed object of either type ever crosses the actor boundary.

**The property this structurally guarantees, verified by attacking it, verbatim.** Per the
brief's instruction, three deliberate violations were written against this file in a scratch
test file (`Tests/VoiceInkTests/Features/Meetings/Models/ScratchAttack.swift`), built, the exact
compiler output captured below, then the scratch file deleted — it is not part of this PR's
diff:

```swift
// ATTACK 1: pass a managed `Meeting` object where a `PersistentIdentifier` is required.
func attackPassManagedObjectAcrossBoundary(
    actor: MeetingSegmentPersistenceActor, meeting: Meeting
) async throws {
    try await actor.appendSegment(
        startOffset: 0, endOffset: 1, speakerLabel: "You", text: "x",
        sourceChannel: .mic, to: meeting
    )
}

// ATTACK 2: call an actor-isolated method synchronously, without `await`.
func attackCallWithoutAwait(actor: MeetingSegmentPersistenceActor, id: PersistentIdentifier) throws {
    try actor.updateState(.paused, for: id)
}

// ATTACK 3 (expected, per older SwiftData write-ups, to compile — it did NOT, see below):
func attackReachThroughNonisolatedModelContext(actor: MeetingSegmentPersistenceActor, meeting: Meeting) {
    actor.modelContext.insert(meeting)
}
```

Verbatim `xcodebuild build-for-testing` output (Xcode 26.6, macOS SDK):

```
ScratchAttack.swift:13:34: error: cannot convert value of type 'Meeting' to expected argument type 'PersistentIdentifier'
    sourceChannel: .mic, to: meeting
                             ^
ScratchAttack.swift:19:15: error: call to actor-isolated instance method 'updateState(_:for:)' in a synchronous nonisolated context
    try actor.updateState(.paused, for: id)
              ^
VoiceInk.MeetingSegmentPersistenceActor.updateState:2:15: note: calls to instance method 'updateState(_:for:)' from outside of its actor context are implicitly asynchronous
internal func updateState(_ state: VoiceInk.MeetingState, for meetingID: PersistentIdentifier) throws}
              ^
ScratchAttack.swift:25:11: error: actor-isolated property 'modelContext' can not be referenced from a nonisolated context
    actor.modelContext.insert(meeting)
          ^
```

**No residual hole, and this was checked rather than assumed — a correction to the brief's own
premise.** The brief (correctly describing older SwiftData documentation) expected attack 3 to
compile clean, exposing `AnyModelActor.modelContext`'s documented `nonisolated` declaration as
an unclosable framework gap. It does not compile on this project's actual toolchain: reading
`/Applications/Xcode-26.6.0.app/.../SwiftData.framework/.../arm64e-apple-macos.swiftinterface`
directly shows `extension ModelActor { public var modelContext: ModelContext { get } }` with
**no** `nonisolated` modifier, which makes it actor-isolated by default on this SDK — and attack
3's compiler error confirms it empirically, not just from reading the interface. So: no
disclosed hole here, because there genuinely isn't one on this SDK. (A future SDK could in
principle change this back; if `attackReachThroughNonisolatedModelContext`-shaped code ever
starts compiling clean, that is the signal something regressed.)

### 2. A second, worse crash found by attacking the actor's own identifier lookup

Writing the "unknown identifier" test (`unknownIdentifierThrows`, an identifier from a
different `ModelContainer` passed into a legitimate actor call) surfaced a real production bug,
not just a test gap: SwiftData's own identifier-lookup APIs are not safe against a foreign
`PersistentIdentifier`, in two different ways, both proven with real crash evidence rather than
inferred:

- **`ModelContext.model(for:)`** returns a plain `any PersistentModel` (no `Optional`), so
  `modelContext.model(for: id) as? Meeting` looks like a normal nil-on-miss check. It isn't:
  touching the returned fault crashes the process outright —
  `SwiftData/BackingData.swift:1057: Fatal error: This model instance was invalidated because
  its backing data could no longer be found the store` — reproduced against a `startMeeting`'d
  meeting from one in-memory `ModelContainer`, looked up through a second, unrelated
  `ModelContainer`'s context.
- **`ModelActor`'s own built-in `self[id, as: Meeting.self]` subscript** — the framework's
  purpose-built, `Optional`-returning lookup for exactly this situation — was tried as the
  natural replacement for a hand-rolled fallback, and is WORSE: it does not return `nil` for a
  foreign identifier, it returns a non-nil but invalid `Meeting`. The `guard let` in
  `meeting(for:)` then passes, and the crash only happens on the NEXT property mutation. Caught
  by the full local test suite (not by inspection): `~/Library/Logs/DiagnosticReports/VoiceInk
  Dev-2026-09-02-083842.ips`, `EXC_BREAKPOINT`/`SIGTRAP`, symbolicated stack bottoming out at
  `Meeting.duration.setter` → SwiftData's `Observation` machinery → `_assertionFailure`, from
  `MeetingSegmentPersistenceActorTests.unknownIdentifierThrows()` calling
  `actor.updateDuration(10, for: foreignID)`. This is a strictly worse failure mode than
  `model(for:)`'s: it defers the crash past the "did I find it" check into whatever mutation
  happens to run next, so a naive `guard let ... else { throw }` around it looks correct and
  isn't.

**Fix, verified as the one approach that survives being attacked.**
`MeetingSegmentPersistenceActor.meeting(for:)` uses neither: `modelContext.registeredModel(for:
id)` first (a pure in-memory lookup, no store access — this actor's own context always has a
`Meeting` registered the instant `startMeeting` creates it, so every legitimate call in a single
actor's lifetime hits this branch), falling back to a `FetchDescriptor<Meeting>(predicate:
#Predicate { $0.persistentModelID == id })` for an identifier the context hasn't seen yet (a
real store query — an absent row is an empty result, not a fault to materialize, so it degrades
to "throw `.meetingNotFound`" instead of crashing). Verified against all three call shapes: a
foreign-container identifier (throws, no crash), a same-session identifier the actor's own
context already has registered (works, as before), and — new coverage — a same-session
identifier the actor's context has NOT yet registered
(`MeetingSegmentPersistenceActorTests.unknownIdentifierThrows` no longer crashes; the durability
tests below exercise the "not yet registered" fetch path directly, since a freshly reopened
container never has anything registered).

### 3. The durability test now proves the actual guarantee, against a real on-disk store

`MeetingSegmentPersistenceActorDurabilityTests.swift` (new file) replaces the previous
in-memory-only "crash loses nothing" coverage. It writes a meeting and five segments through a
`ModelConfiguration(schema:url:)` (a real temp-directory SQLite file), lets the writing
`ModelContainer`/actor go completely out of scope with **no** `finish` call (standing in for a
crash mid-meeting), then opens a **brand-new** `ModelContainer` against the same file and
asserts every segment is present, in the correct order (`startOffset`, then `orderIndex`
tiebreak), and still attached to its meeting. A second test does the same for `updateDuration`
+ `finish`. Runs on a CI runner with no audio hardware — only a temp-directory file, cleaned up
in a `defer`.

**A second empirical finding, this one about test-writing, not the actor.**
`readContext.model(for: meetingID)` on the freshly reopened container hit the exact same
`SwiftData/BackingData.swift` crash class described in section 2 above — this time not because
the identifier was foreign, but because a brand-new context has nothing registered yet, and
`model(for:)`'s crash-on-fault behavior doesn't care why the row can't be resolved through that
path. Fixed the same way as the actor: `readContext.fetch(FetchDescriptor<Meeting>())` instead.

**A third finding, more consequential for whoever builds MeetingEngine's crash recovery.** The
first version of this test also asserted `reread.persistentModelID == meetingID` (the identifier
captured before teardown, compared against the identifier of the row read back after reopening).
That assertion FAILED — reliably, not flakily — even though the store UUID, entity name, and
primary key all matched in the debug description. This is not a bug in this PR; it's Apple's own
documented behavior (`PersistentIdentifier` is valid only for the lifetime of the `ModelContainer`
that produced it) proven empirically rather than taken on faith. **Implication recorded here so
it isn't rediscovered the hard way later:** a future MeetingEngine crash-recovery feature that
needs to find "the still-`.recording` meeting from last session" on relaunch must query for it
(by `state`, or by this app's own `Meeting.id: UUID`), never by holding onto and reusing a
`PersistentIdentifier` saved from a previous process. The durability tests now compare
`Meeting.id` (this app's own stored UUID, captured from a plain read on the still-live container
before teardown) instead, and use reference equality (`$0.meeting === reread`) for the
segment-to-meeting relationship check, which is valid because both sides are fetched into the
same `readContext`.

### Verification

Full local suite (`xcodebuild test`, CI's exact invocation, `-destination 'platform=macOS'`,
parallel test execution as CI runs it) green twice in a row after the fixes above, plus the
isolated new-test-only run (non-parallel) used to bisect each crash down to its actual test and
call site. `scripts/verify-package-trust.sh` passes unchanged (no new dependency). Diagnostic
report paths for both crash discoveries are cited above rather than only described, so they can
be re-read if this ever needs re-verifying.

## stage2-models-store escalation round (second review response)

The fix round above was reviewed again and returned CHANGES-REQUIRED on the same property for
the second time: the `@ModelActor` boundary is structurally defeatable. Everything else that
round established stands and is untouched — the schema design, the 4-store wiring in
`VoiceInk/App/VoiceInk.swift` (unchanged in this round), the `registeredModel`-then-fetch
identifier lookup, and both `PersistentIdentifier` landmines recorded above. This entry covers
only what changed and why.

This round adds a SECOND upstream touchpoint for this stage, `.gitignore` — recorded as
section 9 below and in appendix A3, taking the stage from one upstream touch to two. It is
called out here rather than left to the appendix because an inventory that undercounts itself
is the exact defect the inventory exists to prevent.

### 1. The defect: a `@ModelActor` conformance IS the leak

The previous round checked whether `actor.modelContext` (the convenience property in
`extension ModelActor`) was `nonisolated`, read the SDK's `.swiftinterface` to confirm it is
not, and proved with a compile error that the property could not be reached. All of that was
correct — and it missed the door next to the one it was watching. `ModelActor` has two
requirements of its own:

```swift
public protocol ModelActor : _Concurrency.Actor {
  nonisolated var modelContainer: SwiftData.ModelContainer { get }
  nonisolated var modelExecutor: any SwiftData.ModelExecutor { get }
}
public protocol ModelExecutor : _Concurrency.Executor {
  var modelContext: SwiftData.ModelContext { get }
}
```
(`MacOSX26.5.sdk/System/Library/Frameworks/SwiftData.framework/.../arm64e-apple-macos.swiftinterface`,
lines 120-128.)

`modelExecutor` is `nonisolated` and public; `ModelExecutor.modelContext` is public and, on a
non-actor conformer such as `DefaultSerialModelExecutor`, plainly non-isolated. So any caller
can obtain the actor's exact live `ModelContext` synchronously, fetch managed objects from it,
and mutate them off the actor's executor:

```swift
func attack<A: ModelActor>(_ actor: A) {
    let context = actor.modelExecutor.modelContext
    context.autosaveEnabled = false
}
```

Note it is generic over `any ModelActor`, so it does not even name the conforming type. Hiding,
renaming or documenting the type would have done nothing. **The conformance itself is the
public surface**, and no amount of care applied to the members we wrote could have closed it.

### 2. The fix: own the executor, conform to nothing, and hand back a receipt

`MeetingSegmentPersistenceActor.swift` → `MeetingStore.swift`. Three types, one file:

- `MeetingStore` — a **`struct`**, the only thing anything outside the file can name. Its
  methods are all `async`, and take/return `MeetingHandle`/`MeetingSegmentHandle`.
- `MeetingHandle` / `MeetingSegmentHandle` — `Sendable` value receipts wrapping a
  `PersistentIdentifier` in a `fileprivate` field.
- `MeetingPersistenceEngine` — a **`private`** actor that owns the `ModelContext`, and
  **conforms to nothing**.

The engine is not a `@ModelActor`. That macro's whole substantive output is three lines of
`init` plus the `ModelActor` conformance, and the conformance is the defect, so the file writes
the three lines itself:

```swift
private actor MeetingPersistenceEngine {
    private let executor: DefaultSerialModelExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private var modelContext: ModelContext { executor.modelContext }

    init(modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        executor = DefaultSerialModelExecutor(modelContext: context)
    }
}
```

This is behaviourally identical to `@ModelActor` — a context created from the container, bound
to a `DefaultSerialModelExecutor` that is also the actor's own executor — minus the two things
the conformance adds: the `modelExecutor` requirement (the leak) and the `self[id, as:]`
subscript (the landmine recorded in the previous entry, which returns a non-nil INVALID object
for a foreign identifier). Losing both is the point, not a side effect.

This is the inversion the project has learned to reach for. The old design accepted "the caller
will only use the identifier API" and tried to defend that claim against attack. The new one
removes the alternative: there is no `ModelActor` conformance to reach through, no engine type
to name, and no context-shaped value in the API at all — only receipts the store issues after
doing the work itself.

### 3. The property guaranteed, stated exactly

> **G.** The `ModelContext` this component mutates, and every managed `Meeting`/`MeetingSegment`
> registered in it, are unreachable from any code outside `MeetingStore.swift`, using the
> language's checked features. Every mutation of a meeting's persisted graph therefore happens
> on one serial executor, in call order, with one explicit `save()` per mutation.

Scope, stated so it is not over-read: **G** is about *this component's* context. Anyone holding
the `ModelContainer` can still make their own `ModelContext` over the same rows — that is
SwiftData's supported model, contexts are independent and conflicts resolve at save. What **G**
rules out is a second isolation domain mutating the objects *this* executor owns, which is a
data race on non-`Sendable` reference types rather than an ordinary write conflict.

Four mechanisms enforce it, each closing a route the previous designs left open:

1. **No `ModelActor` conformance** on the exposed type or the engine (§1, §2).
2. **The engine type is `private` at file scope**, so it cannot be named, extended, or
   instantiated elsewhere.
3. **`MeetingStore` is a `struct`.** `ModelActor` refines `Actor`, which only a class or actor
   can conform to, so the conformance cannot be added back retroactively. The choice of `struct`
   is load-bearing.
4. **The engine is a closure capture, never a stored property**, because `Mirror` needs no
   access and no compiler permission (§5).

### 4. Attack transcript (full `xcodebuild`, verbatim)

Attacks live in `scripts/negative-controls/`, permanently, and are run by
`scripts/verify-meeting-store-isolation.sh`, which stages each into the **app target** (not the
test target: `private`/`fileprivate` are file-scoped, so same-module code is the realistic
attacker, and the MeetingEngine will live in that module), builds with a full `xcodebuild`, and
fails if the build SUCCEEDS **or if any expected diagnostic goes missing** — a control that
quietly stops firing still leaves a red build and would otherwise read as green. Wired into CI
after the test step.

Run: `scripts/verify-meeting-store-isolation.sh --derived-data .ci-test-build`, Xcode 26.6
(17F113), macOS 15 deployment target, Swift 5 language mode. Every diagnostic below is a hard
language error, not a strict-concurrency diagnostic, so none of them depends on a build setting
that could be turned down later. Exit 0 (all controls failed to compile, for the expected
reasons). `__NegativeControl.swift` is the staged copy of the attack file.

```
==> MeetingStoreIsolationAttacks.swift
  --- compiler diagnostics ---
    __NegativeControl.swift:40:5: error: global function 'a1_genericModelExecutorEscape' requires that 'MeetingStore' conform to 'ModelActor'
    __NegativeControl.swift:44:33: error: 'MeetingPersistenceEngine' is inaccessible due to 'private' protection level
    __NegativeControl.swift:48:15: error: 'dispatch' is inaccessible due to 'private' protection level
    __NegativeControl.swift:53:53: error: 'persistentID' is inaccessible due to 'fileprivate' protection level
    __NegativeControl.swift:58:9: error: 'async' call in a function that does not support concurrency
    __NegativeControl.swift:65:34: error: cannot convert value of type 'Meeting' to expected argument type 'MeetingHandle'
    __NegativeControl.swift:71:44: error: cannot convert value of type 'M' to expected argument type 'MeetingHandle'
    __NegativeControl.swift:76:5: error: 'MeetingHandle' initializer is inaccessible due to 'fileprivate' protection level
    __NegativeControl.swift:82:23: error: instance method 'decode(_:from:)' requires that 'MeetingHandle' conform to 'Decodable'
    __NegativeControl.swift:88:17: error: incorrect argument label in call (have 'modelContext:', expected 'modelContainer:')
    __NegativeControl.swift:88:32: error: cannot convert value of type 'ModelContext' to expected argument type 'ModelContainer'
    __NegativeControl.swift:92:13: error: inheritance from non-protocol, non-class type 'MeetingStore'
    __NegativeControl.swift:97:11: error: value of type 'MeetingStore' has no member 'modelContainer'
    __NegativeControl.swift:103:5: error: 'dispatch' is inaccessible due to 'private' protection level
    __NegativeControl.swift:108:11: error: value of type 'MeetingStore' has no member 'modelContext'
  --- end diagnostics ---
==> MeetingStoreRetroactiveConformanceAttack.swift
  --- compiler diagnostics ---
    __NegativeControl.swift:16:1: error: non-class type 'MeetingStore' cannot conform to class protocol 'Actor'
    __NegativeControl.swift:16:1: error: non-class type 'MeetingStore' cannot conform to class protocol 'ModelActor'
  --- end diagnostics ---
All MeetingStore negative controls still fail to compile, for the expected reasons.
```

Attack by attack, in the order they appear in the file:

| # | Attack | Line | Outcome |
|---|---|---|---|
| A1 | The reviewer's exact attack, generalised: `func attack<A: ModelActor>` reading `actor.modelExecutor.modelContext`, applied to `MeetingStore` | 40 | **blocked** — no `ModelActor` conformance to bite on. The generic function itself still compiles; there is simply no value of ours it accepts. |
| A2 | Name the engine actor directly | 44 | **blocked** — `private` at file scope |
| A3 | Read the private dispatch table (member reference) | 48 | **blocked** — `private` |
| A4 | Add the `ModelActor` conformance back retroactively | 16 (own file) | **blocked** — a `struct` cannot conform to `Actor` |
| A5 | Extension unwrapping a handle into a `PersistentIdentifier` | 53 | **blocked** — `fileprivate` payload |
| A6 | Call the store synchronously, no `await` | 58 | **blocked** — every method is `async` |
| A7 | Pass a managed `Meeting` across the boundary | 65 | **blocked** — no overload accepts one |
| A8 | The same, laundered through `<M: PersistentModel>` so no model type is named | 71 | **blocked** — same |
| A9 | Forge a handle from an identifier obtained elsewhere | 76 | **blocked** — `fileprivate` init |
| A10 | Reconstruct a handle via `Codable` (`PersistentIdentifier` is `Codable`; the handle is deliberately not) | 82 | **blocked** — not `Decodable` |
| A11 | Hand the store a `ModelContext` somebody else owns | 88 | **blocked** — it only takes a `ModelContainer` |
| A12 | Subclass to override or expose internals | 92 | **blocked** — `MeetingStore` is a struct |
| A13 | Read the container back off the store (`@ModelActor` exposes this `nonisolated`) | 97 | **blocked** — no such member |
| A14 | Key-path route to the dispatch table (a different access mechanism from A3) | 103 | **blocked** — `private` |
| A15 | Read `store.modelContext` by any name it might expose | 108 | **blocked** — no such member |
| A16 | `Mirror` recursion from a live store to its context | — | **COMPILES.** Closed by construction, not by the type system: the engine is a closure capture, so the walk terminates at six function values. Proved at runtime by `MeetingStoreIsolationTests`. |
| A17 | `unsafeBitCast` / raw-memory forgery | — | **COMPILES, and is a disclosed residual hole.** Outside **G** by definition; see FOLLOWUPS.md. |
| A18 | `Mirror` on a `MeetingHandle` to recover its `PersistentIdentifier` | — | **COMPILES, and is a disclosed residual hole.** Recovers no authority over this store's context; asserted by a test so the disclosure cannot go stale. See FOLLOWUPS.md. |

### 5. The one attack that still compiles, and what closes it: `Mirror`

`Mirror(reflecting:)` walks a value's stored properties regardless of `private`, needs no
`@testable`, and cannot be refused. If `MeetingStore` held `private let engine: ...`, then

```swift
Mirror(reflecting: store).children.first!.value          // the engine, as Any
```

hands it over — and from there `as? DefaultSerialModelExecutor` (a **public** class with a
public `modelContext`) recovers the live context at runtime, with no compiler involvement at
all. Access control is a compile-time construct; reflection is not.

So the store holds no engine property. It holds `EngineDispatch`, a struct of six `@Sendable`
closures, each capturing the engine. `Mirror` reports no children for a closure and there is no
API that reads a closure's captures, so the walk terminates at six function values.

Proved at runtime, not asserted: `MeetingStoreIsolationTests.swift` does a bounded
breadth-first `Mirror` walk from a live `MeetingStore` (depth 8, 10k nodes) and fails if any
reachable value is a `ModelContext`, a `ModelExecutor`, a `ModelActor` or a `PersistentModel` —
once on a fresh store, and again after it has written a meeting and a segment, because
`startMeeting` is what causes the context to register managed objects. A third test pins the
mechanism rather than its effect: every leaf reachable from the store must be a closure, so
reintroducing a plain stored property fails immediately and by name.

### 6. Autosave is now OFF, which is what makes the durability test mean anything

`MeetingPersistenceEngine.init` sets `context.autosaveEnabled = false`.

The durability test added in the previous round reads as if it pins the "one explicit `save()`
per mutation" contract. It did not. With autosave left on, SwiftData flushes pending changes on
its own, so deleting every `try modelContext.save()` from the store would have left the test
green: it was asserting durability the store was not responsible for.

Proved by doing it. With autosave off, removing the `save()` from `appendSegment`:

```
MeetingStoreDurabilityTests.swift:118: Expectation failed: (reread.segments.count → 0) == 5
MeetingStoreDurabilityTests.swift:123: Expectation failed: (ordered.map(\.text) → []) == (expectedTexts → ["minute 0 update", "minute 60 update", "minute 120 update", "minute 180 update", "minute 240 update"])
** TEST FAILED **
Failing tests:
	MeetingStoreDurabilityTests.survivesContainerTeardown()
```

Zero of the five segments survived the teardown — which is the correct answer for a store that
never saved them, and was NOT the answer this test gave before autosave was turned off.

Restored, the suite is green again. The check now fails closed: an edit that drops an explicit
save cannot reach `main`.

Turning autosave off is also correct on its own terms. This component's contract is that each
finalized segment is durable by the time its call returns; an autosave timer firing at moments
nothing here chose is at best redundant and at worst hides a missing save.

### 7. Test changes

- `MeetingSegmentPersistenceActorTests.swift` → `MeetingStoreTests.swift`; likewise the
  durability file. New `MeetingStoreIsolationTests.swift` (§5).
- **All `ModelContext.model(for:)` calls removed from the test helpers**, flagged non-blocking
  by review and worth doing: that API fatal-errors the process for an identifier the receiving
  context has not registered, which is precisely the situation a "read it back through a
  separate context" helper creates. Every lookup is now a `FetchDescriptor`, which is also the
  more honest way to ask whether something reached the store.
- The tests no longer unwrap identifiers, because they cannot: `MeetingHandle`'s payload is
  `fileprivate`, and the test target gets no more access than production code does. Read-backs
  fetch by content instead. `foreignHandleThrows` (was `unknownIdentifierThrows`) still passes a
  handle from a genuinely different container, so the `registeredModel`-then-fetch lookup
  recorded in the previous entry stays exercised against a foreign identifier.

### 8. Methodology note: an attack file can defeat its own attacks

Worth recording, because it nearly produced a false all-clear in this very round. All fifteen
attacks started in one file. Two of them — A1 (the generic `modelExecutor` escape, i.e. the
reviewer's exact attack) and A15 (`store.modelContext`) — compiled **clean**, and a careless
reading would have reported "no error" for the single most important attack in the set.

The cause was A4, `extension MeetingStore: ModelActor {}`, sitting a few lines below them. Swift
records a retroactive conformance for the rest of the file even when the conformance itself is
an error, so A4 handed A1 and A15 the very conformance they were probing for. A4 now lives
alone in `MeetingStoreRetroactiveConformanceAttack.swift`, and both files say why.

The general rule, now that it has cost something: **one conformance-mutating attack per file**,
and treat "attack produced no error" as a result to be explained, never as a result to be
reported.

### 9. UPSTREAM TOUCHPOINT: `.gitignore` (five appended lines)

**This is the second upstream-owned file this stage edits, and the first one added since the
stage began.** Recorded here as a numbered entry, not left to the appendix, because the whole
purpose of the touchpoint ledger is defeated by a touchpoint that appears only in a total.

```
+# Derived-data paths used by CI's test step and by
+# scripts/verify-meeting-store-isolation.sh (which reuses the former when given
+# --derived-data, so the negative controls stay a one-file incremental compile).
+.ci-test-build/
+.negative-control-build/
```

`.gitignore` exists upstream (`git cat-file -e upstream/main:.gitignore` succeeds) and was
byte-identical to upstream until this change — `git diff upstream/main <previous commit> --
.gitignore` was empty — so this is a genuinely new divergence that the fork now owns forever,
not an extension of an existing one.

**Why it is worth that cost.** `.ci-test-build/` is the derived-data path CI's own test step
already uses; `.negative-control-build/` is this round's verifier default. Neither was ignored,
so both showed up as untracked directories in every `git status` and were one careless
`git add -A` away from committing hundreds of megabytes of build scratch. The alternative — leaving them unignored and relying on discipline — is the same
"documented rather than enforced" pattern this entire stage exists to stamp out.

**Why the merge cost is close to zero.** Five lines appended to the end of an existing list, in
a file upstream changes rarely and only by appending. That is about the lowest-conflict shape an
upstream edit can take. It is still a real touchpoint and is counted as one.

Appendix A3 and the appendix totals are updated to match.

### 10. `.github/workflows/ci.yml` is NOT an upstream touchpoint (correcting a review finding)

The review of this round flagged the new negative-control CI step as an unauthorised upstream
edit. **That premise is wrong, and the correction is recorded here so the ledger does not carry
it.** Checked, not assumed:

```
$ git ls-tree -r upstream/main -- .github/
100644 blob fb5a4517  .github/ISSUE_TEMPLATE/bug_report.md
100644 blob 130c8d50  .github/ISSUE_TEMPLATE/feature_request.md
100644 blob faca8729  .github/PULL_REQUEST_TEMPLATE.md

$ git cat-file -e upstream/main:.github/workflows/ci.yml
fatal: path '.github/workflows/ci.yml' exists on disk, but not in 'upstream/main'

$ git log --oneline --diff-filter=A -- .github/workflows/ci.yml
8db09790 Phase 0: fork hygiene, delicense, unsigned CI
```

Upstream's `.github/` holds issue and PR templates only. There is no workflow directory and no
`ci.yml`; this fork created it in Phase 0. It is fork-owned, like `FORK-PATCHES.md`,
`FOLLOWUPS.md` and `package-trust.json` — appendix A5 has listed it as such since Phase 0 — and
editing it carries no merge burden, because upstream has no such file to conflict with. The
negative-control step stays.

### 11. Hardening: negative-control expectations are line-anchored, not string-matched

A3 (`_ = store.dispatch`) and A14 (`\MeetingStore.dispatch`) produce the *identical* diagnostic,
`'dispatch' is inaccessible due to 'private' protection level`. The verifier's expectations were
a flat list of message strings, so **either attack could have started compiling while the other
kept supplying the text, and the run would have stayed green while silently testing one attack
instead of two.** Same failure class as §8 — the apparatus quietly stops testing something and
keeps reporting success — one notch smaller, and caught by review rather than by the apparatus,
which is itself the point.

Fixed by binding every expectation to a LINE rather than to a string. Each attack now carries a
`// expect-error: <text>` comment on the line directly above the line the compiler must reject;
the verifier parses those out of the attack source, so the expectation and the attack cannot
drift apart. It now asserts four things, and fails on any of them:

1. the build failed;
2. every marker has its diagnostic **on the exact line the marker sits above**;
3. every diagnostic emitted lands on a marked line, so a new error cannot stand in for a
   missing expected one;
4. the marker COUNT per file matches, so deleting an attack outright is caught too.

**Demonstrated, not asserted.** `_ = store.dispatch` was temporarily changed to `_ = store`
(compiles) and the verifier re-run:

```
    ok  line 65: 'MeetingPersistenceEngine' is inaccessible due to 'private' protection level
    MISSING at line 70: 'dispatch' is inaccessible due to 'private' protection level
    ok  line 76: 'persistentID' is inaccessible due to 'fileprivate' protection level
    ...
    ok  line 133: 'dispatch' is inaccessible due to 'private' protection level
error: MeetingStoreIsolationAttacks.swift failed to build, but not for exactly the reasons it is supposed to.
       An attack that stops firing still leaves a red build, so this would otherwise
       pass unnoticed.
```

Exit 1. Note line 133 in that same output: A14 is still happily producing the exact string the
OLD check looked for, which is precisely why the old check would have passed this tree. The
string appears three times in the failing run's log; the line does not. A3 was restored and the
verifier re-run green.

### Verification

Local, Xcode 26.6 (17F113):

- Full `xcodebuild test` (CI's exact invocation, `-destination 'platform=macOS'`, parallel):
  green except `RouteAwareMeetingMicRecorderTests.liveRouteChangeWaitsForFirstBuffer()`, which
  lives in `Features/Meetings/Capture/`, is untouched by this change, and is the same
  pre-existing flake the previous round hit and re-ran clean. All 15 tests across the three
  MeetingStore suites pass.
- `scripts/verify-meeting-store-isolation.sh --derived-data .ci-test-build`: exit 0, all 15
  markers matched on their exact lines, no unattributed diagnostics (section 11). Its own
  failure path demonstrated by neutering A3: exit 1, quoted in section 11.
- Autosave proof above: save removed -> red, save restored -> green.
- `scripts/verify-package-trust.sh` unchanged and passing; no new dependency (the fail-closed
  supply-chain guard is untouched).
- Upstream touchpoints for this stage: TWO. `VoiceInk/App/VoiceInk.swift` (appendix A2,
  unchanged this round) and `.gitignore` (appendix A3, section 9 below). `.github/workflows/ci.yml`
  is NOT one -- it is fork-owned; see section 10. Zero PRs against `Beingpax/VoiceInk`.

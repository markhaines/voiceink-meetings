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

Totals: 60 identity-only edits, 15 behavioural edits, 7 build/project changes, 17 deletions, 8 new fork-only files (107 paths).

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

### A3. Build and project configuration (7 files)

- `Makefile` -- added `LOCAL_XCODEBUILD_FLAGS ?=` for CI, and pinned the whisper.cpp checkout to `whisper-cpp.rev` instead of `git pull`ing upstream HEAD
- `README.md` -- fork header, build instructions, upstream attribution
- `VoiceInk.xcodeproj/project.pbxproj` -- bundle identifiers for app/XPC/tests/UI-tests, `DEVELOPMENT_TEAM` emptied, iCloud entitlement removals, and the `MLXHuggingFace` package product dependency dropped
- `VoiceInk/Info.plist` -- `SUFeedURL` and `SUPublicEDKey` removed, automatic update checks disabled
- `VoiceInk/VoiceInk.debug.entitlements` -- same, for the debug configuration
- `VoiceInk/VoiceInk.entitlements` -- iCloud/CloudKit container entitlements removed
- `scripts/release.sh` -- notarisation/signing identifiers pointed at the fork

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

### A5. New fork-only files (8 files)

- `.github/workflows/ci.yml` -- the CI pipeline (section 6)
- `FORK-PATCHES.md` -- this file
- `NOTICE` -- upstream attribution and licence notice
- `VoiceInkRefineXPC/HuggingFaceTokenizerLoader.swift` -- the fork's own copy of the `#huggingFaceTokenizerLoader()` expansion, which is what removes mlx-swift-lm's macro from the build graph (section 6)
- `package-trust.json` -- the reviewed build-time input: the whole pinned package graph (every pin's location, revision, root tree and manifest blob ids, plus sha256 of `Package.resolved`), and the reviewed macro/build-tool plugin components with their source-tree hashes (section 6)
- `scripts/assert-fork-identity.sh` -- the fork-identity guard, run against the built app and the project configuration (section 6)
- `scripts/verify-package-trust.sh` -- enforces `package-trust.json` before anything is built (section 6)
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
below. Full narrative detail (every donor use-site read, exact commands run for each gate) is
additionally in the task report at `.tandem/884f6ef6905c4e2aa4e2ca28c34ea629/phase1-foundation.md`,
but that path is orchestration state, not part of this repository, so nothing above depends on
it being reachable. This entry covers the one upstream-file touch, against the ~6-touchpoint
budget the note below sets for Phase 1+.

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

## Architecture budget note

The instruction for this project caps ongoing upstream touchpoints (outside the new
`Features/Meetings/` slice) at roughly 6. That budget is for Phase 1+ feature work layered on
top of a clean base — it does not describe Phase 0 itself, whose entire job is editing
upstream-owned files (identity, signing, Sparkle, delicensing) exactly once, up front, so later
phases don't have to. This entry is long because Phase 0 is supposed to be long; Phase 1 onward
should look nothing like this.

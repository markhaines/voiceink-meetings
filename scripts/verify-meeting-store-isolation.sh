#!/bin/bash
# Runs the structural negative controls: source files that MUST NOT COMPILE.
#
# Two boundaries are defended this way. `MeetingStore`'s isolation guarantee (below), and --
# added in the meeting-transcription-coordinator fix round 3 --
# `FluidAudioSharedModelAttacks.swift`, which asserts that no code in the app module can reach
# the methods on `FluidAudioTranscriptionService` that evict dictation's loaded Parakeet model.
# Same reasoning in both cases: a guarantee that is merely documented gets defeated in one line.
#
# `MeetingStore` claims a structural guarantee (see its doc comment): no code outside
# MeetingStore.swift can reach the ModelContext it mutates, the objects registered in it, or the
# actor that owns them. Two earlier designs of that boundary were each hand-verified as correct
# and then defeated in one line by review, so the claim is not left as prose. Every attack that
# was tried against it lives in scripts/negative-controls/ and is compiled here.
#
# The attack files are compiled INTO THE APP TARGET, not the test target: `private` and
# `fileprivate` are file-scoped, so same-module code is the realistic attacker, and the
# MeetingEngine that will drive this store will live in that very module.
#
# # What "green" means here, and the three ways this fails
#
# A control that stops firing still leaves a red build, so "the build failed" proves nothing on
# its own. This script therefore asserts all three of:
#
#   1. the build FAILED;
#   2. EVERY `// expect-error:` marker in the attack source has its diagnostic, on the exact
#      line the marker sits above -- so an attack that starts compiling is caught individually,
#      even when a DIFFERENT attack produces identical diagnostic text (A3 and A14 do; that
#      collision is why expectations are line-anchored rather than matched as a flat list of
#      strings, and it is the same "apparatus silently stops testing something" failure that
#      A4 caused once already, one notch smaller);
#   3. every diagnostic the compiler emitted lands on a marked line -- so a NEW kind of error
#      cannot stand in for a missing expected one;
#
# plus a marker COUNT per file, so deleting an attack outright is caught too.
#
# Usage: scripts/verify-meeting-store-isolation.sh [--derived-data PATH]
# Pass an existing derived-data path (e.g. the one CI already built into) to keep this
# incremental; with a cold path it does a full build of the app target first.

set -euo pipefail

cd "$(dirname "$0")/.."
repo_root="$(pwd)"

derived_data=".negative-control-build"
while [ $# -gt 0 ]; do
  case "$1" in
    --derived-data) derived_data="$2"; shift 2 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# Where the attack file is dropped so the app target picks it up. VoiceInk/ is a
# PBXFileSystemSynchronizedRootGroup, so any .swift under it is compiled with no project edit.
staged="$repo_root/VoiceInk/Features/Meetings/Models/__NegativeControl.swift"
log_dir="$(mktemp -d)"

cleanup() {
  rm -f "$staged"
  rm -rf "$log_dir"
}
trap cleanup EXIT INT TERM

if [ -e "$staged" ]; then
  echo "error: $staged already exists; refusing to overwrite it" >&2
  exit 2
fi

# A marker is a comment line of exactly the form `// expect-error: <text>`; the diagnostic it
# names must appear on the NEXT line. Prose that merely mentions the convention does not match,
# because the marker must start the comment.
marker_regex='^[[:space:]]*// expect-error: '

run_case() {
  local attack_file="$1"
  local expected_markers="$2"

  local src="$repo_root/scripts/negative-controls/$attack_file"
  echo "==> $attack_file"

  local marker_count
  marker_count="$(grep -cE "$marker_regex" "$src" || true)"
  if [ "$marker_count" -ne "$expected_markers" ]; then
    echo "error: $attack_file has $marker_count expect-error markers, expected $expected_markers." >&2
    echo "       An attack was added or removed without updating this script. If that was" >&2
    echo "       deliberate, update the count here and say why in FORK-PATCHES.md; coverage" >&2
    echo "       shrinking silently is the whole thing this check exists to prevent." >&2
    exit 1
  fi

  cp "$src" "$staged"

  local log="$log_dir/$attack_file.log"
  set +e
  xcodebuild build \
    -project VoiceInk.xcodeproj \
    -scheme VoiceInk \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    -xcconfig LocalBuild.xcconfig \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" \
    CODE_SIGN_ENTITLEMENTS="$repo_root/VoiceInk/VoiceInk.local.entitlements" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
    -skipPackagePluginValidation \
    -onlyUsePackageVersionsFromResolvedFile \
    >"$log" 2>&1
  local status=$?
  set -e

  rm -f "$staged"

  if [ $status -eq 0 ]; then
    echo "error: $attack_file COMPILED. The MeetingStore isolation boundary is defeated." >&2
    echo "       Every attack in that file is supposed to be a compile error; read it and" >&2
    echo "       fix the boundary (or, if the attack is genuinely no longer meaningful," >&2
    echo "       delete it and say why in FORK-PATCHES.md)." >&2
    exit 1
  fi

  # Every diagnostic against the staged file, normalised to `<line>:<col>: error: <message>`.
  local diagnostics="$log_dir/$attack_file.diagnostics"
  grep -oE "__NegativeControl\.swift:[0-9]+:[0-9]+: error: .*" "$log" \
    | sed 's|^__NegativeControl\.swift:||' \
    | sort -u > "$diagnostics"

  # Echoed in full, always. These are the evidence the boundary still holds, and a run that
  # only prints "ok" is a run whose output you have to take on trust; FORK-PATCHES.md quotes
  # this verbatim.
  echo "  --- compiler diagnostics ---"
  sed 's|^|    __NegativeControl.swift:|' "$diagnostics"
  echo "  --- end diagnostics ---"

  local failures=0

  # (2) Every marker's diagnostic is present, on the line the marker sits above.
  local marked_lines="$log_dir/$attack_file.marked-lines"
  : > "$marked_lines"
  local marker_line message target
  while IFS= read -r entry; do
    marker_line="${entry%%:*}"
    message="${entry#*// expect-error: }"
    target=$((marker_line + 1))
    echo "$target" >> "$marked_lines"
    if grep -qF -- "$message" <(grep -E "^$target:[0-9]+: error: " "$diagnostics"); then
      echo "    ok  line $target: $message"
    else
      echo "    MISSING at line $target: $message" >&2
      failures=1
    fi
  done < <(grep -nE "$marker_regex" "$src")

  # (3) No diagnostic lands anywhere but a marked line. Stops a new error masking a missing one.
  local stray
  stray="$(cut -d: -f1 "$diagnostics" | sort -u | grep -vxFf <(sort -u "$marked_lines") || true)"
  if [ -n "$stray" ]; then
    echo "    UNATTRIBUTED diagnostics on unmarked line(s): $(echo "$stray" | tr '\n' ' ')" >&2
    failures=1
  fi

  if [ $failures -ne 0 ]; then
    echo "error: $attack_file failed to build, but not for exactly the reasons it is supposed to." >&2
    echo "       An attack that stops firing still leaves a red build, so this would otherwise" >&2
    echo "       pass unnoticed. Compare the diagnostics above against the markers in $src." >&2
    exit 1
  fi
}

run_case MeetingStoreIsolationAttacks.swift 14
run_case MeetingStoreRetroactiveConformanceAttack.swift 1
run_case FluidAudioSharedModelAttacks.swift 5

echo "All negative controls still fail to compile, for the expected reasons,"
echo "each on the exact line its marker names, with no unattributed diagnostics."

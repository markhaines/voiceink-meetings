#!/bin/bash
# Runs the MeetingStore negative controls: source files that MUST NOT COMPILE.
#
# `MeetingStore` claims a structural guarantee (see its doc comment): no code outside
# MeetingStore.swift can reach the ModelContext it mutates, the objects registered in it, or the
# actor that owns them. Two earlier designs of that boundary were each hand-verified as correct
# and then defeated in one line by review, so the claim is not left as prose. Every attack that
# was tried against it lives in scripts/negative-controls/ and is compiled here; this script
# fails if the build SUCCEEDS, or if any expected diagnostic goes missing.
#
# The second half matters as much as the first. An attack that stops producing its error because
# the code drifted -- a `private` that became `internal`, a conformance that came back -- would
# otherwise still leave the build failing for some unrelated reason and read as green.
#
# The attack files are compiled INTO THE APP TARGET, not the test target: `private` and
# `fileprivate` are file-scoped, so same-module code is the realistic attacker, and the
# MeetingEngine that will drive this store will live in that very module.
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

# One case per attack file. Expected diagnostics are the exact compiler message text (the
# leading path/line is stripped before matching, since it moves whenever the file is edited).
#
# MeetingStoreIsolationAttacks.swift deliberately excludes the retroactive-conformance attack:
# a retroactive conformance is recorded for the whole file even when the conformance itself is
# an error, and while it lived there it silently made A1 and A15 compile CLEAN. See that file's
# header.
run_case() {
  local attack_file="$1"; shift
  local -a expected=("$@")

  echo "==> $attack_file"
  cp "$repo_root/scripts/negative-controls/$attack_file" "$staged"

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

  # Echoed in full, always. These are the evidence the boundary still holds, and a run that
  # only prints "ok" is a run whose output you have to take on trust; FORK-PATCHES.md quotes
  # this verbatim.
  echo "  --- compiler diagnostics ---"
  grep -E "error:" "$log" | sed -e 's|^.*/__NegativeControl.swift|__NegativeControl.swift|' | sort -u | sed 's/^/    /'
  echo "  --- end diagnostics ---"

  local missing=0
  local message
  for message in "${expected[@]}"; do
    if grep -Fq "$message" "$log"; then
      echo "    ok: $message"
    else
      echo "    MISSING: $message" >&2
      missing=1
    fi
  done

  if [ $missing -ne 0 ]; then
    echo "error: $attack_file failed to build, but not for the reasons it is supposed to." >&2
    echo "       A control that stops firing still leaves a red build, so this would" >&2
    echo "       otherwise pass unnoticed. Full log:" >&2
    grep -E "error:" "$log" >&2 || true
    exit 1
  fi
}

run_case MeetingStoreIsolationAttacks.swift \
  "global function 'a1_genericModelExecutorEscape' requires that 'MeetingStore' conform to 'ModelActor'" \
  "'MeetingPersistenceEngine' is inaccessible due to 'private' protection level" \
  "'dispatch' is inaccessible due to 'private' protection level" \
  "'persistentID' is inaccessible due to 'fileprivate' protection level" \
  "'async' call in a function that does not support concurrency" \
  "cannot convert value of type 'Meeting' to expected argument type 'MeetingHandle'" \
  "cannot convert value of type 'M' to expected argument type 'MeetingHandle'" \
  "'MeetingHandle' initializer is inaccessible due to 'fileprivate' protection level" \
  "requires that 'MeetingHandle' conform to 'Decodable'" \
  "incorrect argument label in call (have 'modelContext:', expected 'modelContainer:')" \
  "inheritance from non-protocol, non-class type 'MeetingStore'" \
  "value of type 'MeetingStore' has no member 'modelContainer'" \
  "value of type 'MeetingStore' has no member 'modelContext'"

run_case MeetingStoreRetroactiveConformanceAttack.swift \
  "non-class type 'MeetingStore' cannot conform to class protocol 'ModelActor'" \
  "non-class type 'MeetingStore' cannot conform to class protocol 'Actor'"

echo "All MeetingStore negative controls still fail to compile, for the expected reasons."

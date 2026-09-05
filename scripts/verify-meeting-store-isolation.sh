#!/bin/bash
# Runs the structural negative controls: source files that MUST NOT COMPILE.
#
# Two boundaries are defended this way. `MeetingStore`'s isolation guarantee (below), and --
# added in the meeting-transcription-coordinator fix round 3 --
# the `FluidAudioService*`/`MeetingCapability*`/`MeetingSeam*`/`MeetingDiarizer*` attack files,
# which assert that the meeting transcription seam cannot reach the methods that evict dictation's
# loaded Parakeet model. Same reasoning in both cases: a guarantee that is merely documented gets
# defeated in one line.
#
# Round 5 split those from one bundled file into ONE MECHANISM PER FILE. The bundled version
# passed while the boundary was defeated, because the list did not contain a downcast; separate
# files mean each mechanism is compiled alone and cannot borrow another's diagnostics or
# conformances.
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
marker_regex='^[[:space:]]*// expect-(error|warning): '
# Kept separate so a case can demand one kind and reject the other.
error_marker_regex='^[[:space:]]*// expect-error: '
warning_marker_regex='^[[:space:]]*// expect-warning: '

# run_case <attack-file> <expected-marker-count> <mode>
#
# mode=must-not-compile : the build MUST fail, and every `// expect-error:` marker must have its
#                         diagnostic on the line below it.
# mode=must-warn        : the build is EXPECTED TO SUCCEED, and every `// expect-warning:` marker
#                         must have its diagnostic on the line below it. This mode exists because
#                         a downcast between unrelated concrete types is not an error in Swift --
#                         it is a statically-proven-impossible cast, and the compiler says so.
#                         The attack therefore COMPILES; what the control asserts is that the
#                         compiler still proves it can never succeed. If the boundary regressed to
#                         something the cast COULD succeed against, the diagnostic would vanish
#                         and rule (2) below fails on the missing expectation. Stated plainly
#                         because it is the one place in this suite where "the attack compiled" is
#                         not by itself a failure: see the file headers for why, and the round-5
#                         report for the disclosure.
run_case() {
  local attack_file="$1"
  local expected_markers="$2"
  local mode="${3:-must-not-compile}"

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

  # A case must use its own marker kind exclusively: an `expect-error` sitting in a must-warn
  # file (or vice versa) would be silently ignored by the matcher below and would read as
  # coverage that is not actually being checked.
  local case_marker_regex="$error_marker_regex"
  local wrong_marker_regex="$warning_marker_regex"
  if [ "$mode" = "must-warn" ]; then
    case_marker_regex="$warning_marker_regex"
    wrong_marker_regex="$error_marker_regex"
  fi
  if grep -qE "$wrong_marker_regex" "$src"; then
    echo "error: $attack_file is mode '$mode' but contains markers of the other kind." >&2
    echo "       Those would never be checked. Split the file or fix the marker." >&2
    exit 1
  fi

  # Could one control's diagnostic ever stand in for another's, hiding an attack that started
  # compiling? Three separate reasons it cannot, the third of which is asserted here:
  #
  #   (a) ACROSS FILES: every file gets its own build, its own log and its own diagnostics list,
  #       so one file's output is never even visible when another's expectations are checked.
  #   (b) WITHIN A FILE, duplicate TEXT on different lines: safe, because matching is
  #       line-anchored -- each marker demands its diagnostic at `<its own line>:<col>`, not
  #       anywhere in the file. MeetingStoreIsolationAttacks.swift relies on this deliberately
  #       (A3 and A14 produce identical text; its header records that as the reason expectations
  #       are line-anchored rather than matched as a flat list of strings). Reported below as a
  #       note, not a failure -- failing it would force splitting a file the design already
  #       handles.
  #   (c) WITHIN A FILE, two markers targeting the SAME line: genuinely unsafe, because one
  #       diagnostic on that line would satisfy both expectations. Nothing in the suite does this
  #       today; it is rejected here so nothing can start.
  local dup_text dup_lines
  dup_text="$(grep -E "$case_marker_regex" "$src" | sed "s|^[[:space:]]*// expect-[a-z]*: ||" \
             | sort | uniq -d || true)"
  if [ -n "$dup_text" ]; then
    echo "  note: duplicate marker text in this file, safe because matching is line-anchored:"
    echo "$dup_text" | sed 's|^|        |'
  fi
  dup_lines="$(grep -nE "$case_marker_regex" "$src" | cut -d: -f1 \
              | awk '{print $1 + 1}' | sort | uniq -d || true)"
  if [ -n "$dup_lines" ]; then
    echo "error: $attack_file has two markers expecting diagnostics on the same line(s): $dup_lines" >&2
    echo "       A single diagnostic there would satisfy both, so one attack could start" >&2
    echo "       compiling unnoticed. Put them on separate lines or in separate files." >&2
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

  if [ "$mode" = "must-not-compile" ] && [ $status -eq 0 ]; then
    echo "error: $attack_file COMPILED. The boundary it attacks is defeated." >&2
    echo "       Every attack in that file is supposed to be a compile error; read it and" >&2
    echo "       fix the boundary (or, if the attack is genuinely no longer meaningful," >&2
    echo "       delete it and say why in FORK-PATCHES.md)." >&2
    exit 1
  fi
  if [ "$mode" = "must-warn" ] && [ $status -ne 0 ]; then
    echo "error: $attack_file failed to BUILD, but it is a must-warn case." >&2
    echo "       That is not necessarily a defeat, but this control can no longer prove what it" >&2
    echo "       claims: read the build log and either fix the file or change its mode." >&2
    exit 1
  fi

  # Every diagnostic against the staged file, normalised to `<line>:<col>: error: <message>`.
  local kind="error"
  [ "$mode" = "must-warn" ] && kind="warning"

  local diagnostics="$log_dir/$attack_file.diagnostics"
  # `|| true` is load-bearing, not defensive noise. If the file produced NO diagnostics of this
  # kind, grep exits 1, and under `set -euo pipefail` that killed the whole script here --
  # silently, before it could report the missing expectation below. In must-not-compile mode the
  # bug was unreachable (a failed build always has at least one error); in must-warn mode it hid
  # exactly the regression this suite exists to catch. Found by deliberately neutering an attack
  # and checking the verifier still failed for the RIGHT reason; it did not, until this line.
  grep -oE "__NegativeControl\.swift:[0-9]+:[0-9]+: $kind: .*" "$log" \
    | sed 's|^__NegativeControl\.swift:||' \
    | sort -u > "$diagnostics" || true

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
    # Strip the marker prefix in two steps so ONE expression handles both
    # `// expect-error: ` and `// expect-warning: `. A single `${entry#*: }` does not: the
    # line number's own colon matches first and the marker text is left carrying its prefix,
    # which makes every expectation look MISSING.
    message="${entry#*// expect-}"
    message="${message#*: }"
    target=$((marker_line + 1))
    echo "$target" >> "$marked_lines"
    if grep -qF -- "$message" <(grep -E "^$target:[0-9]+: $kind: " "$diagnostics"); then
      echo "    ok  line $target: $message"
    else
      echo "    MISSING at line $target: $message" >&2
      failures=1
    fi
  done < <(grep -nE "$case_marker_regex" "$src")

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

run_case MeetingStoreIsolationAttacks.swift 14 must-not-compile
run_case MeetingStoreRetroactiveConformanceAttack.swift 1 must-not-compile

# Round 5: one MECHANISM per file. The previous single FluidAudioSharedModelAttacks.swift bundled
# ten attacks into one build; it passed while the boundary was defeated, because the list simply
# did not contain a downcast. Splitting them means each mechanism is compiled alone, so no attack
# can borrow another's diagnostics or another's conformances.
run_case FluidAudioServicePrivateEvictionAttack.swift 5 must-not-compile
run_case MeetingCapabilityCoercionAttack.swift 1 must-not-compile
run_case MeetingCapabilityMemberLookupAttack.swift 2 must-not-compile
run_case MeetingSeamAdmissionControlRequiredAttack.swift 1 must-not-compile
run_case MeetingDiarizerSeamManagerInjectionAttack.swift 1 must-not-compile
# Round 6: FOLLOW THE RETURN VALUE. Every control above and below this block attacks a route to
# the SERVICE, and all of them passed while round 5's capability was handing out the live shared
# `AsrManager` through its own front door. These three attack what the capability RETURNS.
run_case MeetingCapabilityReturnValueEvictionAttack.swift 2 must-not-compile
run_case MeetingReceiptMutatingApiAttack.swift 5 must-not-compile
run_case MeetingSeamCannotNameAsrManagerAttack.swift 2 must-not-compile

run_case MeetingCapabilityConditionalDowncastAttack.swift 1 must-warn
run_case MeetingCapabilityForcedDowncastAttack.swift 1 must-warn
run_case MeetingCapabilityBorrowClosureDowncastAttack.swift 1 must-warn

# The message says what was actually proven. It used to say every control "fails to compile",
# which was FALSE for the three `must-warn` cases: a downcast between unrelated concrete types is
# a warning, so those controls compile ON PURPOSE and what they assert is that the compiler still
# proves the cast can never succeed. A verification apparatus that misdescribes what it proved is
# the same class of defect as a wrong comment, and this project has been bitten by that twice.
echo "All negative controls produced exactly their required diagnostic:"
echo "  - must-not-compile cases failed to build, each expected error on the line its marker names;"
echo "  - must-warn cases built successfully and emitted their expected warning (a cast the"
echo "    compiler proves always fails), which is what those controls assert;"
echo "  - no unattributed diagnostics in either mode."

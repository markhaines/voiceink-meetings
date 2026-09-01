#!/bin/bash
# assert-fork-identity.sh <path-to-.app>
# assert-fork-identity.sh --project <repo-root>
#
# Fails if this fork still carries upstream VoiceInk's identity, or has had any of it put
# back. Two modes, because the evidence lives in two places:
#
#   PRODUCT mode inspects a BUILT .app -- the thing that actually ships. Source greps miss
#   what the compiler folds into the executable: upstream's announcements URL was found
#   this way, compiled into Contents/MacOS/VoiceInk with no trace in Info.plist.
#
#   PROJECT mode inspects the repository's build configuration. The unit and UI test
#   bundles are never inside the .app, so their bundle identifiers -- and DEVELOPMENT_TEAM,
#   which is a signing setting rather than a built-product string -- can only be checked
#   here.
#
# What must hold:
#
#   1. The app's CFBundleIdentifier is this fork's, and every NESTED bundle (the XPC
#      service, plugins, embedded frameworks) is under the fork's identifier too.
#   2. Nothing anywhere in the bundle references upstream's host. If it did, the fork could
#      auto-update itself into upstream's build -- silently replacing the de-licensed,
#      re-signed fork with the original app -- or pull remote content upstream controls.
#      Both existed here: the Sparkle feed in Info.plist, and AnnouncementsService's remote
#      config fetch (now removed).
#   3. Upstream's Sparkle public EdDSA key is absent. That key is what decides which
#      updates the app will accept as authentic; it belongs to upstream's signing key, so
#      its return would mean upstream can hand this fork an update it trusts.
#   4. Upstream's Apple Developer team id is absent from the product AND from the project.
#      Reintroducing it points the fork's signing and provisioning back at upstream.
#   5. No upstream bundle identifier survives anywhere, product or project.
#
# The feed/host check is deliberately a HOST-level substring match, not an exact-URL match:
# a near-miss such as ".../VoiceInk/appcast-v2.xml" on the same host is just as dangerous,
# and an exact comparison would wave it through.
#
# Env (all required): EXPECTED_BUNDLE_ID, FORBIDDEN_UPSTREAM_HOST,
# FORBIDDEN_UPSTREAM_BUNDLE_PREFIX, FORBIDDEN_UPSTREAM_TEAM_ID, FORBIDDEN_UPSTREAM_ED_KEY.
#
# Exits 0 when clean, 1 otherwise. CI runs this against the real build AND against
# fabricated negative controls, so the assertion itself is verified on every run.

set -euo pipefail

: "${EXPECTED_BUNDLE_ID:?EXPECTED_BUNDLE_ID must be set}"
: "${FORBIDDEN_UPSTREAM_HOST:?FORBIDDEN_UPSTREAM_HOST must be set}"
: "${FORBIDDEN_UPSTREAM_BUNDLE_PREFIX:?FORBIDDEN_UPSTREAM_BUNDLE_PREFIX must be set}"
: "${FORBIDDEN_UPSTREAM_TEAM_ID:?FORBIDDEN_UPSTREAM_TEAM_ID must be set}"
: "${FORBIDDEN_UPSTREAM_ED_KEY:?FORBIDDEN_UPSTREAM_ED_KEY must be set}"

failed=0
fail() { echo "error: $*" >&2; failed=1; }

# Recursive, binary-safe search for a fixed string, with the exit status handled properly.
#
# grep's exit codes are 0 = matched, 1 = no match, >1 = ERROR (unreadable path, bad
# argument, I/O failure). The usual `grep ... 2>/dev/null || true` idiom collapses "error"
# into "clean", so a single unreadable file inside the bundle would silently take part of
# the tree out of the scan while the check still reported success. An error here is
# treated as a failure, never as an absence of matches.
#
# scan <label> <needle> <root>
scan() {
  local label="$1" needle="$2" root="$3" out err rc
  err="$(mktemp)"
  set +e
  out="$(grep -r -l -a -i -F -- "$needle" "$root" 2>"$err")"
  rc=$?
  set -e
  if [ "$rc" -gt 1 ]; then
    fail "scan for $label could not complete (grep exit $rc) -- treating as a FAILURE, not a pass:"
    sed 's/^/    /' "$err" >&2
    rm -f "$err"
    return 1
  fi
  # grep can also warn (e.g. on a broken symlink) while still exiting 0/1; surface it.
  if [ -s "$err" ]; then
    sed 's/^/    warning: /' "$err" >&2
  fi
  rm -f "$err"
  if [ "$rc" -eq 0 ]; then
    fail "$label ('$needle') is present in $root:"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    return 1
  fi
  echo "  clean: no $label"
  return 0
}

plist_value() { # plist_value <plist> <key> -> value or empty
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

assert_product() {
  local app_path="$1"
  local info_plist="$app_path/Contents/Info.plist"
  [ -f "$info_plist" ] || { fail "no Info.plist at $info_plist"; return; }

  local bundle_id
  bundle_id="$(plist_value "$info_plist" CFBundleIdentifier)"
  echo "  bundle id:        ${bundle_id:-<none>}"
  [ "$bundle_id" = "$EXPECTED_BUNDLE_ID" ] || \
    fail "bundle id '$bundle_id' does not match expected '$EXPECTED_BUNDLE_ID'"

  local feed_url
  feed_url="$(plist_value "$info_plist" SUFeedURL)"
  echo "  SUFeedURL:        ${feed_url:-<none>}"
  if [ -n "$feed_url" ] && printf '%s' "$feed_url" | grep -qiF -- "$FORBIDDEN_UPSTREAM_HOST"; then
    fail "SUFeedURL '$feed_url' points at upstream's host '$FORBIDDEN_UPSTREAM_HOST'"
  fi

  # Every nested bundle -- XPC services, plugins, embedded frameworks -- must be under the
  # fork's identifier. The XPC service ships inside the app and is signed with it, so an
  # upstream id there is exactly as bad as one at the top level.
  local nested count=0
  while IFS= read -r nested; do
    [ -n "$nested" ] || continue
    local nested_id
    nested_id="$(plist_value "$nested" CFBundleIdentifier)"
    [ -n "$nested_id" ] || continue
    count=$((count + 1))
    echo "  nested bundle:    $nested_id"
    case "$nested_id" in
      "$EXPECTED_BUNDLE_ID"|"$EXPECTED_BUNDLE_ID".*) ;;
      *) fail "nested bundle id '$nested_id' ($nested) is not under '$EXPECTED_BUNDLE_ID'" ;;
    esac
  done < <(find "$app_path/Contents" \
             \( -path '*/XPCServices/*' -o -path '*/PlugIns/*' -o -path '*/Frameworks/*' \) \
             -name Info.plist -maxdepth 4 2>/dev/null || true)
  echo "  nested bundles checked: $count"

  scan "upstream host"          "$FORBIDDEN_UPSTREAM_HOST"            "$app_path" || true
  scan "upstream bundle id"     "$FORBIDDEN_UPSTREAM_BUNDLE_PREFIX"   "$app_path" || true
  scan "upstream team id"       "$FORBIDDEN_UPSTREAM_TEAM_ID"         "$app_path" || true
  scan "upstream Sparkle key"   "$FORBIDDEN_UPSTREAM_ED_KEY"          "$app_path" || true
}

assert_project() {
  local root="$1"
  local pbxproj="$root/VoiceInk.xcodeproj/project.pbxproj"
  [ -f "$pbxproj" ] || { fail "no project.pbxproj under $root"; return; }

  # Positive check: every configured product identifier is under the fork's. This is the
  # only place the TEST bundle identifiers can be checked -- test bundles are built into
  # DerivedData, never into the .app, so the product scan cannot see them.
  local ids id count=0
  ids="$(sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER = "\{0,1\}\([^";]*\)"\{0,1\};.*/\1/p' "$pbxproj" | sort -u)"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    echo "  product id:       $id"
    case "$id" in
      "$EXPECTED_BUNDLE_ID"|"$EXPECTED_BUNDLE_ID".*) ;;
      *) fail "PRODUCT_BUNDLE_IDENTIFIER '$id' is not under '$EXPECTED_BUNDLE_ID'" ;;
    esac
  done <<< "$ids"
  [ "$count" -gt 0 ] || fail "no PRODUCT_BUNDLE_IDENTIFIER found in $pbxproj -- the check would be vacuous"
  echo "  product ids checked: $count"

  scan "upstream team id"      "$FORBIDDEN_UPSTREAM_TEAM_ID"       "$pbxproj" || true
  scan "upstream bundle id"    "$FORBIDDEN_UPSTREAM_BUNDLE_PREFIX" "$pbxproj" || true

  # Info.plists and entitlements carried in the repo: the feed URL and the Sparkle key
  # would come back here first.
  local plist
  for plist in "$root/VoiceInk/Info.plist" "$root/VoiceInkRefineXPC/Info.plist"; do
    [ -f "$plist" ] || continue
    scan "upstream host"        "$FORBIDDEN_UPSTREAM_HOST"   "$plist" || true
    scan "upstream Sparkle key" "$FORBIDDEN_UPSTREAM_ED_KEY" "$plist" || true
  done
}

case "${1:-}" in
  --project)
    [ -n "${2:-}" ] || { echo "usage: assert-fork-identity.sh --project <repo-root>" >&2; exit 2; }
    echo "checking project configuration in $2"
    assert_project "$2"
    ;;
  "")
    echo "usage: assert-fork-identity.sh <path-to-.app> | --project <repo-root>" >&2
    exit 2
    ;;
  *)
    echo "checking built product $1"
    assert_product "$1"
    ;;
esac

if [ "$failed" -ne 0 ]; then
  echo "FAILED: upstream identity is still present" >&2
  exit 1
fi
echo "OK: fork identity clean"

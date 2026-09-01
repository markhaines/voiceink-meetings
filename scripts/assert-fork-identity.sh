#!/bin/bash
# assert-fork-identity.sh <path-to-.app>
#
# Fails if a built product still carries upstream VoiceInk's identity. Two things must hold:
#
#   1. CFBundleIdentifier is this fork's bundle id, not upstream's.
#   2. Nothing in the bundle points at upstream's Sparkle appcast host. If it did, the fork
#      could auto-update itself into upstream's build -- silently replacing the de-licensed,
#      re-signed fork with the original app.
#
# The feed check is deliberately a HOST-level substring match, not an exact-URL match: a
# near-miss such as ".../VoiceInk/appcast-v2.xml" on the same host is just as dangerous, and
# an exact-string comparison would wave it through.
#
# Env: EXPECTED_BUNDLE_ID, FORBIDDEN_SPARKLE_FEED_HOST (both required).
# Exits 0 when the product is clean, 1 otherwise. CI runs this against the real build AND
# against fabricated negative controls, so the assertion itself is verified every run.

set -euo pipefail

app_path="${1:-}"
if [ -z "$app_path" ]; then
  echo "usage: assert-fork-identity.sh <path-to-.app>" >&2
  exit 2
fi
: "${EXPECTED_BUNDLE_ID:?EXPECTED_BUNDLE_ID must be set}"
: "${FORBIDDEN_SPARKLE_FEED_HOST:?FORBIDDEN_SPARKLE_FEED_HOST must be set}"

info_plist="$app_path/Contents/Info.plist"
if [ ! -f "$info_plist" ]; then
  echo "error: no Info.plist at $info_plist" >&2
  exit 1
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
echo "  bundle id:        $bundle_id"
if [ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]; then
  echo "error: bundle id '$bundle_id' does not match expected '$EXPECTED_BUNDLE_ID'" >&2
  exit 1
fi

feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_plist" 2>/dev/null || true)"
echo "  SUFeedURL:        ${feed_url:-<none>}"
if [ -n "$feed_url" ] && printf '%s' "$feed_url" | grep -qiF "$FORBIDDEN_SPARKLE_FEED_HOST"; then
  echo "error: SUFeedURL '$feed_url' points at upstream's appcast host '$FORBIDDEN_SPARKLE_FEED_HOST'" >&2
  exit 1
fi

# Belt and braces: the URL could also be hardcoded in the executable or a nested bundle
# (XPC service, framework) rather than the top-level Info.plist. -a so binaries are scanned.
if grep -rqaiF "$FORBIDDEN_SPARKLE_FEED_HOST" "$app_path" 2>/dev/null; then
  echo "error: upstream appcast host '$FORBIDDEN_SPARKLE_FEED_HOST' is referenced inside $app_path:" >&2
  grep -rlaiF "$FORBIDDEN_SPARKLE_FEED_HOST" "$app_path" 2>/dev/null | sed 's/^/    /' >&2 || true
  exit 1
fi
echo "  bundle scan:      no reference to $FORBIDDEN_SPARKLE_FEED_HOST"

echo "OK: fork identity clean"

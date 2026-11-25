#!/bin/bash

# Notarize a Developer ID-signed app or disk image with Apple and staple the
# ticket to it, so Gatekeeper accepts it and no quarantine workaround is
# needed. Releases notarize only the disk image: the notary service checks
# the app inside it as well and issues the app's ticket in the same go.
#
#   APPLE_API_KEY_PATH=AuthKey_XXXX.p8 APPLE_API_KEY_ID=XXXX APPLE_API_ISSUER_ID=… \
#     ./scripts/notarize-app.sh build/dev/LocalVoice.app
#   … ./scripts/notarize-app.sh build/LocalVoice-v1.2.0-arm64.dmg
#
# Uses an App Store Connect API key (Team key) rather than an Apple ID.

set -euo pipefail

fail() {
  echo "Error: $*" >&2
  exit 1
}

TARGET="${1%/}"
case "$TARGET" in
  *.app) [[ -d "$TARGET/Contents" ]] || fail "Not an app bundle: $TARGET" ;;
  *.dmg) [[ -f "$TARGET" ]] || fail "Disk image not found: $TARGET" ;;
  *) fail "Usage: $0 path/to/App.app | path/to/Image.dmg" ;;
esac
for variable in APPLE_API_KEY_PATH APPLE_API_KEY_ID APPLE_API_ISSUER_ID; do
  [[ -n "${!variable:-}" ]] || fail "$variable is not set."
done
[[ -f "$APPLE_API_KEY_PATH" ]] || fail "API key file not found: $APPLE_API_KEY_PATH"

codesign --verify --strict "$TARGET" || fail "$TARGET is not validly signed."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/notarize.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
AUTH=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")

# The notary service takes a disk image as it is; an app bundle goes up as a zip.
if [[ "$TARGET" == *.app ]]; then
  SUBMISSION="$WORK/$(basename "$TARGET" .app).zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMISSION"
else
  SUBMISSION="$TARGET"
fi
echo "Submitting $(basename "$TARGET") ($(du -h "$SUBMISSION" | cut -f1)) to the notary service…"
# notarytool's exit status does not reliably reflect the verdict; read it from the JSON.
# It writes the JSON to stdout on a verdict but to stderr on a timeout or error.
xcrun notarytool submit "$SUBMISSION" "${AUTH[@]}" --wait --timeout "${NOTARY_TIMEOUT:-45m}" \
  --output-format json > "$WORK/result.json" 2> "$WORK/stderr.txt" || true
field() {
  python3 -I -c 'import json, sys
key, paths = sys.argv[1], sys.argv[2:]
for path in paths:
    for line in reversed(open(path, errors="replace").read().splitlines()):
        try:
            value = json.loads(line).get(key)
        except (ValueError, AttributeError):
            continue
        if value:
            print(value)
            sys.exit()' "$1" "$WORK/result.json" "$WORK/stderr.txt"
}
ID="$(field id)"
STATUS="$(field status)"
echo "Submission ${ID:-?}: ${STATUS:-no verdict}"

if [[ "$STATUS" != "Accepted" ]]; then
  cat "$WORK/result.json" "$WORK/stderr.txt" >&2
  echo >&2
  [[ -n "$STATUS" || -z "$ID" ]] || echo "Apple may still be processing it: xcrun notarytool info $ID …" >&2
  if [[ -n "$ID" ]]; then
    echo "Notary log:" >&2
    xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
  fi
  fail "Notarization did not succeed."
fi

xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
if [[ "$TARGET" == *.app ]]; then
  spctl --assess --type execute --verbose=2 "$TARGET"
else
  spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET"
fi

#!/usr/bin/env bash
#
# Signs, notarises and staples a distributable build.
#
# Requires an Apple Developer Program membership. Ad-hoc signed builds run on the
# machine that produced them but are refused by Gatekeeper elsewhere; notarising
# is what makes a build distributable.
#
# Prerequisites — store credentials once:
#   xcrun notarytool store-credentials huh-notary \
#       --apple-id "you@example.com" \
#       --team-id "TEAMID" \
#       --password "app-specific-password"
#
# Usage:
#   SIGN_ID="Developer ID Application: Name (TEAMID)" ./scripts/notarize.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NAME="Huh"
BUNDLE="huh?"
PROFILE="${NOTARY_PROFILE:-huh-notary}"
VERSION="$(tr -d '[:space:]' < VERSION)"

if [ "${SIGN_ID:--}" = "-" ]; then
    echo "!! SIGN_ID must be a Developer ID Application identity." >&2
    echo "   Available identities:" >&2
    security find-identity -v -p codesigning | sed 's/^/     /' >&2
    exit 1
fi

echo "==> building signed release"
./scripts/build.sh release

RECORD="$ROOT/.build/last-bundle-path"
[ -f "$RECORD" ] || { echo "!! build.sh did not record a bundle path" >&2; exit 1; }
APP="$(cat "$RECORD")"
[ -d "$APP" ] || { echo "!! no bundle at $APP -- run scripts/build.sh first" >&2; exit 1; }
DIST="$ROOT/dist"
ARCHIVE="$DIST/$NAME-$VERSION.zip"
mkdir -p "$DIST"

echo "==> archiving for submission"
rm -f "$ARCHIVE"
# ditto preserves the signature and extended attributes; zip does not.
/usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"

echo "==> submitting to Apple (this can take several minutes)"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait

echo "==> stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> re-archiving the stapled bundle"
rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/    /'

echo "==> done: $ARCHIVE"

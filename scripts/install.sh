#!/usr/bin/env bash
# Builds and installs the application to /Applications.
#
# Exactly one copy should exist on disk. macOS records permission grants against
# the application's path, so a second copy requires granting Accessibility again
# and makes it ambiguous which instance is active.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="Huh"
BUNDLE="huh?"
CONFIG="${1:-release}"

"$ROOT/scripts/build.sh" "$CONFIG"

DEST="/Applications"
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    echo "!! /Applications isn't writable, installing to $DEST instead"
fi

# The path build.sh just wrote, not a guess at where it might have put things.
RECORD="$ROOT/.build/last-bundle-path"
[ -f "$RECORD" ] || { echo "!! build.sh did not record a bundle path" >&2; exit 1; }
SOURCE="$(cat "$RECORD")"
[ -d "$SOURCE" ] || { echo "!! no bundle at $SOURCE" >&2; exit 1; }

EXPECTED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE/Contents/Info.plist")"

echo "==> installing to $DEST/$BUNDLE.app"
pkill -f "/Contents/MacOS/$NAME" 2>/dev/null || true
sleep 1
rm -rf "${DEST:?}/$BUNDLE.app"
cp -R "$SOURCE" "$DEST/$BUNDLE.app"

# Confirm the thing on disk is the thing just built. A silent stale install is
# worse than a failed one: everything downstream looks like it worked.
LANDED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/$BUNDLE.app/Contents/Info.plist")"
if [ "$LANDED" != "$EXPECTED" ]; then
    echo "!! installed build $LANDED but built $EXPECTED" >&2
    exit 1
fi
codesign --verify --strict "$DEST/$BUNDLE.app" || { echo "!! signature invalid after install" >&2; exit 1; }

echo "==> done (build $LANDED)"
echo "    launch it:        open \"$DEST/$BUNDLE.app\""
echo "    or hit ⌘-Space and type: huh"

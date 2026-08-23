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

echo "==> installing to $DEST/$BUNDLE.app"
pkill -f "/Contents/MacOS/$NAME" 2>/dev/null || true
sleep 1
rm -rf "${DEST:?}/$BUNDLE.app"
cp -R "${HUH_STAGE:-${TMPDIR:-/tmp/}huh-build}/$BUNDLE.app" "$DEST/$BUNDLE.app"

echo "==> done"
echo "    launch it:        open \"$DEST/$BUNDLE.app\""
echo "    or hit ⌘-Space and type: huh"

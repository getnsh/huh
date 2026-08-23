#!/usr/bin/env bash
#
# Builds the application and assembles a signed bundle.
#
# The project is built with SwiftPM and the bundle is assembled here rather than
# by Xcode, so a full Xcode installation is not required — Command Line Tools are
# sufficient. An .app bundle is a directory with an Info.plist and a signature.
#
# Usage:
#   ./scripts/build.sh [debug|release]
#
# Environment:
#   SIGN_ID   Code signing identity. Defaults to "-" (ad hoc).
#             Set to a Developer ID Application identity for distribution.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Two names by design:
#   NAME    executable and every path the shell touches. Filesystem-safe.
#   BUNDLE  the name Finder displays. Contains "?", which is a shell glob and a
#           regular-expression metacharacter, so it appears only in quoted paths.
NAME="Huh"
BUNDLE="huh?"
IDENTIFIER="com.getnsh.huh"

VERSION="$(tr -d '[:space:]' < VERSION)"
# Monotonic build number derived from the commit count when available, so
# CFBundleVersion increases across releases as the App Store requires.
if git rev-parse --git-dir >/dev/null 2>&1; then
    BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
else
    BUILD="1"
fi

# The bundle is staged outside the source tree. Some filesystems — network
# shares, synced folders — attach Finder metadata to directories as they are
# written, which codesign rejects under --strict and which cannot be removed
# durably while the file lives there.
STAGE="${HUH_STAGE:-${TMPDIR:-/tmp/}huh-build}"
APP="$STAGE/$BUNDLE.app"
CONTENTS="$APP/Contents"

# Metal shaders need a toolchain Command Line Tools does not ship.
#
# The summary model runs through MLX, whose GPU kernels are Metal source
# compiled at build time. `metal` lives in Xcode, and since Xcode 26 it is a
# separately downloaded component even there. Both absences produce errors that
# name a missing .dia file rather than the actual cause, so they are checked for
# here and reported plainly.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcrun --find metal >/dev/null 2>&1; then
    for CANDIDATE in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [ -d "$CANDIDATE/Contents/Developer" ]; then
            export DEVELOPER_DIR="$CANDIDATE/Contents/Developer"
            echo "==> using $CANDIDATE for the Metal toolchain"
            break
        fi
    done
fi

if ! xcrun --find metal >/dev/null 2>&1; then
    cat >&2 <<'MSG'
!! No Metal compiler found.

   This project builds Metal shaders and needs Xcode, not just Command Line
   Tools. If Xcode is installed, the Metal toolchain is a separate download:

       xcodebuild -downloadComponent MetalToolchain

   Then build again, or point DEVELOPER_DIR at your Xcode:

       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build.sh
MSG
    exit 1
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/$NAME"
[ -f "$BIN" ] || { echo "!! binary not found at $BIN" >&2; exit 1; }

echo "==> assembling $BUNDLE.app ($VERSION build $BUILD)"
rm -rf "$APP"
mkdir -p "$STAGE" "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN" "$CONTENTS/MacOS/$NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/PrivacyInfo.xcprivacy" "$CONTENTS/Resources/PrivacyInfo.xcprivacy"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/"
printf 'APPL????' > "$CONTENTS/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$CONTENTS/Info.plist"

# Strip extended attributes before signing. Files copied through Finder or a
# network volume carry quarantine flags and resource forks, which codesign
# rejects as "detritus".
xattr -cr "$APP"

# Hardened Runtime is enabled unconditionally. It is a prerequisite for
# notarisation and it costs this application nothing: there is no JIT, no
# unsigned executable memory, and no injected library.
SIGN_ID="${SIGN_ID:--}"
TIMESTAMP="--timestamp"
[ "$SIGN_ID" = "-" ] && TIMESTAMP="--timestamp=none"

echo "==> codesign (identity: $SIGN_ID, hardened runtime)"
codesign --force \
    --sign "$SIGN_ID" \
    --identifier "$IDENTIFIER" \
    --options runtime \
    --entitlements "$ROOT/Resources/$NAME.entitlements" \
    $TIMESTAMP \
    "$APP" >/dev/null

echo "==> verifying signature"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "==> done: $APP"
echo "    install with: ./scripts/install.sh"

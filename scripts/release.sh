#!/usr/bin/env bash
#
# Builds a distributable archive and the checksum that proves which one it is.
#
# Releases used to be assembled by hand and uploaded with nothing published
# alongside them, which left a real gap: the install instructions ask people to
# run `xattr -cr` on the download, and that removes the quarantine flag -- the
# only thing standing between an unnotarised binary and a machine. Someone
# following those instructions on a swapped asset would see no warning at all,
# and had no way to tell.
#
# A checksum does not stop a swap. What it does is make one detectable by
# anybody who cares to look, and give every previous download a fixed identity.
# It only means something if the value is published somewhere the archive is
# not, which is what `--publish` is for: the release notes on GitHub.
#
# Notarising is strictly better and this script will do it when it can. It
# needs an Apple Developer Program membership, a Developer ID Application
# certificate, and a stored notarytool profile. Without those, the archive is
# still produced and the script says plainly what the user will have to do.
#
# Usage:
#   ./scripts/release.sh                  build, archive, checksum
#   ./scripts/release.sh --publish        also attach it to the GitHub release
#
# Environment:
#   SIGN_ID          Developer ID Application identity; enables notarisation
#   NOTARY_PROFILE   notarytool keychain profile (default: huh-notary)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
BUNDLE="huh?"
FOLDER="huh-$VERSION"
DIST="$ROOT/dist"
STAGE="$DIST/$FOLDER"
ARCHIVE="$DIST/$FOLDER.zip"
SUMS="$DIST/SHASUMS.txt"
PUBLISH=false

for ARG in "$@"; do
    case "$ARG" in
        --publish) PUBLISH=true ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "!! unknown argument: $ARG" >&2; exit 1 ;;
    esac
done

echo "==> building $VERSION"
./scripts/build.sh release

RECORD="$ROOT/.build/last-bundle-path"
[ -f "$RECORD" ] || { echo "!! build.sh did not record a bundle path" >&2; exit 1; }
APP="$(cat "$RECORD")"
[ -d "$APP" ] || { echo "!! no bundle at $APP" >&2; exit 1; }

# The version in the archive name has to be the version inside the bundle, or
# the checksum is published against a number that does not describe it.
BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$BUILT" != "$VERSION" ]; then
    echo "!! VERSION says $VERSION but the bundle says $BUILT" >&2
    exit 1
fi

# ── Notarisation, when the credentials for it exist ──────────────────────
NOTARISED=false
PROFILE="${NOTARY_PROFILE:-huh-notary}"
if [ "${SIGN_ID:-}" != "" ] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "==> notarising"
    SUBMISSION="$DIST/notarise-$VERSION.zip"
    mkdir -p "$DIST"
    rm -f "$SUBMISSION"
    /usr/bin/ditto -c -k --keepParent "$APP" "$SUBMISSION"
    xcrun notarytool submit "$SUBMISSION" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$SUBMISSION"
    NOTARISED=true
else
    echo "==> not notarising (no SIGN_ID, or no '$PROFILE' notarytool profile)"
fi

# ── Stage exactly what the user unzips ───────────────────────────────────
echo "==> staging $FOLDER"
rm -rf "$STAGE" "$ARCHIVE" "$SUMS"
mkdir -p "$STAGE"
# ditto, not cp: it preserves the code signature and extended attributes.
/usr/bin/ditto "$APP" "$STAGE/$BUNDLE.app"
/usr/bin/ditto "$ROOT/scripts/uninstall.sh" "$STAGE/uninstall.sh"
chmod +x "$STAGE/uninstall.sh"

if [ "$NOTARISED" = true ]; then
    QUARANTINE_NOTE="  2. Open it. macOS will check it with Apple the first time, which takes
     a moment."
else
    QUARANTINE_NOTE="  2. Open Terminal and run:

         xattr -cr \"/Applications/$BUNDLE.app\"

     This is required, not optional. The build is signed on the machine that
     produced it rather than by Apple, so macOS refuses to open it until the
     quarantine flag it attached on download is cleared. Check the SHA-256
     against the one in the release notes before you do this -- clearing
     quarantine is the point at which macOS stops asking questions."
fi

cat > "$STAGE/INSTALL.txt" <<TXT
huh? $VERSION

Push-to-talk dictation and meeting transcription for macOS.


VERIFY

  Before installing, check that the archive you downloaded is the one that was
  published. In the folder holding the zip:

      shasum -a 256 $FOLDER.zip

  Compare the result with the SHA-256 printed in the release notes on
  https://github.com/getnsh/huh/releases . If they differ, stop.


INSTALL

  1. Drag "$BUNDLE.app" to your Applications folder.

$QUARANTINE_NOTE

  3. Open it. Grant Microphone and Accessibility when asked -- the first is for
     hearing you, the second is for typing into whatever app you are in.
     Accessibility must be enabled by hand in
     System Settings > Privacy & Security > Accessibility.


USING IT

  Hold the Right Option key and talk. Release, and the text lands wherever your
  cursor is.

  To transcribe a recording, drop the file on the window or press Cmd-O.


UNINSTALL

  Run the included script:

      ./uninstall.sh              removes the app, keeps your data
      ./uninstall.sh --all        also deletes transcripts and dictionaries

  Your transcripts, dictionary and saved names live in
  ~/Library/Application Support/Huh and are kept unless you ask for --all.


REQUIREMENTS

  macOS 26 or later, Apple silicon.

  Summaries and finding names use Apple's on-device model, which needs Apple
  Intelligence. Without it, everything else still works, and a longer meeting
  can be summarised by downloading a local model instead.


PRIVACY

  Nothing is sent anywhere. Audio is never written to disk and never uploaded.
  Two optional downloads exist, both off by default and neither carrying any of
  your content: the Parakeet speech models, and Qwen3 4B for summaries. Both
  are pinned to an exact revision.

  Sending a transcript to ChatGPT or Claude is offered for long meetings. That
  one is manual: it copies the text to your clipboard and opens the site, so you
  paste it yourself and can see exactly what you are sending.

  Made by getnsh.
TXT

echo "==> archiving"
# --keepParent so the zip expands into $FOLDER/ rather than scattering.
# ditto rather than zip: no __MACOSX directory, and the signature survives.
( cd "$DIST" && /usr/bin/ditto -c -k --keepParent "$FOLDER" "$FOLDER.zip" )

echo "==> checksum"
( cd "$DIST" && shasum -a 256 "$FOLDER.zip" > "SHASUMS.txt" )
DIGEST="$(awk '{print $1}' "$SUMS")"

# The archive is verified as it now sits on disk, not as it was a moment ago.
( cd "$DIST" && shasum -a 256 -c SHASUMS.txt >/dev/null ) \
    || { echo "!! the archive does not match its own checksum" >&2; exit 1; }

echo
echo "    $ARCHIVE"
echo "    sha256  $DIGEST"
echo "    notarised: $NOTARISED"
echo

if [ "$PUBLISH" = true ]; then
    command -v gh >/dev/null || { echo "!! gh is not installed" >&2; exit 1; }
    TAG="v$VERSION"
    echo "==> attaching to $TAG"
    gh release upload "$TAG" "$ARCHIVE" "$SUMS" --clobber
    echo "==> done. Put this in the release notes:"
    echo
    echo "    sha256  $DIGEST"
else
    echo "    publish with: ./scripts/release.sh --publish"
fi

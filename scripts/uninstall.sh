#!/usr/bin/env bash
#
# Removes huh? and, optionally, everything it stored.
#
# Two separate things are removed by two separate steps, on purpose. The
# application is disposable; the dictionary, the people you taught it and your
# transcript history are not, and deleting them silently alongside the app would
# be the wrong default.
#
# Usage:
#   ./scripts/uninstall.sh              app and login item only, data kept
#   ./scripts/uninstall.sh --all        also delete transcripts and dictionaries
#   ./scripts/uninstall.sh --all --yes  no confirmation prompt
set -euo pipefail

APP_NAME="huh?.app"
# ${HOME:?} rather than $HOME. These paths are handed to `rm -rf` below, and
# with HOME unset or empty they would resolve to /Library/Application
# Support/... -- system-wide, and not this application's to delete.
SUPPORT="${HOME:?HOME is not set}/Library/Application Support/Huh"
LEGACY="${HOME:?HOME is not set}/Library/Application Support/Murmur"
BUNDLE_ID="com.getnsh.huh"

PURGE=false
ASSUME_YES=false
for ARG in "$@"; do
    case "$ARG" in
        --all) PURGE=true ;;
        --yes|-y) ASSUME_YES=true ;;
        -h|--help) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "!! unknown option: $ARG" >&2; exit 1 ;;
    esac
done

echo "==> quitting huh? if it is running"
osascript -e 'tell application "System Events" to if exists (processes whose bundle identifier is "com.getnsh.huh") then quit application id "com.getnsh.huh"' 2>/dev/null || true
pkill -x Huh 2>/dev/null || true
sleep 1

echo "==> removing the login item"
osascript -e 'tell application "System Events" to delete login item "Huh"' 2>/dev/null || true

for DIR in /Applications "$HOME/Applications"; do
    if [ -d "$DIR/$APP_NAME" ]; then
        echo "==> removing $DIR/$APP_NAME"
        rm -rf "$DIR/$APP_NAME"
    fi
done

echo "==> removing preferences"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"
rm -rf "$HOME/Library/Caches/$BUNDLE_ID"
rm -rf "$HOME/Library/HTTPStorages/$BUNDLE_ID"
rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"

if [ "$PURGE" = true ]; then
    if [ "$ASSUME_YES" != true ]; then
        echo
        echo "This will permanently delete:"
        echo "    $SUPPORT"
        [ -d "$LEGACY" ] && echo "    $LEGACY"
        echo
        echo "That is your transcript history, your dictionary, your saved names"
        echo "and every review decision. It cannot be undone."
        printf "Type 'delete' to confirm: "
        read -r REPLY
        [ "$REPLY" = "delete" ] || { echo "==> cancelled; nothing was deleted"; exit 0; }
    fi
    echo "==> deleting stored data"
    rm -rf "${SUPPORT:?}" "${LEGACY:?}"
else
    if [ -d "$SUPPORT" ] || [ -d "$LEGACY" ]; then
        echo
        echo "Your data was kept:"
        [ -d "$SUPPORT" ] && echo "    $SUPPORT"
        [ -d "$LEGACY" ] && echo "    $LEGACY"
        echo "Run with --all to delete it too."
    fi
fi

# Downloaded models are shared with any other application using the same cache,
# so they are reported rather than removed.
CACHE="$HOME/.cache/huggingface"
if [ -d "$CACHE" ]; then
    SIZE="$(du -sh "$CACHE" 2>/dev/null | cut -f1)"
    echo
    echo "Downloaded speech and language models are in a shared cache:"
    echo "    $CACHE  ($SIZE)"
    echo "Other applications may use it. Remove it yourself if nothing else needs it."
fi

cat <<'NOTE'

==> done

Two permissions remain granted to an application that no longer exists. macOS
does not let an app revoke its own, so remove them by hand if you want them
gone:

    System Settings > Privacy & Security > Microphone
    System Settings > Privacy & Security > Accessibility
NOTE

#!/usr/bin/env bash
# Makes huh? start automatically at login. Reversible from
# System Settings ▸ General ▸ Login Items, or by running:
#   ./scripts/enable-login-item.sh --off
set -euo pipefail

APP="/Applications/huh?.app"
[ -d "$APP" ] || APP="$HOME/Applications/huh?.app"

if [ "${1:-}" = "--off" ]; then
    osascript -e 'tell application "System Events" to delete login item "Huh"' 2>/dev/null || true
    echo "==> huh? removed from login items"
    exit 0
fi

[ -d "$APP" ] || { echo "!! huh? isn't installed. Run ./scripts/install.sh first."; exit 1; }

osascript -e 'tell application "System Events" to delete login item "Huh"' 2>/dev/null || true
osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APP\", hidden:true, name:\"Huh\"}" >/dev/null
echo "==> huh? will start at login ($APP)"

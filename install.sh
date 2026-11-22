#!/bin/bash
# Install (or update) KeyMirror from a downloaded KeyMirror.zip or KeyMirror.app.
# Handles the Gatekeeper quarantine so the ad-hoc-signed app will open.
#
# Usage:
#   ./install.sh                     # finds KeyMirror.zip/.app next to this script or in ~/Downloads
#   ./install.sh ~/Downloads/KeyMirror.zip
#
set -euo pipefail

APP_NAME="KeyMirror.app"
DEST="/Applications/${APP_NAME}"

find_source() {
    if [ $# -ge 1 ]; then echo "$1"; return; fi
    for d in "$(dirname "$0")" "$HOME/Downloads" "$PWD"; do
        [ -e "$d/KeyMirror.zip" ] && { echo "$d/KeyMirror.zip"; return; }
        [ -e "$d/$APP_NAME" ]    && { echo "$d/$APP_NAME"; return; }
    done
    echo ""
}

SRC="$(find_source "$@")"
if [ -z "$SRC" ]; then
    echo "✗ Couldn't find KeyMirror.zip or KeyMirror.app."
    echo "  Download it from the Releases page, then run: ./install.sh <path-to-zip>"
    exit 1
fi

TMP="$(mktemp -d)"
if [[ "$SRC" == *.zip ]]; then
    echo "▸ unpacking $SRC"
    ditto -x -k "$SRC" "$TMP"
    APP_SRC="$(/usr/bin/find "$TMP" -maxdepth 2 -name "$APP_NAME" -print -quit)"
else
    APP_SRC="$SRC"
fi
[ -n "$APP_SRC" ] || { echo "✗ No $APP_NAME inside $SRC"; exit 1; }

echo "▸ installing to $DEST"
rm -rf "$DEST"
ditto "$APP_SRC" "$DEST"

echo "▸ clearing Gatekeeper quarantine"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "▸ launching"
open "$DEST"

echo
echo "✓ Installed. Look for the ⌨ icon in the menu bar."
echo "  Grant Accessibility (+ Input Monitoring if this Mac is the Sender) and"
echo "  Local Network when prompted, then set the shared secret in Preferences."

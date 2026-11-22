#!/bin/bash
# Cut a new release from this Mac: build, zip, tag, and publish to GitHub.
# Installed apps pick it up via the in-app updater.
#
#   ./release.sh 0.5.1
#
# (This is the reliable path while GitHub-hosted macOS runners aren't available
#  to the account. If you enable them, you can instead run the Release workflow.)
set -euo pipefail
cd "$(dirname "$0")"

REPO="MaxFishman/keymirror"
V="${1:-}"
[ -n "$V" ] || { echo "usage: ./release.sh <version>   e.g. ./release.sh 0.5.1"; exit 1; }
V="${V#v}"
TAG="v$V"

echo "▸ building $TAG"
VERSION="$V" BUILD="$(date +%Y%m%d%H%M)" ./build-app.sh >/dev/null
ditto -c -k --keepParent dist/KeyMirror.app dist/KeyMirror.zip

echo "▸ tagging + pushing $TAG"
git tag "$TAG"
git push origin "$TAG"

echo "▸ publishing GitHub release"
gh release create "$TAG" dist/KeyMirror.zip \
    --repo "$REPO" \
    --title "keymirror $TAG" \
    --generate-notes

echo "✓ released $TAG — https://github.com/$REPO/releases/tag/$TAG"
echo "  Open apps will offer the update within a few hours (or via Check for Updates)."

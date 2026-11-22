#!/bin/bash
# Build KeyMirror.app — a menu-bar agent wrapping the keymirror binary.
#
#   ./build-app.sh            # release build + bundle + ad-hoc sign
#   open dist/KeyMirror.app   # launch it (appears in the menu bar)
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="KeyMirror"
BUNDLE_ID="org.fishman.keymirror"
# VERSION/BUILD can be overridden by the release pipeline (from the git tag).
VERSION="${VERSION:-0.5.0}"
BUILD="${BUILD:-5}"

echo "▸ compiling release binary…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/keymirror"

APP="dist/${APP_NAME}.app"
echo "▸ assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/keymirror"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>      <string>keymirror</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <!-- Menu-bar agent: no Dock icon, no main window. -->
    <key>LSUIElement</key>             <true/>
    <!-- Required for Bonjour browse/advertise on modern macOS. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>keymirror uses the local network to mirror key presses to your other Mac.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_keymirror._tcp</string>
    </array>
</dict>
</plist>
PLIST

echo "▸ ad-hoc code-signing…"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || \
    codesign --force --sign - "$APP"

echo "✓ built ${APP}"
echo
echo "Launch it:   open ${APP}"
echo "It appears as ⌨ in the menu bar. Pick a mode from its menu."
echo
echo "NOTE: ad-hoc signing is fine for personal use on this Mac. macOS will ask"
echo "for Accessibility / Input Monitoring / Local Network the first time — allow"
echo "them. For distribution to other Macs you'd sign with a Developer ID cert"
echo "and notarize."

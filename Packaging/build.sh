#!/usr/bin/env bash
# Build, ad-hoc sign, and package FreeSlapMac into a .dmg.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP_NAME="FreeSlapMac"
APP_BUNDLE="$BUILD/$APP_NAME.app"
HELPER_NAME="com.freeslapmac.helper"
MIN_MACOS="14.0"
ARCH="arm64"
SDK=$(xcrun --sdk macosx --show-sdk-path)

echo "==> Cleaning $BUILD"
rm -rf "$BUILD"
mkdir -p "$APP_BUNDLE/Contents/"{MacOS,Resources,Library/LaunchDaemons}

echo "==> Compiling app"
APP_SRCS=(
    "$ROOT/App/FreeSlapMacApp.swift"
    "$ROOT/App/MenuBarView.swift"
    "$ROOT/App/SettingsView.swift"
    "$ROOT/App/SlapEngine.swift"
    "$ROOT/App/MotionInventory.swift"
    "$ROOT/Helper/HIDSensor.swift"
    "$ROOT/Helper/SlapDetector.swift"
    "$ROOT/Shared/XPCProtocol.swift"
    "$ROOT/Shared/Logging.swift"
)
xcrun swiftc \
    -target "${ARCH}-apple-macos${MIN_MACOS}" \
    -sdk "$SDK" -O -parse-as-library \
    -framework AppKit -framework SwiftUI -framework AVFoundation \
    -framework Combine -framework ServiceManagement -framework OSLog -framework IOKit \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    "${APP_SRCS[@]}"

echo "==> Compiling helper daemon"
HELPER_SRCS=(
    "$ROOT/Helper/main.swift"
    "$ROOT/Helper/HIDSensor.swift"
    "$ROOT/Helper/SlapDetector.swift"
    "$ROOT/Shared/XPCProtocol.swift"
    "$ROOT/Shared/Logging.swift"
)
xcrun swiftc \
    -target "${ARCH}-apple-macos${MIN_MACOS}" \
    -sdk "$SDK" -O \
    -framework IOKit -framework Foundation -framework OSLog \
    -o "$APP_BUNDLE/Contents/MacOS/$HELPER_NAME" \
    "${HELPER_SRCS[@]}"

echo "==> Embedding LaunchDaemon plist"
cp "$ROOT/Helper/com.freeslapmac.helper.plist" \
   "$APP_BUNDLE/Contents/Library/LaunchDaemons/com.freeslapmac.helper.plist"

echo "==> Copying resources"
cp "$ROOT/App/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
mkdir -p "$APP_BUNDLE/Contents/Resources/Sounds/Reactions"
mkdir -p "$APP_BUNDLE/Contents/Resources/Sounds/Relax"
shopt -s nullglob
for f in "$ROOT/Resources/Sounds/Reactions/"*.{mp3,wav,m4a,aac,aif,aiff,flac,caf}; do
    cp "$f" "$APP_BUNDLE/Contents/Resources/Sounds/Reactions/"
    echo "    + $(basename "$f")"
done
for f in "$ROOT/Resources/Sounds/Relax/"*.{mp3,wav,m4a,aac,aif,aiff,flac,caf}; do
    cp "$f" "$APP_BUNDLE/Contents/Resources/Sounds/Relax/"
    echo "    + $(basename "$f")"
done
shopt -u nullglob

echo "==> Ad-hoc signing"
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$HELPER_NAME"
codesign --force --sign - \
    --entitlements "$ROOT/App/FreeSlapMac.entitlements" \
    --deep "$APP_BUNDLE"

echo "==> Verifying"
codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1 | head -8

DMG="$BUILD/$APP_NAME.dmg"
if command -v create-dmg >/dev/null 2>&1; then
    create-dmg --volname "$APP_NAME" --window-size 540 380 --icon-size 96 \
        --icon "$APP_NAME.app" 140 190 --app-drop-link 400 190 \
        --no-internet-enable "$DMG" "$APP_BUNDLE" || \
        hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG"
else
    hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG"
fi

echo ""
echo "==> Done: $DMG"
echo "   First run: right-click app → Open → Open Anyway"
echo "   Then in the app: Settings → Install Helper → approve in System Settings → Login Items"
echo "   Logs: ~/Library/Logs/FreeSlapMac/  and  /var/log/FreeSlapMac/"

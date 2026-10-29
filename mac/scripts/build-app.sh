#!/bin/bash
# Builds 密钥匣.app (universal: Apple silicon + Intel), ad-hoc signed.
#   scripts/build-app.sh            -> dist/release/密钥匣.app and dist/KeyBox-mac.zip
#   scripts/build-app.sh debug      -> dist/debug/密钥匣.app (includes the --ui-snapshot test mode)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARCHS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" "${ARCHS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)"

APP="dist/$CONFIG/密钥匣.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/zh-Hans.lproj"
cp "$BIN_DIR/KeyBox" "$APP/Contents/MacOS/KeyBox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: required for Apple silicon. Not notarized, so the first launch needs
# System Settings > Privacy & Security > "Open Anyway" (or: xattr -dr com.apple.quarantine <app>).
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"
lipo -info "$APP/Contents/MacOS/KeyBox"

if [ "$CONFIG" = release ]; then
  rm -f dist/KeyBox-mac.zip
  (cd "dist/$CONFIG" && ditto -c -k --sequesterRsrc --keepParent "密钥匣.app" ../KeyBox-mac.zip)
  ls -l dist/KeyBox-mac.zip
fi

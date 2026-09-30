#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CORE_PATH="${1:-}"
CORE_LICENSE_PATH="${2:-}"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if [[ -z "$CORE_PATH" || ! -x "$CORE_PATH" ]]; then
  echo "Usage: Scripts/package.sh /path/to/sing-box" >&2
  exit 2
fi

cd "$ROOT_DIR"
swift test
MACOSX_DEPLOYMENT_TARGET=10.15 swift build -c release --arch x86_64
BIN_DIR="$(swift build -c release --arch x86_64 --show-bin-path)"

APP_DIR="$ROOT_DIR/dist/Maos VPN.app"
rm -rf "$ROOT_DIR/dist"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/MaosVPN" "$APP_DIR/Contents/MacOS/MaosVPN"
cp "$CORE_PATH" "$APP_DIR/Contents/Resources/sing-box"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE-MaosVPN.txt"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ -n "$CORE_LICENSE_PATH" && -f "$CORE_LICENSE_PATH" ]]; then
  cp "$CORE_LICENSE_PATH" "$APP_DIR/Contents/Resources/LICENSE-sing-box.txt"
fi
chmod 755 "$APP_DIR/Contents/MacOS/MaosVPN" "$APP_DIR/Contents/Resources/sing-box"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")" = "$APP_VERSION"

ICONSET="$ROOT_DIR/.build/MaosVPN.iconset"
rm -rf "$ICONSET"
swift "$ROOT_DIR/Scripts/generate_icon.swift" "$ICONSET"

for icon in \
  icon_16x16.png icon_16x16@2x.png \
  icon_32x32.png icon_32x32@2x.png \
  icon_128x128.png icon_128x128@2x.png \
  icon_256x256.png icon_256x256@2x.png \
  icon_512x512.png icon_512x512@2x.png; do
  if [[ ! -s "$ICONSET/$icon" ]]; then
    echo "Icon generation failed: $ICONSET/$icon is missing or empty" >&2
    exit 1
  fi
done

iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
if [[ ! -s "$APP_DIR/Contents/Resources/AppIcon.icns" ]]; then
  echo "Icon packaging failed: AppIcon.icns is missing or empty" >&2
  exit 1
fi

# Ad-hoc signing keeps the bundle internally consistent. The workflow can
# replace this with Developer ID signing later without changing the app.
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ROOT_DIR/dist/MaosVPN-macOS-10.15-Intel.zip"

DMG_ROOT="$ROOT_DIR/.build/dmg-root"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
cp -R "$APP_DIR" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "Maos VPN" -srcfolder "$DMG_ROOT" -ov -format UDZO "$ROOT_DIR/dist/MaosVPN-macOS-10.15-Intel.dmg"

cd "$ROOT_DIR/dist"
shasum -a 256 MaosVPN-macOS-10.15-Intel.zip MaosVPN-macOS-10.15-Intel.dmg > SHA256SUMS.txt

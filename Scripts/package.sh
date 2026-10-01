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
test -s "$ROOT_DIR/Resources/AppIcon.png"
swift "$ROOT_DIR/Scripts/generate_icon.swift" "$ROOT_DIR/Resources/AppIcon.png" "$ICONSET"

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
DMG_BACKGROUND="$ROOT_DIR/.build/dmg-background.png"
DMG_RW="$ROOT_DIR/.build/MaosVPN-readwrite.dmg"
DMG_MOUNT=""
rm -rf "$DMG_ROOT"
rm -f "$DMG_RW" "$ROOT_DIR/dist/MaosVPN-macOS-10.15-Intel.dmg"
mkdir -p "$DMG_ROOT/.background"
cp -R "$APP_DIR" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
swift "$ROOT_DIR/Scripts/generate_dmg_background.swift" "$DMG_BACKGROUND"
cp "$DMG_BACKGROUND" "$DMG_ROOT/.background/background.png"

hdiutil create -volname "Maos VPN" -srcfolder "$DMG_ROOT" -ov -fs HFS+ -format UDRW "$DMG_RW"
ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW")"
DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk 'NR == 1 { print $1 }')"
DMG_MOUNT="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '/Apple_HFS/ { print $NF; exit }')"
if [[ -z "$DEVICE" || -z "$DMG_MOUNT" || ! -d "$DMG_MOUNT" ]]; then
  echo "Could not attach the read-write DMG" >&2
  exit 1
fi
cleanup_dmg() {
  if [[ -n "${DEVICE:-}" ]]; then
    hdiutil detach -force "$DEVICE" >/dev/null 2>&1 || true
  fi
}
trap cleanup_dmg EXIT
/usr/bin/chflags hidden "$DMG_MOUNT/.background" || true

LAYOUT_CREATED=false
for attempt in 1 2 3; do
  if /usr/bin/osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "Maos VPN"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {120, 120, 720, 480}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set text size of theViewOptions to 13
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "Maos VPN.app" of container window to {150, 185}
    set position of item "Applications" of container window to {450, 185}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
  then
    LAYOUT_CREATED=true
    break
  fi
  sleep 2
done

if [[ "$LAYOUT_CREATED" == true ]]; then
  echo "Custom DMG layout created"
else
  echo "::warning title=DMG layout::Finder could not save the custom layout; packaging a functional fallback DMG."
fi

sync

# Finder/diskimages-helper can briefly keep the mounted image busy on GitHub's
# macOS runners even after the window is closed. Close any remaining Finder
# window first, then retry a graceful detach before falling back to a forced
# unmount/detach sequence.
osascript -e 'tell application "Finder" to close every window whose name is "Maos VPN"' >/dev/null 2>&1 || true
sleep 1

DETACHED=false
for attempt in 1 2 3 4 5; do
  if hdiutil detach "$DEVICE" >/dev/null 2>&1; then
    DETACHED=true
    break
  fi
  sleep 2
done

if [[ "$DETACHED" != true ]]; then
  echo "DMG is still busy; forcing unmount before detach"
  diskutil unmountDisk force "$DEVICE" >/dev/null 2>&1 || true

  for attempt in 1 2 3 4 5; do
    if hdiutil detach -force "$DEVICE" >/dev/null 2>&1; then
      DETACHED=true
      break
    fi
    sleep 2
  done
fi

if [[ "$DETACHED" != true ]]; then
  echo "Failed to detach $DEVICE after retries" >&2
  hdiutil info >&2 || true
  exit 1
fi

DEVICE=""
trap - EXIT
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$ROOT_DIR/dist/MaosVPN-macOS-10.15-Intel.dmg"

cd "$ROOT_DIR/dist"
shasum -a 256 MaosVPN-macOS-10.15-Intel.zip MaosVPN-macOS-10.15-Intel.dmg > SHA256SUMS.txt

#!/bin/sh
set -eu
DESKPILOT_PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DESKPILOT_BUILD="$DESKPILOT_PROJECT/.build"
DESKPILOT_APP="$DESKPILOT_BUILD/DeskPilot.app"
DESKPILOT_ICONSET="$DESKPILOT_BUILD/AppIcon.iconset"
mkdir -p "$DESKPILOT_BUILD/cache" "$DESKPILOT_APP/Contents/MacOS" "$DESKPILOT_APP/Contents/Resources"
mkdir -p "$DESKPILOT_ICONSET"
for DESKPILOT_SIZE in 16 32 128 256 512; do
  sips -z "$DESKPILOT_SIZE" "$DESKPILOT_SIZE" "$DESKPILOT_PROJECT/Resources/AppIcon.png" --out "$DESKPILOT_ICONSET/icon_${DESKPILOT_SIZE}x${DESKPILOT_SIZE}.png" >/dev/null
  DESKPILOT_RETINA=$((DESKPILOT_SIZE * 2))
  sips -z "$DESKPILOT_RETINA" "$DESKPILOT_RETINA" "$DESKPILOT_PROJECT/Resources/AppIcon.png" --out "$DESKPILOT_ICONSET/icon_${DESKPILOT_SIZE}x${DESKPILOT_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$DESKPILOT_ICONSET" -o "$DESKPILOT_APP/Contents/Resources/AppIcon.icns"
xcrun clang -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=14.0 -c "$DESKPILOT_PROJECT/Sources/NativeSupport.m" -o "$DESKPILOT_BUILD/NativeSupport.o"
xcrun swiftc -swift-version 5 -O -whole-module-optimization -module-cache-path "$DESKPILOT_BUILD/cache" -target arm64-apple-macosx14.0 \
  -import-objc-header "$DESKPILOT_PROJECT/Sources/NativeSupport.h" \
  "$DESKPILOT_PROJECT"/Sources/*.swift "$DESKPILOT_BUILD/NativeSupport.o" \
  -framework Cocoa -framework ApplicationServices -framework Carbon -framework ServiceManagement \
  -o "$DESKPILOT_APP/Contents/MacOS/DeskPilotNative"
cat > "$DESKPILOT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>pl.deskpilot.native</string>
<key>CFBundleExecutable</key><string>DeskPilotNative</string>
<key>CFBundleName</key><string>DeskPilot</string>
<key>CFBundleDisplayName</key><string>DeskPilot</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleShortVersionString</key><string>0.2.5</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><false/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAccessibilityUsageDescription</key><string>DeskPilot reads and arranges windows on your chosen desktops.</string>
<key>NSAppDataUsageDescription</key><string>DeskPilot reads Chrome profile names and directory identifiers to keep each profile on its assigned desktop.</string>
</dict></plist>
PLIST
cp -R "$DESKPILOT_PROJECT/ThirdPartyNotices" "$DESKPILOT_APP/Contents/Resources/"
codesign --force --sign "${DESKPILOT_SIGNING_IDENTITY:--}" --identifier pl.deskpilot.native "$DESKPILOT_APP"
printf '%s\n' "$DESKPILOT_APP"

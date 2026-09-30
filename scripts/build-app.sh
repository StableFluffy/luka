#!/bin/bash
# Builds Luka.app into ./build.
#   --install  copy it to ~/Applications
#   --zip      build/Luka-<version>.zip
#   --dmg      build/Luka-<version>.dmg (drag-to-Applications disk image)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Luka
BIN="$(swift build -c release --show-bin-path)/Luka"
APP=build/Luka.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Luka"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - --timestamp=none "$APP"

if [ "${1:-}" = "--install" ]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/Luka.app
    cp -R "$APP" ~/Applications/
    echo "Installed ~/Applications/Luka.app"
elif [ "${1:-}" = "--zip" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    ZIP="build/Luka-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Packaged $ZIP"
elif [ "${1:-}" = "--dmg" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    DMG="build/Luka-$VERSION.dmg"
    STAGE=build/dmg
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
    hdiutil create -quiet -volname "Luka" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov build/dmg-rw.dmg
    MOUNT=$(hdiutil attach -nobrowse -noautoopen build/dmg-rw.dmg | awk -F'\t' '/Apple_HFS/ {print $NF}')
    SetFile -a C "$MOUNT" 2>/dev/null || true
    hdiutil detach -quiet "$MOUNT"
    hdiutil convert -quiet build/dmg-rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG"
    rm -rf "$STAGE" build/dmg-rw.dmg
    echo "Packaged $DMG"
else
    echo "Built $APP"
fi

#!/bin/bash
# Builds Luka.app into ./build.
#   (none)     build/Luka.app
#   --install  also copy it to ~/Applications
#   --zip      build/Luka-<version>.zip
#   --dmg      build/Luka-<version>.dmg (drag-to-Applications disk image)
#   --release  signed, notarized and stapled DMG + zip
#
# Signs with the first "Developer ID Application" identity in the keychain (override with
# LUKA_SIGN_IDENTITY), else ad hoc. --release also needs notary credentials saved once with
#   xcrun notarytool store-credentials luka-notary --apple-id <email> --team-id <TEAMID>
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Luka.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
IDENTITY="${LUKA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
NOTARY_PROFILE="${LUKA_NOTARY_PROFILE:-luka-notary}"

build_app() {
    # SwiftPM's swiftbuild engine stamps the deployment target as the SDK version, which makes
    # macOS run the app in compatibility mode (no Liquid Glass chrome). Pass the real SDK version.
    local minos sdk
    minos=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" Resources/Info.plist)
    sdk=$(xcrun --sdk macosx --show-sdk-version)
    local flags=(-c release --product Luka -Xlinker -platform_version -Xlinker macos -Xlinker "$minos" -Xlinker "$sdk")
    swift build "${flags[@]}"
    local bin
    bin="$(swift build "${flags[@]}" --show-bin-path)/Luka"

    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$bin" "$APP/Contents/MacOS/Luka"
    # Debug symbols record absolute build paths; strip them and make sure none are left.
    strip -S -x "$APP/Contents/MacOS/Luka"
    if LC_ALL=C grep -q -a -F "$HOME" "$APP/Contents/MacOS/Luka"; then
        echo "Build paths leaked into the binary" >&2
        exit 1
    fi
    if ! vtool -show-build "$APP/Contents/MacOS/Luka" | grep -q "sdk $sdk"; then
        echo "Binary is not stamped with SDK $sdk" >&2
        exit 1
    fi
    cp Resources/Info.plist "$APP/Contents/Info.plist"
    cp -R Resources/*.lproj "$APP/Contents/Resources/"
    cp Resources/AppIcon.icns "$APP/Contents/Resources/"

    if [ -n "$IDENTITY" ]; then
        codesign --force --options runtime --timestamp --entitlements Resources/Luka.entitlements --sign "$IDENTITY" "$APP"
        echo "Signed with $IDENTITY"
    else
        codesign --force --sign - --timestamp=none --entitlements Resources/Luka.entitlements "$APP"
    fi
}

make_zip() {
    ZIP="build/Luka-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
    echo "Packaged $ZIP"
}

make_dmg() {
    DMG="build/Luka-$VERSION.dmg"
    local stage=build/dmg
    rm -rf "$stage" "$DMG" build/dmg-rw.dmg
    mkdir -p "$stage"
    cp -R "$APP" "$stage/"
    ln -s /Applications "$stage/Applications"
    cp Resources/AppIcon.icns "$stage/.VolumeIcon.icns"
    hdiutil create -quiet -volname "Luka" -srcfolder "$stage" -fs HFS+ -format UDRW -ov build/dmg-rw.dmg
    local mount
    mount=$(hdiutil attach -nobrowse -noautoopen build/dmg-rw.dmg | awk -F'\t' '/Apple_HFS/ {print $NF}')
    SetFile -a C "$mount" 2>/dev/null || true
    hdiutil detach -quiet "$mount"
    hdiutil convert -quiet build/dmg-rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG"
    rm -rf "$stage" build/dmg-rw.dmg
    [ -n "$IDENTITY" ] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    echo "Packaged $DMG"
}

# Submits to Apple's notary service and waits; prints the log and fails if it isn't accepted.
notarize() {
    local file=$1 result id status
    echo "Notarizing $file…"
    result=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
    id=$(plutil -extract id raw - <<<"$result")
    status=$(plutil -extract status raw - <<<"$result")
    if [ "$status" != "Accepted" ]; then
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
        echo "Notarization $status ($id)" >&2
        exit 1
    fi
    echo "Notarized ($id)"
}

case "${1:-}" in
    --install)
        build_app
        mkdir -p ~/Applications
        rm -rf ~/Applications/Luka.app
        cp -R "$APP" ~/Applications/
        echo "Installed ~/Applications/Luka.app"
        ;;
    --zip)
        build_app
        make_zip
        ;;
    --dmg)
        build_app
        make_dmg
        ;;
    --release)
        if [ -z "$IDENTITY" ]; then
            echo "No Developer ID Application certificate in the keychain." >&2
            echo "Xcode › Settings › Accounts › Manage Certificates… › + › Developer ID Application" >&2
            exit 1
        fi
        if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
            echo "No notary credentials named $NOTARY_PROFILE. Save them once with:" >&2
            echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <email> --team-id <TEAMID>" >&2
            exit 1
        fi
        build_app
        # The app is notarized and stapled first so the copy inside the DMG and the zip
        # both launch cleanly offline; then the DMG itself.
        make_zip
        notarize "$ZIP"
        xcrun stapler staple "$APP"
        make_zip
        make_dmg
        notarize "$DMG"
        xcrun stapler staple "$DMG"
        spctl --assess --type execute --verbose "$APP"
        spctl --assess --type open --context context:primary-signature --verbose "$DMG"
        echo "Release ready: $DMG, $ZIP"
        ;;
    *)
        build_app
        echo "Built $APP"
        ;;
esac

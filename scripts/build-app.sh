#!/usr/bin/env bash
# Builds dist/Hush.app, a signed zip for the updater, and a DMG.
#   UNIVERSAL=1        build arm64 + x86_64
#   SIGN_IDENTITY=...  code-signing identity (default: "Hush Release", then Apple Development, then ad-hoc)
#   NO_DMG=1           skip the DMG
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Hush"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
cd "$ROOT"

if [ "${UNIVERSAL:-0}" = "1" ]; then ARCHS=(--arch arm64 --arch x86_64); else ARCHS=(--arch arm64); fi

swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: Icon Composer bundle → Assets.car (Liquid Glass on macOS 26+) and Hush.icns (older macOS).
ICON_TMP="$(mktemp -d)"
if xcrun actool Resources/Hush.icon --compile "$ICON_TMP" --app-icon Hush --platform macosx \
     --minimum-deployment-target 14.0 --output-partial-info-plist "$ICON_TMP/p.plist" >/dev/null 2>&1; then
    cp "$ICON_TMP/Assets.car" "$ICON_TMP/Hush.icns" "$APP/Contents/Resources/"
else
    cp Resources/Hush.icns "$APP/Contents/Resources/Hush.icns"
fi
rm -rf "$ICON_TMP"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    if security find-certificate -c "Hush Release" >/dev/null 2>&1; then
        SIGN_IDENTITY="Hush Release"
    else
        SIGN_IDENTITY="$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
    fi
fi
codesign --force --deep --options runtime --entitlements Resources/Hush.entitlements --sign "${SIGN_IDENTITY:--}" "$APP"

cd "$DIST"
rm -f "$APP_NAME.zip" "$APP_NAME.zip.sig"
ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip"
if [ -f "${HUSH_KEY:-$HOME/.config/hush/ed25519.key}" ]; then
    swift "$ROOT/scripts/release-key.swift" sign "$DIST/$APP_NAME.zip"
fi

if [ "${NO_DMG:-0}" != "1" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DIST/$APP_NAME.dmg"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$APP_NAME.dmg" >/dev/null
    rm -rf "$STAGE"
fi

echo "Built $APP (signed with: ${SIGN_IDENTITY:-ad-hoc})"

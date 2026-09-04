#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIGURATION=${CONFIGURATION:-release}
APP_DIR="/private/tmp/Window Columns.app"
VISIBLE_APP="$PROJECT_DIR/Window Columns.app"
INSTALL_DIR="/Applications/Window Columns.app"
# Ask the toolchain where its SDK is. This used to name a specific SDK version,
# which only existed on the machine the project was written on.
WINDOW_COLUMNS_SDK=${SDKROOT:-$(xcrun --show-sdk-path 2>/dev/null || true)}
if [ -z "$WINDOW_COLUMNS_SDK" ] || [ ! -d "$WINDOW_COLUMNS_SDK" ]; then
    echo "Could not locate the macOS SDK." >&2
    echo "Install the Apple Command Line Tools with: xcode-select --install" >&2
    exit 1
fi
WINDOW_COLUMNS_MODULE_CACHE="$PROJECT_DIR/.build/ModuleCache"

export SDKROOT="$WINDOW_COLUMNS_SDK"

# Fail early with something actionable rather than a compiler error.
if ! command -v swift >/dev/null 2>&1; then
    echo "swift not found. Install the Apple Command Line Tools: xcode-select --install" >&2
    exit 1
fi
export CLANG_MODULE_CACHE_PATH="$WINDOW_COLUMNS_MODULE_CACHE"

# An ad-hoc signature makes the bundle's designated requirement a bare cdhash,
# which changes on every rebuild and silently invalidates the Accessibility
# grant. A certificate keeps the requirement stable across builds, so the
# permission is granted once. See Scripts/create-signing-identity.sh.
# Note: no -v. The local certificate is deliberately left out of the trust
# settings, so it is a usable signing identity but not a "valid" one, and -v
# would filter it out.
IDENTITY_NAME=${WINDOW_COLUMNS_IDENTITY:-Window Columns Local Signing}
if security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY_NAME"; then
    SIGN_ID="$IDENTITY_NAME"
    STABLE_SIGNATURE=1
else
    SIGN_ID="-"
    STABLE_SIGNATURE=0
fi

# Hardened Runtime and timestamp are required by Apple Gatekeeper when signing
# with an Apple Developer ID certificate.
CODESIGN_EXTRA_FLAGS=""
if echo "$SIGN_ID" | grep -q "Developer ID Application:" || [ "${HARDENED_RUNTIME:-0}" = "1" ]; then
    CODESIGN_EXTRA_FLAGS="--options runtime --timestamp --entitlements $PROJECT_DIR/Resources/WindowColumns.entitlements"
fi

cd "$PROJECT_DIR"
swift build --disable-sandbox -c "$CONFIGURATION" --product WindowColumns
swift build --disable-sandbox -c "$CONFIGURATION" --product WindowColumnsGroupHost
BIN_DIR=$(swift build --disable-sandbox -c "$CONFIGURATION" --product WindowColumns --show-bin-path)

rm -rf "/private/tmp/Window Columns.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Helpers"
cp "$BIN_DIR/WindowColumns" "$APP_DIR/Contents/MacOS/WindowColumns"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon-v3.icns" "$APP_DIR/Contents/Resources/AppIcon-v3.icns"
cp "$PROJECT_DIR/Resources/AppIcon-v3-Light.png" "$APP_DIR/Contents/Resources/AppIcon-v3-Light.png"
cp "$PROJECT_DIR/Resources/AppIcon-v3-Dark.png" "$APP_DIR/Contents/Resources/AppIcon-v3-Dark.png"

slot=1
while [ "$slot" -le 9 ]; do
    HELPER_APP="$APP_DIR/Contents/Helpers/Window Group $slot.app"
    mkdir -p "$HELPER_APP/Contents/MacOS" "$HELPER_APP/Contents/Resources"
    cp "$BIN_DIR/WindowColumnsGroupHost" "$HELPER_APP/Contents/MacOS/WindowColumnsGroupHost"
    cp "$PROJECT_DIR/Resources/GroupIcons/Group$slot.icns" "$HELPER_APP/Contents/Resources/GroupIcon.icns"
    cp "$PROJECT_DIR/Resources/GroupHost-Info.plist" "$HELPER_APP/Contents/Info.plist"
    plutil -replace CFBundleDisplayName -string "Window Group $slot" "$HELPER_APP/Contents/Info.plist"
    plutil -replace CFBundleName -string "WindowGroup$slot" "$HELPER_APP/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string "com.adimaskil.WindowColumns.Group$slot" "$HELPER_APP/Contents/Info.plist"
    xattr -cr "$HELPER_APP"
    codesign --force --sign "$SIGN_ID" $CODESIGN_EXTRA_FLAGS "$HELPER_APP"
    slot=$((slot + 1))
done

xattr -cr "$APP_DIR"
codesign --force --sign "$SIGN_ID" $CODESIGN_EXTRA_FLAGS "$APP_DIR"
# File Provider may attach empty Finder metadata to the bundle immediately after
# signing. Clear root metadata while leaving signed contents untouched.
xattr -c "$APP_DIR"
ln -sfn "$INSTALL_DIR" "$VISIBLE_APP"

if [ "${INSTALL:-0}" = "1" ]; then
    # Accessibility is granted per bundle path, so the app has to live at one
    # stable location. Quit the running copy first: replacing a bundle under a
    # live process leaves the controller and its companions mismatched.
    # pkill rather than an Apple Event, so this never trips an Automation prompt.
    pkill -f "$INSTALL_DIR/Contents/" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$INSTALL_DIR/Contents/" >/dev/null 2>&1 || break
        sleep 0.3
    done
    rm -rf "$INSTALL_DIR"
    ditto "$APP_DIR" "$INSTALL_DIR"

    if [ "$STABLE_SIGNATURE" -eq 0 ]; then
        # This build's cdhash differs from the one the grant was recorded
        # against, so the existing permission can never match again. Clearing it
        # turns a switch that looks on but does nothing into an honest prompt.
        tccutil reset Accessibility com.adimaskil.WindowColumns >/dev/null 2>&1 || true
        echo "--------------------------------------------------------------" >&2
        echo "Signed ad-hoc, so the Accessibility grant cannot survive this" >&2
        echo "rebuild and has been cleared. You will be asked for it again." >&2
        echo "To grant it once and for all:  make signing-identity" >&2
        echo "--------------------------------------------------------------" >&2
    fi
    echo "$INSTALL_DIR"
else
    echo "$APP_DIR"
fi

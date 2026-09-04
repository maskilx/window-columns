#!/bin/sh
set -eu

# Notarizes Window Columns with Apple's Notary service and staples the ticket.
# Requires an Apple Developer ID Application certificate and notarytool credentials.
#
# Usage:
#   KEYCHAIN_PROFILE="my-profile" sh Scripts/notarize.sh [path/to/Window Columns.app]
# Or:
#   APPLE_ID="..." APPLE_PASSWORD="..." APPLE_TEAM_ID="..." sh Scripts/notarize.sh

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_PATH="${1:-/private/tmp/Window Columns.app}"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at $APP_PATH" >&2
    echo "Build it first with: make app" >&2
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "Error: xcrun not found. Command Line Tools required." >&2
    exit 1
fi

ZIP_PATH="/private/tmp/WindowColumns-notarization.zip"
rm -f "$ZIP_PATH"

echo "Creating notarization archive..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Submitting to Apple Notary service..."
if [ -n "${KEYCHAIN_PROFILE:-}" ]; then
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
    xcrun notarytool submit "$ZIP_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait
else
    echo "-------------------------------------------------------------------" >&2
    echo "Error: Notary credentials missing." >&2
    echo "Store credentials using: xcrun notarytool store-credentials --help" >&2
    echo "Then re-run with: KEYCHAIN_PROFILE=\"<profile-name>\" make notarize" >&2
    echo "-------------------------------------------------------------------" >&2
    rm -f "$ZIP_PATH"
    exit 1
fi

rm -f "$ZIP_PATH"

echo "Stapling notarization ticket to $APP_PATH..."
xcrun stapler staple "$APP_PATH"

echo "Validating Gatekeeper assessment..."
spctl -a -vvv -t install "$APP_PATH"

echo "Notarization and stapling complete! Gatekeeper will allow this build out of the box."

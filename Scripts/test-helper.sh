#!/bin/sh
set -eu

WINDOW_COLUMNS_TEST_DIR=$(mktemp -d /private/tmp/window-columns-helper-test.XXXXXX)
trap 'rm -rf "$WINDOW_COLUMNS_TEST_DIR"' EXIT HUP INT TERM
WINDOW_COLUMNS_TEST_APP="$WINDOW_COLUMNS_TEST_DIR/Test Group.app"
ditto "$1" "$WINDOW_COLUMNS_TEST_APP"
plutil -replace CFBundleIdentifier -string "com.adimaskil.WindowColumns.Tests.GroupHost.$$" \
    "$WINDOW_COLUMNS_TEST_APP/Contents/Info.plist"
codesign --force --sign - "$WINDOW_COLUMNS_TEST_APP"
swift run GroupHostIntegrationChecks "$WINDOW_COLUMNS_TEST_APP"

#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")
BASE_VERSION=${VERSION%%-*}

if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$'; then
    echo "VERSION must be a semantic beta version such as 0.1.0-beta.1" >&2
    exit 1
fi

for plist in "$PROJECT_DIR/Resources/Info.plist" "$PROJECT_DIR/Resources/GroupHost-Info.plist"; do
    plutil -lint "$plist" >/dev/null
    PLIST_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$plist")
    if [ "$PLIST_VERSION" != "$BASE_VERSION" ]; then
        echo "$plist has version $PLIST_VERSION; expected $BASE_VERSION from VERSION" >&2
        exit 1
    fi
done

if ! grep -Fq "## [$VERSION]" "$PROJECT_DIR/CHANGELOG.md"; then
    echo "CHANGELOG.md has no release entry for $VERSION" >&2
    exit 1
fi

echo "Release metadata is consistent for $VERSION."

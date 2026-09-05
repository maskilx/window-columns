#!/bin/sh
set -eu

# Command Line Tools ship Swift Testing outside SwiftPM's default framework
# search path. Use the selected toolchain for both compilation and loading.
WINDOW_COLUMNS_DEVELOPER_DIR=$(xcode-select -p)
for library in \
    "$WINDOW_COLUMNS_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library" \
    "$WINDOW_COLUMNS_DEVELOPER_DIR/Library/Developer" \
    "$WINDOW_COLUMNS_DEVELOPER_DIR/Library"; do
    if [ -d "$library/Frameworks/Testing.framework" ]; then
        exec swift test --disable-xctest \
            -Xswiftc -F -Xswiftc "$library/Frameworks" \
            -Xlinker -rpath -Xlinker "$library/Frameworks" \
            -Xlinker -rpath -Xlinker "$library/usr/lib" "$@"
    fi
done

exec swift test --disable-xctest "$@"

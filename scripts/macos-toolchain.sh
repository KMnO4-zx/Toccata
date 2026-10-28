#!/bin/bash
# Source before compiling or packaging. The SDK controls native macOS UI styling.
TOCCATA_MACOS_SDK_VERSION=26.5
TOCCATA_ACTIVE_MACOS_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
if [ "$TOCCATA_ACTIVE_MACOS_SDK_VERSION" != "$TOCCATA_MACOS_SDK_VERSION" ]; then
    printf 'macOS SDK %s is required; the selected toolchain uses %s. Select Xcode 26.5 before building.\n' \
        "$TOCCATA_MACOS_SDK_VERSION" "$TOCCATA_ACTIVE_MACOS_SDK_VERSION" >&2
    exit 1
fi
SDKROOT="$(xcrun --sdk "macosx$TOCCATA_MACOS_SDK_VERSION" --show-sdk-path)"
export SDKROOT

verify_toccata_macos_sdk() {
    local binary actual_sdks
    for binary in "$@"; do
        actual_sdks="$(xcrun vtool -show-build "$binary" | awk '$1 == "sdk" { print $2 }' | LC_ALL=C sort -u)"
        if [ "$actual_sdks" != "$TOCCATA_MACOS_SDK_VERSION" ]; then
            printf 'Wrong SDK in %s: expected %s, found %s. Rebuild with the pinned toolchain.\n' \
                "$binary" "$TOCCATA_MACOS_SDK_VERSION" "${actual_sdks:-unknown}" >&2
            return 1
        fi
    done
}

#!/bin/bash
# Sourced by build/release scripts. shared/app-version.json is the app version source.
TOCCATA_VERSION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOCCATA_VERSION="$(/usr/bin/plutil -extract version raw -o - "$TOCCATA_VERSION_ROOT/shared/app-version.json")"
TOCCATA_BUILD="$(/usr/bin/plutil -extract build raw -o - "$TOCCATA_VERSION_ROOT/shared/app-version.json")"
if [[ ! "$TOCCATA_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
   [[ ! "$TOCCATA_BUILD" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Invalid version or build in shared/app-version.json\n' >&2
    exit 1
fi
TOCCATA_CORE_VERSION="$(sed -n 's/^version = "\([^"]*\)"$/\1/p' "$TOCCATA_VERSION_ROOT/core/toccata-core/Cargo.toml")"
if [ "$TOCCATA_CORE_VERSION" != "$TOCCATA_VERSION" ]; then
    printf 'Version mismatch: app=%s core=%s\n' "$TOCCATA_VERSION" "$TOCCATA_CORE_VERSION" >&2
    exit 1
fi

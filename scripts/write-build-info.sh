#!/bin/bash
# Capture the source revision once at build time, including local source edits.
# This generated resource is ignored so it never makes a clean build dirty.
set -euo pipefail
BUILD_INFO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD_INFO_OUTPUT="$BUILD_INFO_ROOT/apps/toccata-studio/Resources/build-info.json"
BUILD_INFO_COMMIT=null
BUILD_INFO_DIRTY=false

# Source archives may have no Git metadata, or live inside an unrelated checkout.
# Never attribute those builds to a parent repository's revision.
if BUILD_INFO_GIT_ROOT="$(git -C "$BUILD_INFO_ROOT" rev-parse --show-toplevel 2>/dev/null)" &&
   [ "$(cd "$BUILD_INFO_GIT_ROOT" && pwd -P)" = "$BUILD_INFO_ROOT" ] &&
   BUILD_INFO_HEAD="$(git -C "$BUILD_INFO_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" &&
   [[ "$BUILD_INFO_HEAD" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] &&
   BUILD_INFO_STATUS="$(git -C "$BUILD_INFO_ROOT" status --porcelain --untracked-files=normal --ignore-submodules=none 2>/dev/null)"; then
    BUILD_INFO_COMMIT="\"$BUILD_INFO_HEAD\""
    if [ -n "$BUILD_INFO_STATUS" ]; then BUILD_INFO_DIRTY=true; fi
fi

mkdir -p "$(dirname "$BUILD_INFO_OUTPUT")"
BUILD_INFO_TEMP="$(mktemp "$BUILD_INFO_OUTPUT.XXXXXX")"
trap 'rm -f "$BUILD_INFO_TEMP"' EXIT
printf '{\n  "commit": %s,\n  "isDirty": %s\n}\n' "$BUILD_INFO_COMMIT" "$BUILD_INFO_DIRTY" > "$BUILD_INFO_TEMP"
# Preserve the modification time when nothing changed, avoiding needless rebuilds.
if ! cmp -s "$BUILD_INFO_TEMP" "$BUILD_INFO_OUTPUT"; then
    mv "$BUILD_INFO_TEMP" "$BUILD_INFO_OUTPUT"
fi
chmod 644 "$BUILD_INFO_OUTPUT"

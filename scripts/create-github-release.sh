#!/bin/bash
# Invoked only by the manually dispatched release workflow, never by local packaging.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
: "${GH_REPO:?Missing GitHub repository}"
: "${RELEASE_TAG:?Missing explicit release version}"
: "${RELEASE_MODE:?Choose draft or publish explicitly}"
: "${RELEASE_COMMIT:?Missing reviewed source commit}"

EXPECTED_VERSION="$(python3 -c 'import json; print(json.load(open("shared/app-version.json"))["version"])')"
[[ "$EXPECTED_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
test "$RELEASE_TAG" = "v$EXPECTED_VERSION"
case "$RELEASE_MODE" in draft|publish) ;; *) exit 2 ;; esac
[[ "$RELEASE_COMMIT" =~ ^[a-f0-9]{40}$ ]]
test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"
NOTES="docs/releases/$RELEASE_TAG.md"
test -s "$NOTES"
DMG="Toccata-$EXPECTED_VERSION-arm64.dmg"
test -s "dist/$DMG"
test -s "dist/$DMG.sha256"
(
    cd dist
    shasum -a 256 -c "$DMG.sha256"
)

# Never move an existing tag or overwrite an already reviewed release.
# A failed upload leaves a draft for inspection; retries must be resolved explicitly.
RELEASES_JSON="$(gh api --paginate "repos/$GH_REPO/releases?per_page=100" --jq '.[].tag_name')"
if printf '%s\n' "$RELEASES_JSON" | grep -Fxq "$RELEASE_TAG"; then
    printf 'Release %s already exists. Review its draft/assets on GitHub; no overwrite performed.\n' "$RELEASE_TAG" >&2
    exit 1
fi
TAGS="$(gh api --paginate "repos/$GH_REPO/git/matching-refs/tags/$RELEASE_TAG" --jq '.[].ref')"
if printf '%s\n' "$TAGS" | grep -Fxq "refs/tags/$RELEASE_TAG"; then
    printf 'Tag %s already exists. Choose a new release version; no tag moved.\n' "$RELEASE_TAG" >&2
    exit 1
fi

gh release create "$RELEASE_TAG" "dist/$DMG" "dist/$DMG.sha256" \
    --target "$RELEASE_COMMIT" --title "Toccata $RELEASE_TAG" --notes-file "$NOTES" --draft
if [ "$RELEASE_MODE" = publish ]; then
    gh release edit "$RELEASE_TAG" --draft=false --latest
fi
gh release view "$RELEASE_TAG" --json url,isDraft,tagName

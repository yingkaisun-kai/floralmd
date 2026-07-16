#!/bin/bash
# Build, sign, and prepare a FloralMD release locally.
#
# Usage: FLORALMD_FEED_DIR=/path/to/feed-checkout ./scripts/release.sh [--publish]
#
# By default this script only creates local artifacts and updates the local feed
# checkout. --publish explicitly authorizes creation of the GitHub Release; the
# feed commit and push always remain manual review steps.

set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=false
case "${1:-}" in
    "") ;;
    --publish) PUBLISH=true ;;
    *) echo "Usage: $0 [--publish]" >&2; exit 2 ;;
esac

FEED_DIR="${FLORALMD_FEED_DIR:-}"
if [ -z "$FEED_DIR" ] || ! git -C "$FEED_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: FLORALMD_FEED_DIR must point to a checkout of the feed branch." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)"
REPOSITORY="${FLORALMD_REPOSITORY:-yingkaisun-kai/floralmd}"
DMG="build/FloralMD-${VERSION}.dmg"

VALIDATE_ARGS=(--version "$VERSION" --tag "v${VERSION}" --build "$BUILD")
if git cat-file -e HEAD^:Info.plist 2>/dev/null; then
    PREVIOUS_VERSION="$(git show HEAD^:Info.plist | plutil -extract CFBundleShortVersionString raw -o - -)"
    PREVIOUS_BUILD="$(git show HEAD^:Info.plist | plutil -extract CFBundleVersion raw -o - -)"
    VALIDATE_ARGS+=(--previous-build "$PREVIOUS_BUILD")
    if python3 scripts/validate-release-version.py \
        --version "$PREVIOUS_VERSION" --tag "v${PREVIOUS_VERSION}" \
        --build "$PREVIOUS_BUILD" >/dev/null 2>&1; then
        VALIDATE_ARGS+=(--previous-version "$PREVIOUS_VERSION")
    fi
fi
python3 scripts/validate-release-version.py "${VALIDATE_ARGS[@]}"

# ── Build ────────────────────────────────────────────────────────────────────
echo "Preparing FloralMD ${VERSION} (build ${BUILD})"
./scripts/build-app.sh --variant production

rm -f "$DMG" "build/FloralMD ${VERSION}.dmg"
create-dmg build/FloralMD.app build/ || true
DMG_SRC="$(find build -maxdepth 1 -name 'FloralMD*.dmg' -print -quit)"
if [ -z "$DMG_SRC" ]; then
    echo "Error: create-dmg produced no DMG." >&2
    exit 1
fi
if [ "$DMG_SRC" != "$DMG" ]; then
    mv "$DMG_SRC" "$DMG"
fi
hdiutil verify "$DMG"
shasum -a 256 "$DMG" > "build/FloralMD-${VERSION}.sha256"

SIGN_UPDATE="$(find .build -name sign_update -type f -print -quit)"
if [ -z "$SIGN_UPDATE" ]; then
    echo "Error: Sparkle sign_update was not found." >&2
    exit 1
fi

if [ -n "${FLORALMD_SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    SIG_OUTPUT="$(printf '%s' "$FLORALMD_SPARKLE_ED_PRIVATE_KEY" | \
        "$SIGN_UPDATE" --ed-key-file - "$DMG")"
else
    SIG_OUTPUT="$("$SIGN_UPDATE" --account floralmd "$DMG")"
fi
ED_SIGNATURE="$(printf '%s\n' "$SIG_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
FILE_LENGTH="$(printf '%s\n' "$SIG_OUTPUT" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
if [ -z "$ED_SIGNATURE" ] || [ -z "$FILE_LENGTH" ]; then
    echo "Error: could not parse Sparkle signature output." >&2
    exit 1
fi

ASSET_URL="https://github.com/${REPOSITORY}/releases/download/v${VERSION}/FloralMD-${VERSION}.dmg"
DESCRIPTION_FILE="$(mktemp)"
NOTES_FILE="$(mktemp)"
trap 'rm -f "$DESCRIPTION_FILE" "$NOTES_FILE"' EXIT
python3 scripts/changelog-to-html.py "$VERSION" > "$DESCRIPTION_FILE"
python3 scripts/extract-release-notes.py "$VERSION" > "$NOTES_FILE"
if [ ! -s "$NOTES_FILE" ]; then
    echo "See the CHANGELOG for details." > "$NOTES_FILE"
fi

if [ ! -f "$FEED_DIR/appcast.xml" ]; then
    cp scripts/appcast-template.xml "$FEED_DIR/appcast.xml"
fi
python3 scripts/update-appcast.py \
    --appcast "$FEED_DIR/appcast.xml" \
    --version "$VERSION" \
    --build "$BUILD" \
    --url "$ASSET_URL" \
    --signature "$ED_SIGNATURE" \
    --length "$FILE_LENGTH" \
    --pub-date "$(date -u '+%a, %d %b %Y %H:%M:%S +0000')" \
    --description-file "$DESCRIPTION_FILE"

if [ "$PUBLISH" = true ]; then
    gh release create "v${VERSION}" \
        "$DMG" "build/FloralMD-${VERSION}.sha256" \
        --title "FloralMD ${VERSION}" \
        --notes-file "$NOTES_FILE" \
        --latest
fi

echo "Prepared $DMG and $FEED_DIR/appcast.xml."
echo "Review and commit the feed change separately; this script never pushes it."

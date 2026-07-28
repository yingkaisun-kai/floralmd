#!/bin/bash
# Create the DMG once from the already-signed and stapled app.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <FloralMD.app> <output.dmg>" >&2
    exit 2
fi

APP="$1"
DMG="$2"
[ -d "$APP" ] || { echo "Error: app bundle does not exist." >&2; exit 1; }

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/floralmd-dmg.XXXXXX")"
cleanup() {
    rm -rf "$STAGE"
}
trap cleanup EXIT

ditto "$APP" "${STAGE}/FloralMD.app"
ln -s /Applications "${STAGE}/Applications"
mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil create \
    -volname FloralMD \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

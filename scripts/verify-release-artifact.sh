#!/bin/bash
# Strict evidence gates for signed/notarized FloralMD release artifacts.

set -euo pipefail

usage() {
    echo "usage: $0 signed-app <app> | notarized-app <app> | final-dmg <dmg> <sha256> | stapled <artifact> | checksum <artifact> <sha256>" >&2
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

signature_details() {
    codesign -dvvv "$1" 2>&1
}

require_developer_id() {
    local details
    details="$(signature_details "$1")"
    grep -q '^Authority=Developer ID Application:' <<< "$details" ||
        fail "artifact is not signed with Developer ID Application."
}

require_runtime_and_timestamp() {
    local details
    details="$(signature_details "$1")"
    grep -Eq '^CodeDirectory .*flags=.*runtime' <<< "$details" ||
        fail "signed code does not enable hardened runtime."
    grep -Eq '^Timestamp=.+$' <<< "$details" ||
        fail "signed code has no secure timestamp."
    grep -q '^Timestamp=none$' <<< "$details" &&
        fail "signed code has no secure timestamp."
    # The expected false result from the negative grep above must not become
    # this function's status under `set -e`.
    return 0
}

require_no_get_task_allow() {
    local code_path="$1"
    local entitlements
    entitlements="$(mktemp "${TMPDIR:-/tmp}/floralmd-entitlements.XXXXXX")"
    if codesign -d --entitlements :- "$code_path" >"$entitlements" 2>/dev/null; then
        if plutil -p "$entitlements" 2>/dev/null |
            grep -Eq '"com\.apple\.security\.get-task-allow"[[:space:]]*=>[[:space:]]*(true|1)'; then
            rm -f "$entitlements"
            fail "get-task-allow is enabled in signed code."
        fi
        rm -f "$entitlements"
    else
        rm -f "$entitlements"
    fi
}

verify_signed_app() {
    local app="$1"
    [ -d "$app" ] || fail "app bundle does not exist."
    codesign --verify --deep --strict "$app" ||
        fail "strict nested code-signature verification failed."
    require_no_get_task_allow "$app"
    require_runtime_and_timestamp "$app"
    require_developer_id "$app"
    while IFS= read -r -d '' code_path; do
        if codesign -d "$code_path" >/dev/null 2>&1; then
            require_no_get_task_allow "$code_path"
            require_runtime_and_timestamp "$code_path"
        fi
    done < <(
        find "$app" \
            \( -type d \( -name '*.app' -o -name '*.appex' -o -name '*.xpc' -o -name '*.framework' \) \
            -o -type f -perm -111 \) \
            -print0
    )
}

case "${1:-}" in
    signed-app)
        [ "$#" -eq 2 ] || { usage; exit 2; }
        verify_signed_app "$2"
        ;;
    notarized-app)
        [ "$#" -eq 2 ] || { usage; exit 2; }
        verify_signed_app "$2"
        xcrun stapler validate "$2" >/dev/null ||
            fail "app has no valid stapled notarization ticket."
        spctl --assess --type execute --verbose=4 "$2" >/dev/null ||
            fail "Gatekeeper rejected the app."
        ;;
    final-dmg)
        [ "$#" -eq 3 ] || { usage; exit 2; }
        DMG="$2"
        CHECKSUM="$3"
        [ -f "$DMG" ] || fail "DMG does not exist."
        [ -f "$CHECKSUM" ] || fail "SHA-256 manifest does not exist."
        hdiutil verify "$DMG" >/dev/null || fail "DMG verification failed."
        codesign --verify --strict "$DMG" ||
            fail "DMG code-signature verification failed."
        require_developer_id "$DMG"
        DETAILS="$(signature_details "$DMG")"
        grep -Eq '^Timestamp=.+$' <<< "$DETAILS" ||
            fail "DMG has no secure timestamp."
        grep -q '^Timestamp=none$' <<< "$DETAILS" &&
            fail "DMG has no secure timestamp."
        xcrun stapler validate "$DMG" >/dev/null ||
            fail "DMG has no valid stapled notarization ticket."
        spctl --assess --type open --context context:primary-signature \
            --verbose=4 "$DMG" >/dev/null ||
            fail "Gatekeeper rejected the DMG."
        (
            cd "$(dirname "$CHECKSUM")"
            shasum -a 256 -c "$(basename "$CHECKSUM")" >/dev/null
        ) || fail "DMG bytes do not match the SHA-256 manifest."
        ;;
    stapled)
        [ "$#" -eq 2 ] || { usage; exit 2; }
        xcrun stapler validate "$2" >/dev/null ||
            fail "artifact has no valid stapled notarization ticket."
        ;;
    checksum)
        [ "$#" -eq 3 ] || { usage; exit 2; }
        (
            cd "$(dirname "$3")"
            shasum -a 256 -c "$(basename "$3")" >/dev/null
        ) || fail "artifact bytes do not match the SHA-256 manifest."
        ;;
    *)
        usage
        exit 2
        ;;
esac

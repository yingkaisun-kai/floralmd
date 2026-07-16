#!/bin/bash
# Build an isolated local Debug app or the production app used by Release CI.
#
# Local default:
#   ./scripts/build-app.sh
#   -> build/FloralMD-Debug.app
#
# Quick Look debugging (independent extension identity):
#   ./scripts/build-app.sh --with-quick-look
#
# Release workflow only:
#   ./scripts/build-app.sh --variant production
#   -> build/FloralMD.app

set -euo pipefail
cd "$(dirname "$0")/.."

VARIANT="debug"
WITH_QUICK_LOOK=false

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --variant)
            [ "$#" -ge 2 ] || { echo "Error: --variant requires debug or production." >&2; exit 2; }
            VARIANT="$2"
            shift 2
            ;;
        --with-quick-look)
            WITH_QUICK_LOOK=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$VARIANT" in
    debug)
        APP_NAME="FloralMD-Debug"
        BUNDLE_ID="com.yingkaisun.floralmd.debug"
        BUNDLE="build/${APP_NAME}.app"
        BUILD_CONFIGURATION="debug"
        BUNDLE_EXECUTABLE="floralmd-debug"
        INFO_PLIST="Resources/Debug/Info.plist"
        QUICK_LOOK_NAME="FloralMD-Debug-QuickLook"
        QUICK_LOOK_BUNDLE_ID="com.yingkaisun.floralmd.debug.quicklook"
        QUICK_LOOK_BUNDLE_EXECUTABLE="floralmd-debug-quicklook"
        QUICK_LOOK_INFO_PLIST="Resources/Debug/QuickLook-Info.plist"
        INCLUDE_QUICK_LOOK="$WITH_QUICK_LOOK"
        INCLUDE_SPARKLE=false
        ;;
    production)
        APP_NAME="FloralMD"
        BUNDLE_ID="com.yingkaisun.floralmd"
        BUNDLE="build/${APP_NAME}.app"
        BUILD_CONFIGURATION="release"
        BUNDLE_EXECUTABLE="floralmd"
        INFO_PLIST="Info.plist"
        QUICK_LOOK_NAME="FloralMDQuickLook"
        QUICK_LOOK_BUNDLE_ID="com.yingkaisun.floralmd.quicklook"
        QUICK_LOOK_BUNDLE_EXECUTABLE="FloralMDQuickLook"
        QUICK_LOOK_INFO_PLIST="Resources/QuickLook/Info.plist"
        INCLUDE_QUICK_LOOK=true
        INCLUDE_SPARKLE=true
        ;;
    *)
        echo "Error: --variant must be debug or production." >&2
        exit 2
        ;;
esac

SOURCE_EXECUTABLE="floralmd"
SOURCE_QUICK_LOOK_EXECUTABLE="FloralMDQuickLook"
QUICK_LOOK_BUNDLE="${BUNDLE}/Contents/PlugIns/${QUICK_LOOK_NAME}.appex"

build_swift() {
    FLORALMD_BUILD_VARIANT="$VARIANT" swift build -c "$BUILD_CONFIGURATION" "$@" 2>&1 | tail -3
}

echo "Building ${VARIANT} app binary..."
if [ "$VARIANT" = "production" ]; then
    build_swift
else
    build_swift --product floralmd
    if [ "$INCLUDE_QUICK_LOOK" = true ]; then
        echo "Building isolated Debug Quick Look extension..."
        build_swift --product FloralMDQuickLook
    fi
fi

# SwiftPM's generated SwiftMath accessor looks beside Bundle.main by default.
# A sealed macOS app may contain only Contents/ at the bundle root, so point the
# accessor at Contents/Resources and relink when the generated source is fresh.
SWIFTMATH_ACCESSOR="$(find .build -path "*/${BUILD_CONFIGURATION}/SwiftMath.build/DerivedSources/resource_bundle_accessor.swift" -print -quit)"
if [ -z "$SWIFTMATH_ACCESSOR" ]; then
    echo "Error: SwiftMath resource accessor not found after ${VARIANT} build." >&2
    exit 1
fi
if grep -q 'Bundle.main.bundleURL' "$SWIFTMATH_ACCESSOR"; then
    echo "Relinking SwiftMath with standard app resource lookup..."
    sed -i '' 's/Bundle\.main\.bundleURL/Bundle.main.resourceURL!/g' "$SWIFTMATH_ACCESSOR"
    if [ "$VARIANT" = "production" ]; then
        build_swift
    else
        build_swift --product floralmd
        if [ "$INCLUDE_QUICK_LOOK" = true ]; then
            build_swift --product FloralMDQuickLook
        fi
    fi
fi

echo "Creating ${APP_NAME}.app bundle..."
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"

cp ".build/${BUILD_CONFIGURATION}/${SOURCE_EXECUTABLE}" \
    "${BUNDLE}/Contents/MacOS/${BUNDLE_EXECUTABLE}"
cp "$INFO_PLIST" "${BUNDLE}/Contents/Info.plist"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"

# Debug uses an allowlisted plist with no document types or Sparkle keys, while
# inheriting only the product version/build number from the production plist.
if [ "$VARIANT" = "debug" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" \
        "${BUNDLE}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_BUILD}" \
        "${BUNDLE}/Contents/Info.plist"
fi

cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"
cp LICENSE NOTICE "${BUNDLE}/Contents/Resources/"
for localization in Resources/*.lproj; do
    cp -R "$localization" "${BUNDLE}/Contents/Resources/"
done
# InfoPlist.strings overrides the main plist when Finder resolves an app name.
# Overlay the variant-specific files after copying the shared localizations so
# Debug never inherits the production display name.
if [ "$VARIANT" = "debug" ]; then
    for localization in Resources/Debug/*.lproj; do
        cp -R "$localization" "${BUNDLE}/Contents/Resources/"
    done
fi

if [ "$INCLUDE_QUICK_LOOK" = true ]; then
    echo "Embedding ${QUICK_LOOK_NAME} extension..."
    mkdir -p "${QUICK_LOOK_BUNDLE}/Contents/MacOS" "${QUICK_LOOK_BUNDLE}/Contents/Resources"
    cp ".build/${BUILD_CONFIGURATION}/${SOURCE_QUICK_LOOK_EXECUTABLE}" \
        "${QUICK_LOOK_BUNDLE}/Contents/MacOS/${QUICK_LOOK_BUNDLE_EXECUTABLE}"
    cp "$QUICK_LOOK_INFO_PLIST" "${QUICK_LOOK_BUNDLE}/Contents/Info.plist"
    # An .appex is a separate bundle and does not reliably inherit the host
    # icon. Ship it explicitly so IconServices never needs a cached fallback.
    cp Resources/AppIcon.icns "${QUICK_LOOK_BUNDLE}/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" \
        "${QUICK_LOOK_BUNDLE}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_BUILD}" \
        "${QUICK_LOOK_BUNDLE}/Contents/Info.plist"
fi

echo "Compiling asset catalog..."
ACTOOL="$(xcrun --find actool 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer/usr/bin/actool)"
"$ACTOOL" Resources/Assets.xcassets \
    --compile "${BUNDLE}/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$(mktemp)" \
    >/dev/null

if [ "$INCLUDE_SPARKLE" = true ]; then
    echo "Embedding Sparkle.framework..."
    mkdir -p "${BUNDLE}/Contents/Frameworks"
    SPARKLE_FW="$(find .build -type d -name 'Sparkle.framework' | grep -v '\.dSYM' | head -1)"
    if [ -z "$SPARKLE_FW" ]; then
        echo "Error: Sparkle.framework not found after production build." >&2
        exit 1
    fi
    cp -R "$SPARKLE_FW" "${BUNDLE}/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "${BUNDLE}/Contents/MacOS/${BUNDLE_EXECUTABLE}" 2>/dev/null || true
fi

echo "Copying SwiftPM resource bundles..."
for resource_bundle in ".build/${BUILD_CONFIGURATION}"/*.bundle; do
    if [ -e "$resource_bundle" ]; then
        cp -R "$resource_bundle" "${BUNDLE}/Contents/Resources/"
    fi
done

echo "Code signing..."
if [ "$INCLUDE_SPARKLE" = true ]; then
    codesign --force --deep --sign - "${BUNDLE}/Contents/Frameworks/Sparkle.framework"
fi
if [ "$INCLUDE_QUICK_LOOK" = true ]; then
    codesign --force --sign - \
        --identifier "$QUICK_LOOK_BUNDLE_ID" \
        --entitlements Resources/QuickLook/FloralMDQuickLook.entitlements \
        "$QUICK_LOOK_BUNDLE"
fi
# Do not use --deep here: the nested extension was signed above with its
# sandbox entitlements, and recursive signing would silently strip them.
codesign --force --sign - --identifier "$BUNDLE_ID" "$BUNDLE"

echo "Verifying sealed bundle and variant identity..."
codesign --verify --deep --strict "$BUNDLE"
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${BUNDLE}/Contents/Info.plist")"
ACTUAL_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "${BUNDLE}/Contents/Info.plist")"
ACTUAL_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${BUNDLE}/Contents/Info.plist")"
BINARY_STRINGS="$(strings "${BUNDLE}/Contents/MacOS/${BUNDLE_EXECUTABLE}")"
[ "$ACTUAL_BUNDLE_ID" = "$BUNDLE_ID" ] || { echo "Error: wrong bundle identifier." >&2; exit 1; }
[ "$ACTUAL_NAME" = "$APP_NAME" ] || { echo "Error: wrong display name." >&2; exit 1; }
[ "$ACTUAL_EXECUTABLE" = "$BUNDLE_EXECUTABLE" ] || { echo "Error: wrong executable name." >&2; exit 1; }

# Finder and Launch Services prefer localized InfoPlist.strings values over the
# main plist, so validate the signed resources instead of trusting only the
# unlocalized dictionary above.
for localized_info in "${BUNDLE}"/Contents/Resources/*.lproj/InfoPlist.strings; do
    [ -e "$localized_info" ] || continue
    LOCALIZED_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$localized_info")"
    LOCALIZED_DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$localized_info")"
    [ "$LOCALIZED_NAME" = "$APP_NAME" ] || {
        echo "Error: wrong localized bundle name in ${localized_info}." >&2
        exit 1
    }
    [ "$LOCALIZED_DISPLAY_NAME" = "$APP_NAME" ] || {
        echo "Error: wrong localized display name in ${localized_info}." >&2
        exit 1
    }
done

if [ "$VARIANT" = "debug" ]; then
    for forbidden_key in CFBundleDocumentTypes SUFeedURL SUPublicEDKey; do
        if /usr/libexec/PlistBuddy -c "Print :${forbidden_key}" "${BUNDLE}/Contents/Info.plist" >/dev/null 2>&1; then
            echo "Error: Debug plist contains forbidden key ${forbidden_key}." >&2
            exit 1
        fi
    done
    if [ -e "${BUNDLE}/Contents/Frameworks/Sparkle.framework" ] || \
       otool -L "${BUNDLE}/Contents/MacOS/${BUNDLE_EXECUTABLE}" | grep -q 'Sparkle.framework'; then
        echo "Error: Debug bundle links or embeds Sparkle." >&2
        exit 1
    fi
    if [ "$INCLUDE_QUICK_LOOK" = false ] && [ -d "${BUNDLE}/Contents/PlugIns" ]; then
        echo "Error: normal Debug bundle unexpectedly contains a plug-in." >&2
        exit 1
    fi
    if grep -q 'Check for Updates' <<< "$BINARY_STRINGS"; then
        echo "Error: Debug binary contains the production update menu." >&2
        exit 1
    fi
else
    EXPECTED_FEED_URL="https://raw.githubusercontent.com/yingkaisun-kai/floralmd/feed/appcast.xml"
    ACTUAL_FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "${BUNDLE}/Contents/Info.plist")"
    ACTUAL_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${BUNDLE}/Contents/Info.plist")"
    [ "$ACTUAL_FEED_URL" = "$EXPECTED_FEED_URL" ] || {
        echo "Error: Production bundle has the wrong Sparkle feed URL." >&2
        exit 1
    }
    [ -n "$ACTUAL_PUBLIC_KEY" ] || {
        echo "Error: Production bundle has no Sparkle public key." >&2
        exit 1
    }
    if [ ! -d "${BUNDLE}/Contents/Frameworks/Sparkle.framework" ] || \
       ! otool -L "${BUNDLE}/Contents/MacOS/${BUNDLE_EXECUTABLE}" | grep -q 'Sparkle.framework'; then
        echo "Error: Production bundle does not link and embed Sparkle." >&2
        exit 1
    fi
    if ! grep -q 'Check for Updates' <<< "$BINARY_STRINGS"; then
        echo "Error: Production binary has no manual update menu." >&2
        exit 1
    fi
fi

if [ "$INCLUDE_QUICK_LOOK" = true ]; then
    ACTUAL_QUICK_LOOK_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${QUICK_LOOK_BUNDLE}/Contents/Info.plist")"
    ACTUAL_QUICK_LOOK_ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${QUICK_LOOK_BUNDLE}/Contents/Info.plist")"
    ACTUAL_QUICK_LOOK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${QUICK_LOOK_BUNDLE}/Contents/Info.plist")"
    ACTUAL_QUICK_LOOK_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${QUICK_LOOK_BUNDLE}/Contents/Info.plist")"
    [ "$ACTUAL_QUICK_LOOK_ID" = "$QUICK_LOOK_BUNDLE_ID" ] || {
        echo "Error: wrong Quick Look bundle identifier." >&2
        exit 1
    }
    [ "$ACTUAL_QUICK_LOOK_ICON" = "AppIcon" ] || {
        echo "Error: Quick Look extension does not declare AppIcon." >&2
        exit 1
    }
    [ "$ACTUAL_QUICK_LOOK_VERSION" = "$APP_VERSION" ] || {
        echo "Error: Quick Look extension version differs from the host app version." >&2
        exit 1
    }
    [ "$ACTUAL_QUICK_LOOK_BUILD" = "$APP_BUILD" ] || {
        echo "Error: Quick Look extension build differs from the host app build." >&2
        exit 1
    }
    [ -f "${QUICK_LOOK_BUNDLE}/Contents/Resources/AppIcon.icns" ] || {
        echo "Error: Quick Look extension is missing AppIcon.icns." >&2
        exit 1
    }
    cmp -s \
        "${BUNDLE}/Contents/Resources/AppIcon.icns" \
        "${QUICK_LOOK_BUNDLE}/Contents/Resources/AppIcon.icns" || {
        echo "Error: Quick Look extension icon differs from the host app icon." >&2
        exit 1
    }
fi

echo ""
echo "Done: ${BUNDLE}"
if [ "$VARIANT" = "debug" ]; then
    echo "Run this bundle in place. Do not copy it to /Applications/FloralMD.app."
    if [ "$INCLUDE_QUICK_LOOK" = true ]; then
        echo "Quick Look Debug identity: ${QUICK_LOOK_BUNDLE_ID}"
    fi
else
    echo "Production output is for the Release workflow; install user builds from GitHub Release DMGs."
fi

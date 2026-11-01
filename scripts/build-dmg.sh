#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Syntly"
VOLUME_NAME="Synt(ax)ly"
VERSION="0.1.0"
BUILD_UNIVERSAL=true
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

for arg in "$@"; do
    case "$arg" in
        --host)
            BUILD_UNIVERSAL=false
            ;;
        --universal)
            BUILD_UNIVERSAL=true
            ;;
        --sign=*)
            SIGNING_IDENTITY="${arg#*=}"
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

echo "=========================================="
echo "  Building ${APP_NAME} DMG Installer"
echo "=========================================="

# 1. Build the .app bundle
BUILD_APP_ARGS=()
if [ "$BUILD_UNIVERSAL" = true ]; then
    BUILD_APP_ARGS+=("--universal")
    ARCH_LABEL="Universal"
else
    ARCH_LABEL="$(uname -m)"
fi

if [ "$SIGNING_IDENTITY" != "-" ]; then
    BUILD_APP_ARGS+=("--sign=${SIGNING_IDENTITY}")
fi

echo "Step 1: Building ${APP_NAME}.app (${ARCH_LABEL})..."
"${SCRIPT_DIR}/build-app.sh" "${BUILD_APP_ARGS[@]}"

# 2. Prepare staging directory for DMG
DMG_STAGING_DIR="/tmp/syntly_dmg_staging"
DMG_NAME="${APP_NAME}-${VERSION}-${ARCH_LABEL}.dmg"

echo "Step 2: Preparing disk image staging directory..."
rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"

# Copy the app bundle
cp -R "${APP_NAME}.app" "$DMG_STAGING_DIR/"

# Create standard macOS drag-and-drop link to /Applications
ln -s /Applications "$DMG_STAGING_DIR/Applications"

# 3. Create compressed DMG
echo "Step 3: Creating compressed DMG (${DMG_NAME})..."
rm -f "${DMG_NAME}"
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${DMG_STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_NAME}"

# Clean staging
rm -rf "$DMG_STAGING_DIR"

# 4. Sign DMG if Developer ID identity is available
if [ "$SIGNING_IDENTITY" != "-" ]; then
    echo "Step 4: Signing ${DMG_NAME} with Developer ID..."
    codesign --force --sign "${SIGNING_IDENTITY}" "${DMG_NAME}"
fi

echo ""
echo "=========================================="
echo "✅ Successfully created DMG:"
echo "   $(pwd)/${DMG_NAME}"
ls -lh "${DMG_NAME}"
echo "=========================================="
echo ""
echo "Binary Architecture:"
file "${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
echo ""
echo "Distribution Notes:"
echo " • Universal binary supports BOTH Apple Silicon (M1/M2/M3/M4) and Intel Macs natively."
if [ "$SIGNING_IDENTITY" = "-" ]; then
    echo " • Signed with Ad-hoc signature. If downloaded from the internet, users can open it via:"
    echo "   Right-click Syntly.app -> Open -> Open, or run: xattr -cr /Applications/Syntly.app"
    echo " • To distribute frictionlessly without warnings, sign with your Apple Developer ID and notarize:"
    echo "   ./scripts/build-dmg.sh --sign=\"Developer ID Application: Your Name (TEAM_ID)\""
    echo "   xcrun notarytool submit ${DMG_NAME} --keychain-profile \"AC_PROFILE\" --wait"
    echo "   xcrun stapler staple ${DMG_NAME}"
else
    echo " • Signed with Developer ID. Next step: Notarize with Apple:"
    echo "   xcrun notarytool submit ${DMG_NAME} --keychain-profile \"AC_PROFILE\" --wait"
    echo "   xcrun stapler staple ${DMG_NAME}"
fi

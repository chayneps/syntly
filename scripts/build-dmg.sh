#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Syntly"
VOLUME_NAME="Synt(ax)ly"
VERSION="2.0.0"
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

# Add First Launch guide for Installation & Gatekeeper
cat << 'EOF' > "$DMG_STAGING_DIR/PLEASE READ - How to Install.txt"
========================================================================
             Synt(ax)ly — Installation & Setup Guide
========================================================================

STEP 1: INSTALLATION
------------------------------------------------------------------------
👉 Drag "Syntly.app" into the "Applications" folder shortcut right here.


STEP 2: OVERCOMING THE "UNKNOWN DEVELOPER" / MALWARE WARNING
------------------------------------------------------------------------
Because Synt(ax)ly is an open-source project without a paid $99/year
Apple Developer ID certificate, macOS Gatekeeper blocks it on first launch:

  "Apple could not verify 'Syntly.app' is free of malware"

This is because macOS defaults to "App Store & Known Developers".
On modern macOS (Sonoma & Sequoia), clicking "Open Anyway" often loops.

Use either method below to launch Synt(ax)ly in seconds:

METHOD 1: Instant Terminal Command (Recommended)
------------------------------------------------
1. Open Terminal (press ⌘ + Space, type "Terminal", press Return).
2. Copy and paste this command and press Return:

   xattr -cr /Applications/Syntly.app

3. Double-click Syntly.app in your Applications folder. It will open
   immediately with zero warnings!

Why this works: Web browsers (Safari, Chrome) add a hidden "quarantine"
attribute to downloaded files. The command above clears that tag so
macOS treats Syntly as a trusted local app.


METHOD 2: Unlock "Anywhere" in System Settings
----------------------------------------------
If you want your Mac to allow open-source apps without blocking:
1. Open Terminal and run:

   sudo spctl --master-disable

2. Enter your Mac login password when prompted.
3. Open System Settings -> Privacy & Security.
4. Under "Security" -> "Allow applications from", select "Anywhere".
5. Syntly.app will now open without any warnings.


STEP 3: GRANT ACCESSIBILITY PERMISSION (ONE-CLICK SETUP)
------------------------------------------------------------------------
To detect active text fields and display the real-time Manga Thinking
Bubble beside your typing cursor, Synt(ax)ly requires macOS Accessibility
permission:

1. Launch Synt(ax)ly. It runs quietly in your macOS menu bar (top-right
   of your screen near the clock).
2. Click the Synt(ax)ly menu bar icon.
3. Click the yellow warning:
   "⚠️ Grant Accessibility Access…"
   This immediately opens System Settings directly to Privacy & Security
   -> Accessibility.
4. Toggle ON the switch next to "Synt(ax)ly" (or click "+" and select
   /Applications/Syntly.app).


STEP 4: CONFIGURE YOUR AI MODEL & CLIPROXYAPI
------------------------------------------------------------------------
Synt(ax)ly connects to your preferred local or cloud AI models.

1. Click the Synt(ax)ly menu bar icon and choose "Settings…" (or press ⌘,).
2. Go to the "API & Model" tab.

Recommended Gateway — CLIProxyAPI (Zero-API-Key Setup):
-------------------------------------------------------
If you use CLIProxyAPI (https://github.com/router-for-me/CLIProxyAPI):
- Simply click the "CLI Proxy API (127.0.0.1:8317)" preset button.
- Syntly will AUTOMATICALLY read your existing Google, Gemini, or Claude
  credentials from ~/.cli-proxy-api/config.yaml — no manual API key copying!

Other Supported Backends:
-------------------------
- Kiro Gateway (https://github.com/jwadow/kiro-gateway): Route through your
  Kiro IDE subscription with Claude and frontier models.
- Ollama / LM Studio: 100% free and offline local inference.
- Google AI Studio (Gemini) / OpenAI / OpenRouter: Paste your API key.

Click "Test Connection" to benchmark latency, and you're ready to write!

========================================================================
100% Free & Open Source under the MIT License
Source Code & Releases: https://github.com/chayneps/syntly
========================================================================
EOF

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

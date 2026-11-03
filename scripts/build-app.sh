#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Syntly"
BUNDLE_ID="dev.syntly.app"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"

# Ensure AppIcon.icns is always kept up to date with assets/app_icon_1024.png
if [ -f "assets/app_icon_1024.png" ] && ([ ! -f "assets/AppIcon.icns" ] || [ "assets/app_icon_1024.png" -nt "assets/AppIcon.icns" ]); then
    echo "Generating AppIcon.icns from assets/app_icon_1024.png..."
    ICONSET_DIR="/tmp/Syntly_AppIcon.iconset"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"
    sips -z 16 16     assets/app_icon_1024.png --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
    sips -z 32 32     assets/app_icon_1024.png --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
    sips -z 32 32     assets/app_icon_1024.png --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
    sips -z 64 64     assets/app_icon_1024.png --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
    sips -z 128 128   assets/app_icon_1024.png --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
    sips -z 256 256   assets/app_icon_1024.png --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   assets/app_icon_1024.png --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
    sips -z 512 512   assets/app_icon_1024.png --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   assets/app_icon_1024.png --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
    sips -z 1024 1024 assets/app_icon_1024.png --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$ICONSET_DIR" --output assets/AppIcon.icns
    rm -rf "$ICONSET_DIR"
fi

BUILD_UNIVERSAL=false
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

for arg in "$@"; do
    case "$arg" in
        --universal)
            BUILD_UNIVERSAL=true
            ;;
        --sign=*)
            SIGNING_IDENTITY="${arg#*=}"
            ;;
    esac
done

if [ "$BUILD_UNIVERSAL" = true ]; then
    echo "Building ${APP_NAME} (Release Universal 2: Apple Silicon + Intel)..."
    swift build -c release --arch arm64 --arch x86_64
    BINARY_SOURCE=".build/apple/Products/Release/${APP_NAME}"
else
    echo "Building ${APP_NAME} (Release)..."
    swift build -c release
    BINARY_SOURCE=".build/release/${APP_NAME}"
fi

echo "Packaging ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BINARY_SOURCE}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

if [ -f "assets/AppIcon.icns" ]; then
    cp "assets/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi
if [ -f "assets/app_icon_1024.png" ]; then
    cp "assets/app_icon_1024.png" "${APP_BUNDLE}/Contents/Resources/app_icon_1024.png"
fi
if [ -f "assets/menu_bar_icon.png" ]; then
    cp "assets/menu_bar_icon.png" "${APP_BUNDLE}/Contents/Resources/menu_bar_icon.png"
fi

cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Synt(ax)ly</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026. All rights reserved.</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAppNap</key>
    <false/>
    <key>NSWritingToolsDisabled</key>
    <true/>
    <key>ApplePersistenceIgnoreState</key>
    <true/>
    <key>NSQuitAlwaysKeepsWindows</key>
    <false/>
</dict>
</plist>
EOF

if [ "$SIGNING_IDENTITY" != "-" ]; then
    echo "Signing ${APP_BUNDLE} with Developer ID (${SIGNING_IDENTITY}) and hardened runtime..."
    codesign --force --deep --options runtime --sign "${SIGNING_IDENTITY}" "${APP_BUNDLE}"
else
    echo "Signing ${APP_BUNDLE} with stable Designated Requirement (Ad-hoc)..."
    codesign --force --deep --sign - -r='designated => identifier "'"${BUNDLE_ID}"'"' "${APP_BUNDLE}"
fi

echo "✅ Created ${APP_BUNDLE} with native AppIcon. Run 'open ${APP_BUNDLE}' to launch!"

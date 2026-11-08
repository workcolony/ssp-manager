#!/bin/bash
# Builds SSPManager.app from the SwiftPM executable.
set -euo pipefail
cd "$(dirname "$0")/.."
APP_DIR="build/SSPManager.app"
swift build -c release
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/SSPManager "$APP_DIR/Contents/MacOS/SSPManager"
# SPM resource bundle (PluginCatalog.json) — beside the executable for Bundle.module
BUNDLE=$(ls -d .build/release/*.bundle 2>/dev/null | head -1 || true)
if [ -n "$BUNDLE" ]; then
    cp -R "$BUNDLE" "$APP_DIR/Contents/MacOS/"
fi
# Also copy into Resources so Bundle.main finds the catalog without relying on
# SPM's baked Bundle.module path under .build/.
if [ -f Sources/SSPManager/PluginCatalog.json ]; then
    cp Sources/SSPManager/PluginCatalog.json "$APP_DIR/Contents/Resources/PluginCatalog.json"
fi

# icon: source PNG -> iconset -> icns -> Resources/AppIcon.icns
ICON_SRC="icon ideas/ssp manager.png"
if [ -f "$ICON_SRC" ]; then
    rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ICON_SRC" --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) "$ICON_SRC" --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns build/AppIcon.iconset -o "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleName</key><string>SSP Manager</string>
<key>CFBundleIdentifier</key><string>com.bendymusic.ssp-manager</string>
<key>CFBundleVersion</key><string>0.1</string>
<key>CFBundleExecutable</key><string>SSPManager</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
echo "built $APP_DIR"

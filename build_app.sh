#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
echo "==> 编译 release..."
swift build -c release
mkdir -p build
STAGING_DIR="$(mktemp -d build/.package.XXXXXX)"
APP_DIR="$STAGING_DIR/EdgeHider.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/release/EdgeHider" "$APP_DIR/Contents/MacOS/"
# iconutil 使用标准 iconset；原始图标文件保持不变。
if [ -d "AppIcon.appiconset" ]; then
    ICON_DIR="$STAGING_DIR/AppIcon.iconset"
    mkdir -p "$ICON_DIR"
    cp AppIcon.appiconset/*.png "$ICON_DIR/"
    if [ -f "$ICON_DIR/icon_512@2x.png" ]; then
        mv "$ICON_DIR/icon_512@2x.png" "$ICON_DIR/icon_512x512@2x.png"
    fi
    if [ ! -f "$ICON_DIR/icon_512x512.png" ]; then
        cp "$ICON_DIR/icon_256x256@2x.png" "$ICON_DIR/icon_512x512.png"
    fi
    iconutil -c icns "$ICON_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>CFBundleName</key><string>EdgeHider</string>
<key>CFBundleDisplayName</key><string>EdgeHider</string>
<key>CFBundleIdentifier</key><string>com.edgehider.app</string>
<key>CFBundleVersion</key><string>1.1.4</string>
<key>CFBundleShortVersionString</key><string>1.1.4</string>
<key>CFBundleExecutable</key><string>EdgeHider</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHumanReadableCopyright</key><string>Doon</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
# 仅在新包完整构建、签名成功后替换，并保留旧包以便回退。
if [ -d build/EdgeHider.app ]; then
    BACKUP_DIR="$(mktemp -d build/previous.XXXXXX)"
    mv build/EdgeHider.app "$BACKUP_DIR/EdgeHider.app"
    echo "==> 旧版本备份: $BACKUP_DIR/EdgeHider.app"
fi
mv "$APP_DIR" build/EdgeHider.app
echo "==> 完成: build/EdgeHider.app"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
PROBE_DIR=/tmp/EdgeHiderFullscreenProbe
mkdir -p "$PROBE_DIR"
clang -fobjc-arc -framework AppKit -framework ApplicationServices Probe.m -o "$PROBE_DIR/probe"
for ROLE in target host; do
    APP_DIR="$PROBE_DIR/$ROLE.app"
    mkdir -p "$APP_DIR/Contents/MacOS"
    cp "$PROBE_DIR/probe" "$APP_DIR/Contents/MacOS/probe"
    cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.edgehider.probe.$ROLE</string>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundleName</key><string>EdgeHider Probe $ROLE</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
    codesign --force --sign - "$APP_DIR"
done
APP_DIR="../../build/EdgeHiderFullscreenProbe.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$PROBE_DIR/probe" "$APP_DIR/Contents/MacOS/probe"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.edgehider.fullscreenprobe</string>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundleName</key><string>EdgeHiderFullscreenProbe</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
printf 'Built: %s\n' "$PROBE_DIR"

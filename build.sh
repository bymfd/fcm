#!/bin/bash
# Build FCM.app (Universal: Intel + Apple Silicon)
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

APP="FCM.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

echo "Building universal binaries (Intel + Apple Silicon)..."
clang -O2 -arch arm64 -arch x86_64 -framework IOKit -o build-smc src/smc.c
swiftc -O -target x86_64-apple-macosx12.0 -framework Cocoa -o build-x86_64 src/main.swift
swiftc -O -target arm64-apple-macosx12.0 -framework Cocoa -o build-arm64 src/main.swift
lipo -create build-x86_64 build-arm64 -output "$APP/Contents/MacOS/FCM"
rm -f build-x86_64 build-arm64
mv build-smc "$APP/Contents/Resources/smc"

echo "Generating app icon..."
rm -rf build-icon.iconset
mkdir -p build-icon.iconset
sips -z 16 16 assets/mfc.png --out build-icon.iconset/icon_16x16.png >/dev/null
sips -z 32 32 assets/mfc.png --out build-icon.iconset/icon_16x16@2x.png >/dev/null
sips -z 32 32 assets/mfc.png --out build-icon.iconset/icon_32x32.png >/dev/null
sips -z 64 64 assets/mfc.png --out build-icon.iconset/icon_32x32@2x.png >/dev/null
sips -z 128 128 assets/mfc.png --out build-icon.iconset/icon_128x128.png >/dev/null
sips -z 256 256 assets/mfc.png --out build-icon.iconset/icon_128x128@2x.png >/dev/null
sips -z 256 256 assets/mfc.png --out build-icon.iconset/icon_256x256.png >/dev/null
sips -z 512 512 assets/mfc.png --out build-icon.iconset/icon_256x256@2x.png >/dev/null
sips -z 512 512 assets/mfc.png --out build-icon.iconset/icon_512x512.png >/dev/null
cp assets/mfc.png build-icon.iconset/icon_512x512@2x.png
iconutil -c icns build-icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build-icon.iconset

cp src/Info.plist "$APP/Contents/Info.plist"
cp src/helper.sh src/install.sh "$APP/Contents/Resources/"

echo "Done: $APP"

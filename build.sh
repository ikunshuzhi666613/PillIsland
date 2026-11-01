#!/bin/bash
# 重新编译并安装药丸灵动岛
set -e
cd "$(dirname "$0")"

APP="/Applications/PillIsland.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 媒体信息适配器（BSD 3-Clause，来自 ungive/mediaremote-adapter）
rm -rf "$APP/Contents/Resources/MediaRemoteAdapter"
cp -R MediaRemoteAdapter "$APP/Contents/Resources/MediaRemoteAdapter"

mkdir -p build
swiftc -O -swift-version 5 -target x86_64-apple-macos14.0 \
    -o build/PillIsland-x86_64 main.swift -framework Cocoa
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
    -o build/PillIsland-arm64 main.swift -framework Cocoa
lipo -create -output "$APP/Contents/MacOS/PillIsland" \
    build/PillIsland-x86_64 build/PillIsland-arm64

codesign --force --deep --sign "PillIsland Dev" "$APP"

echo "✅ 已编译并安装到 $APP"
echo "   重启药丸: pkill -f PillIsland.app; open $APP"

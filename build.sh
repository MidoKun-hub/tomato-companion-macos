#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
APP_DIR="$PROJECT_DIR/build/番茄伴伴.app"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
MODULE_CACHE_DIR="/private/tmp/tomato-swift-module-cache"
mkdir -p "$MODULE_CACHE_DIR"

if [[ ! -d "$SDK_PATH" ]]; then
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Assets/tomato-pet.png" "$APP_DIR/Contents/Resources/tomato-pet.png"
cp "$PROJECT_DIR/Assets/tomato-focus.png" "$APP_DIR/Contents/Resources/tomato-focus.png"
cp "$PROJECT_DIR/Assets/tomato-rest.png" "$APP_DIR/Contents/Resources/tomato-rest.png"
cp "$PROJECT_DIR/Assets/mascot-carrot.png" "$APP_DIR/Contents/Resources/mascot-carrot.png"
cp "$PROJECT_DIR/Assets/mascot-broccoli.png" "$APP_DIR/Contents/Resources/mascot-broccoli.png"
cp "$PROJECT_DIR/Assets/mascot-eggplant.png" "$APP_DIR/Contents/Resources/mascot-eggplant.png"
cp "$PROJECT_DIR/Assets/mascot-bell-pepper.png" "$APP_DIR/Contents/Resources/mascot-bell-pepper.png"
ruby "$PROJECT_DIR/make_icns.rb" "$PROJECT_DIR/AppIcon.iconset" "$APP_DIR/Contents/Resources/AppIcon.icns"
swiftc \
  -Onone \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -sdk "$SDK_PATH" \
  -target x86_64-apple-macosx13.0 \
  -framework AppKit \
  -framework QuartzCore \
  "$PROJECT_DIR/Sources/main.swift" \
  -o "$APP_DIR/Contents/MacOS/TomatoCompanion"
codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"

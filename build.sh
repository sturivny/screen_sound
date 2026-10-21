#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
APP="${1:-$PWD/build/ScreenSound.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/module-cache
xcrun swiftc -swift-version 5 -O -parse-as-library \
  -target arm64-apple-macosx15.0 -sdk "$SDK" \
  -module-cache-path "$PWD/build/module-cache" \
  Sources/*.swift -o "$APP/Contents/MacOS/ScreenSound"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns Assets/ScreenSound-icon.png "$APP/Contents/Resources/"
codesign --force --sign - --identifier local.screensound.recorder "$APP"
codesign --verify --strict "$APP"
echo "Собрано: $APP"

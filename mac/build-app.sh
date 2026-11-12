#!/bin/bash
# Builds AppVault.app into ./dist. Usage: ./build-app.sh [--install]
# Requires Xcode (or the Xcode command line tools) on macOS 14 or later.
set -euo pipefail
cd "$(dirname "$0")"

# Universal binary: runs on Apple Silicon and Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --product AppVault "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/AppVault"

APP=dist/AppVault.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AppVault"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Ad-hoc signature (no Apple developer account needed).
codesign --force --sign - --options runtime "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/AppVault.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/AppVault.app"
fi

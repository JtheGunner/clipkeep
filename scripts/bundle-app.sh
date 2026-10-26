#!/usr/bin/env bash
# Assembles build/Clipkeep.app from the SwiftPM release build.
# A bundle is required for SMAppService (launch at login) and for notarization.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="build/Clipkeep.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/Clipkeep" "$app/Contents/MacOS/Clipkeep"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>li.wuermli.clipkeep</string>
  <key>CFBundleName</key><string>Clipkeep</string>
  <key>CFBundleExecutable</key><string>Clipkeep</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "Built $app"

#!/usr/bin/env bash
# Assembles build/Clipkeep.app from the SwiftPM release build.
# A bundle is required for SMAppService (launch at login) and for notarization.
#
# Environment:
#   VERSION            marketing version (default 0.1.0)
#   BUILD_NUMBER       bundle version (default 1)
#   CODESIGN_IDENTITY  signing identity, e.g. "Developer ID Application: Name (TEAMID)".
#                      Default: the identity "Clipkeep Local Signing" if
#                      ./scripts/create-signing-identity.sh has created it, else "-" (ad hoc).
#                      An ad-hoc signature changes with every build, so macOS asks for the
#                      Keychain approval and the privacy grants again after each one.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="build/Clipkeep.app"
version="${VERSION:-0.1.0}"
build_number="${BUILD_NUMBER:-1}"
local_identity="Clipkeep Local Signing"
identity="${CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  if security find-identity -v -p codesigning | grep -qF "\"$local_identity\""; then
    identity="$local_identity"
  else
    identity="-"
  fi
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/Clipkeep" "$app/Contents/MacOS/Clipkeep"

# SwiftPM stamps the binary as linked against the deployment target's SDK (14.0). macOS then runs
# the app in compatibility mode with the old control look. Stamp the SDK that built it instead,
# keeping the minimum OS version.
sdk_version="$(xcrun --show-sdk-version)"
vtool -set-build-version macos 14.0 "$sdk_version" -replace \
  -output "$app/Contents/MacOS/Clipkeep" "$app/Contents/MacOS/Clipkeep"

# SQLCipher ships as a dynamic framework that the executable loads through @rpath.
mkdir -p "$app/Contents/Frameworks"
cp -R "$bin_dir/SQLCipher.framework" "$app/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Clipkeep"

# The app icon (Finder, Launchpad, dialogs, notifications) and the menu bar icon (a template image
# the app loads from Contents/Resources).
resources="$app/Contents/Resources"
mkdir -p "$resources"
cp assets/logo/clipkeep.icns "$resources/Clipkeep.icns"
cp assets/logo/png/clipkeep-menubar.png assets/logo/png/clipkeep-menubar@2x.png "$resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>li.wuermli.clipkeep</string>
  <key>CFBundleName</key><string>Clipkeep</string>
  <key>CFBundleExecutable</key><string>Clipkeep</string>
  <key>CFBundleIconFile</key><string>Clipkeep</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Clipkeep liest die Adresse des aktiven Browser-Tabs, um Kopien dem Kontext zuzuordnen.</string>
</dict>
</plist>
PLIST
if [[ "$identity" == Developer\ ID\ Application:* ]]; then
  # Hardened runtime and a secure timestamp are required for notarization.
  codesign --force --deep --options runtime --timestamp \
    --entitlements Resources/Clipkeep.entitlements --sign "$identity" "$app"
else
  # Ad hoc or a self-signed identity. No hardened runtime: its library validation would refuse
  # the embedded SQLCipher framework, which has no team identifier to match.
  codesign --force --deep --sign "$identity" "$app"
fi

# A bundle without its icons would still run, so check for them here instead of finding out in the
# menu bar. The signature seals them: this runs after signing and fails if a file is missing.
for resource in Clipkeep.icns clipkeep-menubar.png clipkeep-menubar@2x.png; do
  if [[ ! -s "$resources/$resource" ]]; then
    echo "The bundle is missing Contents/Resources/$resource." >&2
    exit 1
  fi
done
codesign --verify --deep --strict "$app"
echo "Built $app (signed with: $identity)"

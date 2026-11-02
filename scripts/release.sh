#!/usr/bin/env bash
# Builds a distributable build/Clipkeep-<version>.zip with one command.
#
#   VERSION=1.0.0 CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=clipkeep-notary ./scripts/release.sh
#
# NOTARY_PROFILE names a keychain profile created once with
#   xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team>
# Without a Developer ID the zip is signed with the local identity or ad hoc, and Gatekeeper will
# warn on other Macs (see "Installation" in the README).
# Without NOTARY_PROFILE the app is signed but not notarised.
# SKIP_TESTS=1 skips the test run, for a caller that has tested the commit already (the release workflow).
# Next to the zip it writes build/Clipkeep-<version>.zip.sha256 (the checksum the Homebrew cask needs).
set -euo pipefail

cd "$(dirname "$0")/.."
export VERSION="${VERSION:?set VERSION, e.g. VERSION=1.0.0}"
identity="${CODESIGN_IDENTITY:--}"
app="build/Clipkeep.app"
zip="build/Clipkeep-$VERSION.zip"
checksum="$zip.sha256"

if [[ -z "${SKIP_TESTS:-}" ]]; then
  ./scripts/test.sh -c release -Xswiftc -enable-testing
fi
./scripts/bundle-app.sh
codesign --verify --deep --strict "$app"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ "$identity" != Developer\ ID\ Application:* ]]; then
    echo "Notarisation needs CODESIGN_IDENTITY (a Developer ID certificate)." >&2
    exit 1
  fi
  submit="build/Clipkeep-notarize.zip"
  ditto -c -k --keepParent "$app" "$submit"
  xcrun notarytool submit "$submit" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$submit"
  xcrun stapler staple "$app"
  spctl --assess --type execute --verbose "$app"
fi

rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
(cd build && shasum -a 256 "$(basename "$zip")") > "$checksum"
echo "Built $zip"
echo "SHA-256: $(cut -d' ' -f1 "$checksum")"

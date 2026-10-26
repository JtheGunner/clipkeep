#!/usr/bin/env bash
# Runs the test suite. With only the Command Line Tools installed (no Xcode),
# the swift-testing macro plugin is not on the default search path, so add it.
set -euo pipefail

plugin_dir="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
flags=()
if [[ -d "$plugin_dir" ]] && ! xcode-select -p | grep -q "Xcode"; then
  flags+=(-Xswiftc -plugin-path -Xswiftc "$plugin_dir")
fi

exec swift test "${flags[@]}" "$@"

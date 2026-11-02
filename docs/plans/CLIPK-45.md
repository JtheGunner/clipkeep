# CLIPK-45: Install the Bitwarden CLI with one click

## Approach

Homebrew only (`brew install bitwarden-cli`). When Homebrew is missing the installation is not
offered; the menu keeps showing the plain "not installed" status.

1. `BitwardenInstaller` in `ClipkeepCore/Bitwarden` behind a protocol: `isAvailable` (brew found)
   and `install()`. Errors: `failed`, `timedOut`; command output is dropped.
2. Status menu: "Bitwarden-CLI installieren …" appears only when the status is `notInstalled` and
   Homebrew is available. A confirmation dialog precedes the run; the item is disabled and the
   status shows progress while it runs; the status is reloaded afterwards.
3. Tests with a fake runner; manual checklist, README and changelog updated.

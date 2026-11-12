# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Shell, SQL and YAML snippets are collected automatically from your copies, with secrets replaced by placeholders before anything is stored. Copies that capture skips (pause, ignored or password manager apps, ignore rules, Clipkeep's own copies) are never collected, and "Snippets automatisch erfassen" in the menu switches collection off.
- The palette searches snippets too: Control+Option+S opens it in snippet mode, Tab switches between history and snippets, Return copies the snippet and Command+Delete removes it so it is not collected again.
- The Clipkeep logo: the app icon in Finder, Launchpad, dialogs and notifications, the menu bar icon (dimmed while capture is paused) and the README header.

### Fixed

- Transferring parked secrets to Bitwarden no longer asks for the Keychain password every few seconds. All parked secrets now live in one Keychain item, so macOS asks at most once and "Always Allow" covers every secret. Secrets parked by earlier versions are moved over on first use, which can ask once more for items an older build created.
- While unlocking or transferring, a small panel with a spinner appears at the top of the screen the pointer is on, the menu bar item shows the same state and the Bitwarden actions are disabled, so it is clear that something is in progress.

## [0.1.1] - 2026-11-02

### Added

- A GitHub Actions workflow publishes a release when a version tag lands on `main`: it builds and signs the archive, creates the GitHub release and opens the cask pull request in the tap.

### Fixed

- Commands that hang, such as a stuck `bw`, now time out on schedule even when the app is busy with other work.

## [0.1.0] - 2026-11-02

### Added

- Menu-bar app with a launch-at-login toggle.
- Encrypted SQLCipher database with schema and migrations; the key lives in the Keychain.
- Clipboard capture with normalisation, content filters, window title and browser address as context.
- Pause and ignore rules for capture.
- Secret detection (token formats, key/value hints, entropy); detected secrets are parked in the Keychain and replaced by a placeholder, with optional transfer to Bitwarden through the `bw` CLI and a "not a secret" undo.
- Content classifier with entity extraction, and normalised and near-duplicate detection.
- Trigram full-text search with filters.
- Explainable importance score, tiers and opt-in retention; pin, star and undoable delete.
- Sessions grouped by pause, app and context, and topics clustered with TF-IDF and structural signals.
- Global hotkey with a floating search palette, and a history window with day, session and topic views.
- Markdown export of a session, a day or a topic.
- Import of collected text files with preview, secret handling and duplicate detection.
- Background maintenance jobs for sessions, topics and ranking.
- Evaluation harness with a synthetic gold set (`./scripts/eval.sh`).
- "Import löschen …" in the menu deletes the entries of one imported file at once, keeps entries that existed before and offers an undo right after.
- Release script with optional Developer ID signing and notarisation (`./scripts/release.sh`).
- One-click installation of the Bitwarden CLI through Homebrew from the Bitwarden menu, offered only when Homebrew is available.
- Installation without an Apple Developer ID: download with right click → "Open", or `brew install --cask JtheGunner/tap/clipkeep`. `./scripts/release.sh` now also writes a SHA-256 checksum next to the zip.

### Changed

- `bundle-app.sh` signs with a local self-signed certificate when one exists (`./scripts/create-signing-identity.sh`), so rebuilds keep the Keychain approval and the privacy grants. Without it the bundle stays ad-hoc signed.

- Safari tab addresses are read by default; SSH targets are kept out of e-mail detection.
- The clipboard is polled every 250 ms.

### Fixed

- Near-duplicate detection no longer slows down quadratically on many almost identical texts, and CJK text gets a usable fingerprint.
- The menu shows a hint when macOS restricts clipboard reading.
- The import preview warns when secrets take large blocks of text with them.
- The Markdown export runs in the background, and the import reports secrets that could not be parked instead of counting them as saved.
- Imported text files are dated by their structure: entries under a date heading (`2024-03-05`, `5.3.2024`, `5. März 2024`, `March 5, 2024`) get that day, and a file without headings gets one session per block. The preview says which applies.
- The history window can rename, merge and move topics, fetch a parked secret from Bitwarden (copied as concealed and cleared after 60 s) and undo "not a secret".
- An open history window now picks up new copies and changed entries (for example after "Kein Secret" in a notification) and keeps selection and scroll position.
- The "Ignorieren" menu lists ignored apps by name instead of bundle identifier; an app that is not installed still shows its identifier.

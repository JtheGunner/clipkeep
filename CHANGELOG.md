# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- Release script with optional Developer ID signing and notarisation (`./scripts/release.sh`).

### Changed

- Safari tab addresses are read by default; SSH targets are kept out of e-mail detection.
- The clipboard is polled every 250 ms.

### Fixed

- Near-duplicate detection no longer slows down quadratically on many almost identical texts, and CJK text gets a usable fingerprint.
- The menu shows a hint when macOS restricts clipboard reading.
- The import preview warns when secrets take large blocks of text with them.

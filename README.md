<div align="center">

# 📋 Clipkeep

**A private, local clipboard history for macOS — searchable, grouped by session, secrets kept out of sight.**

<code>copy</code> &nbsp;→&nbsp; <code>capture</code> &nbsp;→&nbsp; <code>encrypt</code> &nbsp;→&nbsp; <code>find again</code>

![Platform](https://img.shields.io/badge/macOS-14%2B-0ea5e9?style=flat-square&logo=apple)
![Language](https://img.shields.io/badge/Swift-6-f59e0b?style=flat-square&logo=swift)
![Storage](https://img.shields.io/badge/SQLCipher-encrypted-22c55e?style=flat-square)
![Network](https://img.shields.io/badge/network-none-8b5cf6?style=flat-square)

</div>

---

## ✨ What it is

Clipkeep lives in the menu bar and remembers what you copy. Copies are grouped into work sessions and topics, so you can find "that snippet from yesterday's Kubernetes debugging" instead of scrolling a flat list.

Everything stays on your Mac. There is no cloud, no account and no AI at runtime.

| | Feature | Notes |
|---|---|---|
| 🔎 | Palette | Global hotkey <kbd>⌃</kbd><kbd>⌥</kbd><kbd>V</kbd>, full-text search over your history |
| 🗓️ | History window | Days, sessions and topics, entry detail, copy / pin / star / delete with undo |
| 🔐 | Secret handling | Detected secrets are moved to the Keychain; the history keeps only a placeholder |
| ⏸️ | Control | Pause capture, ignore apps, add content rules |
| 📥 | Import | Split a text file into entries, dated by its date headings («Textdatei importieren …») |
| 📤 | Export | A session, a topic or a day as Markdown |
| 🧹 | Upkeep | Sessions, topics and ranking are maintained in the background |

---

## 🛠️ Build and run

Requirements: macOS 14 or newer and the Xcode Command Line Tools (full Xcode is not needed).

```bash
swift build                 # debug build
./scripts/bundle-app.sh     # release build, assembled as build/Clipkeep.app
open build/Clipkeep.app
```

A bundle is required for "launch at login". See [Installation](#-installation) for how the app is signed and installed.

To build a distributable zip, run `VERSION=1.0.0 ./scripts/release.sh`. With a Developer ID certificate (`CODESIGN_IDENTITY`) it signs with the hardened runtime, and with a `notarytool` keychain profile (`NOTARY_PROFILE`) it also notarises and staples the app. See the header of the script.

| | Command | Purpose |
|---|---|---|
| 🔏 | `./scripts/create-signing-identity.sh` | Create the local code-signing certificate, once |
| 🧪 | `./scripts/test.sh` | Run the test suite (`-c release -Xswiftc -enable-testing` for release mode) |
| 🎨 | `./scripts/lint.sh` | Check formatting with swift-format (`--fix` rewrites files) |
| 📏 | `./scripts/eval.sh` | Search-quality evaluation, see [`eval/README.md`](eval/README.md) |

---

## 📦 Installation

Without an Apple Developer ID the app cannot be notarised, but it installs fine from source.

1. **Create a signing certificate once:** `./scripts/create-signing-identity.sh`. It makes a self-signed code-signing certificate in your login keychain and asks for your login password to trust it.
2. **Build and install:** `./scripts/bundle-app.sh`, then copy `build/Clipkeep.app` to `/Applications`. A bundle built on your own Mac has no quarantine flag, so Gatekeeper does not warn.
3. **Rebuild freely:** `bundle-app.sh` signs with that certificate automatically. The signing identity stays the same, so the Keychain approval and the Accessibility and Automation grants survive an update.

Without the certificate the bundle is signed ad hoc. That also runs, but macOS treats every build as a new app and asks for the Keychain approval and the privacy grants again.

**On another Mac:** run `VERSION=1.0.0 ./scripts/release.sh` and send `build/Clipkeep-1.0.0.zip`. Gatekeeper blocks the first launch of an app from outside the App Store. Open it with a right click → "Open", or clear the quarantine flag once with `xattr -dr com.apple.quarantine Clipkeep.app`.

---

## 🔒 Privacy

- **Local only.** Clipkeep makes no network connections and uses no AI model.
- **Encrypted history.** The database is SQLCipher-encrypted at `~/Library/Application Support/Clipkeep/clipkeep.db`. Its key is stored in the macOS Keychain.
- **Secrets are parked.** Passwords, tokens and keys that Clipkeep recognises are stored in the Keychain; the database only holds a placeholder and a fingerprint for duplicate detection.
- **Optional Bitwarden transfer.** If the `bw` command-line client is installed, a parked secret can be handed to your Bitwarden vault.
- **Content is never logged.** Error logs contain error descriptions only.

> [!NOTE]
> Clipkeep records everything you copy that it does not recognise as a secret. Use "pause" and the ignore rules for sensitive workflows.

---

## 🧩 Permissions

| | Permission | Why | Required |
|---|---|---|---|
| 🔑 | Keychain | Database key and parked secrets | Yes |
| 🔔 | Notifications | Tell you when a secret was moved out of the history | Optional |
| ♿ | Accessibility | Read the title of the front window as context | Optional |
| 🌐 | Automation (Apple Events) | Read the address of the active browser tab | Optional |

Reading Safari tab addresses is on by default and can be switched off in the menu; Safari cannot tell private windows apart, so their addresses are recorded too.

---

## 🏗️ Architecture

```text
 clipboard ─▶ ClipboardPoller ─▶ CapturePipeline ─▶ ContentStore ─▶ SQLCipher DB
                                   │ normalise                          ▲
                                   │ detect secrets ─▶ Keychain          │
                                   ▼                                    │
                              context (app, window, URL)      MaintenanceService
                                                          sessions · topics · ranking
 menu bar · palette · history window ◀── search / browse ◀──────────────┘
```

The code is split into a testable library and thin app targets:

| | Target | Role |
|---|---|---|
| 📦 | `ClipkeepCore` | Capture, storage, sessions, topics, ranking, search, import, export, evaluation |
| 🖥️ | `Clipkeep` | AppKit menu-bar app (`LSUIElement`) |
| 📏 | `clipkeep-eval` | Command-line evaluation harness |

---

## 🤝 Contributing

Issues and pull requests are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to report problems, propose changes and run the project locally.

---

## 📝 Changelog

Notable changes are listed in [`CHANGELOG.md`](CHANGELOG.md).

---

## 📄 License

Released under the [MIT License](LICENSE).

---

<div align="center"><sub>Built for people who copy a lot and want to keep it to themselves.</sub></div>

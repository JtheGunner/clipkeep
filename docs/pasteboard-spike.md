# Pasteboard privacy and permissions: findings

Question: does current macOS show extra prompts when an app reads the clipboard in the
background, and what do the optional permissions cost and give?

Tool: `pasteboard-probe <seconds>` (`Sources/PasteboardProbe`). It polls
`NSPasteboard.general.changeCount` every 250 ms, reads each change like the app does, and prints
the types, the markers, the text length, the front window title and the browser address.

## Setup

| | |
|---|---|
| macOS | 26.7.2 (25G332) |
| Run | 90 s, 334 polls, 15 clipboard changes |
| Sources | Google Chrome, Bitwarden desktop, Antigravity IDE, Visual Studio Code |
| Accessibility | granted |
| `NSPasteboard.accessBehavior` | `2` (always allow) |

## Findings

| Topic | Result |
|---|---|
| Reading in the background | All 15 changes were read without error, with the access setting on "allow". The "ask" and "deny" settings were not tested. |
| CPU cost | 0.311 s CPU in 90 s: 0.35 % of one core at a 250 ms interval. |
| Read time | 0.5–2 ms for Electron apps, 7–16 ms for Chrome (it supplies the text on request). Reads belong on a background queue. |
| Window title | Available with the Accessibility permission, for every app tested. |
| Browser address | Available for Chrome through Apple Events. Not available for Electron apps, so the field stays empty there. |
| Markers | No `org.nspasteboard.*` marker (concealed, transient, auto-generated) appeared in any change, including copies out of the Bitwarden desktop app. Marker-based secret detection alone is therefore not enough; content detection stays necessary. |
| Repeated changes | Identical content appeared in consecutive changes (up to three in a row). The run cannot tell repeated copies by the tester from repeated change counts of one copy, so it gives no evidence either way. |
| Source app | The front app at copy time is not always the app that owns the content: a copy out of Bitwarden showed Bitwarden, a paste target shows its own name afterwards. Treat it as a hint. |

## Decisions

1. **Polling interval: 250 ms.** The cost is below half a percent of one core, and a shorter gap
   loses fewer copies, because only the latest content of a burst can be read.
2. **Prompts.** With the access setting on "allow" there is no prompt. The setting can be
   queried (`accessBehavior`, macOS 15.4 and later), so the app can tell the user when it is
   not "allow" instead of silently seeing nothing. This is tracked as follow-up work.
3. **Optional permissions stay optional.** Accessibility (window titles) and Automation
   (browser addresses) improve grouping but are not required for capture.
4. **Secrets.** Do not rely on pasteboard markers; the content detector decides.

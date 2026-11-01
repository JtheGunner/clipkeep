# Manual end-to-end checklist

Automated tests cover the core library. These checks need the real app, real macOS permission
dialogs or a real Bitwarden vault, so they are done by hand before a release.

Menu and dialog labels are quoted as they appear in the app (German).

## How to run

1. Build the bundle: `./scripts/bundle-app.sh`, then `open build/Clipkeep.app`.
2. Use a test Mac user or accept that the history will contain your test copies.
3. For permission checks, reset the app's grants first: `tccutil reset All li.wuermli.clipkeep`.
4. Tick each box; write down any deviation as its own issue and link it here.

Record the macOS version, the app version and the date next to each run.

## 1. First launch and permissions

- [ ] The menu bar icon appears and the app has no Dock icon.
- [ ] The first launch asks for Keychain access once; "Always allow" stops further prompts.
- [ ] "Beim Anmelden starten" toggles and shows a check mark; after a re-login the app starts.
- [ ] "Fenstertitel: Bedienungshilfen erlauben …" shows the system prompt on the first click and opens Settings on later clicks. Afterwards the entry reads "Fenstertitel: erlaubt".
- [ ] "Browser-Adressen: Automation erlauben …" asks for each installed browser; "nicht erlaubt – öffnen …" opens the Automation pane after a denial.
- [ ] Denying every optional permission still records copies (without window title or address).

## 2. Clipboard access (macOS 15.4 and later)

Settings → Privacy & Security → Paste from Other Apps → Clipkeep.

- [ ] "Allow": copies are recorded, no hint in the menu.
- [ ] "Ask": the menu shows the hint about the per-read question; copying still works or the hint explains why not.
- [ ] "Deny": the menu shows the "Lesen verboten" hint and the entry opens System Settings.
- [ ] Switching the setting back to "Allow" removes the hint the next time the menu opens.

## 3. Capture

- [ ] Copying text from Safari, Chrome, a terminal and an editor creates entries with the right source app.
- [ ] Window title and address are recorded where the permissions are granted.
- [ ] "Aufzeichnung pausieren" stops capture, the icon changes, "Aufzeichnung fortsetzen" resumes it.
- [ ] "… ignorieren" for the front app stops recording from that app; removing it under "Ignorieren" resumes.
- [ ] A content rule ("Inhaltsregel hinzufügen …") skips matching copies; an invalid pattern shows "Regel nicht übernommen".

## 4. Secrets and notifications

- [ ] The first secret copy asks for notification permission.
- [ ] Copying a token or private key shows "Secret gesichert" and the history shows only a placeholder.
- [ ] The "Kein Secret" action works from the notification (asks for authentication) and the text is then stored normally.
- [ ] After the undo window has passed, "Rückgängig nicht mehr möglich" appears.
- [ ] "Secret-Ausnahmen" lists the exception; removing it parks the next copy again.
- [ ] With notifications denied, secrets are still parked and nothing breaks.

## 5. Hotkey and palette

- [ ] <kbd>⌃</kbd><kbd>⌥</kbd><kbd>V</kbd> opens the palette from any app.
- [ ] Typing searches the history, arrow keys and Return copy the entry, Escape closes the palette.
- [ ] When another app owns the shortcut the menu reads "Kurzbefehl ⌃⌥V ist belegt" and "Suchpalette öffnen" still works.

## 6. History window

- [ ] "Verlauf öffnen …" lists days, sessions and topics; the detail view shows the entry with its context.
- [ ] Copy, pin, star and delete work; the undo restores a deleted entry.
- [ ] Search inside the window finds entries by substring.
- [ ] Right-click a topic: "Thema umbenennen …" renames it (an empty name restores the automatic label) and "Mit anderem Thema zusammenführen …" moves all its sessions into the chosen topic.
- [ ] Right-click a session: "In anderes Thema verschieben …" and "Eigenes Thema daraus machen" work; a manual change is not undone by the next rebuild of the topics.
- [ ] While more days can still be loaded, the header of the last day reads "N+ Sessions"; after scrolling to the end it shows the exact number.
- [ ] A parked secret shows "Aus Bitwarden abrufen": the value lands in the clipboard, is not recorded again, is skipped by a clipboard manager and is cleared after 60 seconds unless something else was copied.
- [ ] With Bitwarden locked, without the CLI or offline, the window header explains it instead of failing silently.
- [ ] "Kein Secret" in the window asks for confirmation and restores the entry as a normal one.
- [ ] "Exportieren …" writes a Markdown file for a session, a day and a topic; the window stays responsive during a large export; parked secrets are not in the file.

## 7. Import

- [ ] "Textdatei importieren …" opens the file picker; a binary file and a file over 200 MB are refused with a message.
- [ ] The preview shows counts, samples and the split mode; changing the mode updates it.
- [ ] A file in which a long block holds one secret shows the warning about the share of text that is dropped.
- [ ] Importing creates entries labelled "Import" before the live history; running it again adds nothing.
- [ ] Cancelling mid-import keeps the entries imported so far.
- [ ] Imported secrets are parked, and the result reports any that could not be parked.

## 8. Bitwarden (real vault)

Needs the `bw` CLI and a test vault; never use your main vault.

- [ ] Without `bw`, the status line says it is not installed and parked secrets stay in the Keychain.
- [ ] Logged out: the status says to run `bw login` in a terminal.
- [ ] "Entsperren und Secrets übertragen …" with a wrong master password shows "Masterpasswort falsch".
- [ ] With the right password, parked secrets appear as secure notes in the vault and the count is reported.
- [ ] Running the transfer twice does not create duplicate notes.
- [ ] "Sperren" locks the vault again; offline, the status says secrets stay in the Keychain.
- [ ] Quitting the app locks the vault.

## 9. Upkeep and quit

- [ ] After a few minutes of use, sessions and topics are rebuilt without visible lag.
- [ ] Quitting and relaunching keeps the history; the database file is not readable as plain text.
- [ ] "Clipkeep beenden" quits cleanly; no stray `bw` process remains.

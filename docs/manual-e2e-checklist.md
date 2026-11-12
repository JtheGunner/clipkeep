# Manual end-to-end checklist

Automated tests cover the core library. These checks need the real app, real macOS permission
dialogs or a real Bitwarden vault, so they are done by hand before a release.

Menu and dialog labels are quoted as they appear in the app (German).

## How to run

1. Build the bundle: `./scripts/bundle-app.sh`, then `open build/Clipkeep.app`.
2. Use a test Mac user or accept that the history will contain your test copies.
3. For permission checks, reset the app's grants first: `tccutil reset All li.wuermli.clipkeep`.
4. Tick each box; write down any deviation as its own issue and link it here.

A bundle signed ad hoc (the default of `bundle-app.sh`) gets a new signature with every build.
macOS then treats each build as a different app: the Keychain approval and the Accessibility and
Automation grants have to be given again after a rebuild.

Record the macOS version, the app version and the date next to each run.

## 1. First launch and permissions

- [ ] The menu bar icon appears and the app has no Dock icon.
- [ ] The menu bar icon is the Clipkeep logo and reads well in a light and a dark menu bar (it is a template image, so macOS tints it).
- [ ] `build/Clipkeep.app` shows the Clipkeep icon in Finder and Launchpad, and in the dialogs and notifications the app shows.
- [ ] The first launch of a fresh install shows no Keychain prompt, because the app created the key itself. After a rebuild with a different signature the prompt appears once; "Always allow" stops it for that build.
- [ ] The menu shows icons on its action items (palette, history, import, pause, ignore, quit) and none on status lines.
- [ ] "Beim Anmelden starten" toggles and shows a check mark; after a re-login the app starts.
- [ ] "Fenstertitel: Bedienungshilfen erlauben …" shows the system prompt on the first click and opens Settings on later clicks. Afterwards the entry reads "Fenstertitel: erlaubt".
- [ ] "Browser-Adressen: Automation erlauben …" asks for each running browser; "nicht erlaubt – öffnen …" opens the Automation pane after a denial.
- [ ] Denying every optional permission still records copies (without window title or address).

## 2. Clipboard access (macOS 15.4 and later)

Settings → Privacy & Security → Paste from Other Apps → Clipkeep. Only macOS versions that offer this setting can run this section; if it is missing, note the macOS version and skip the section.

- [ ] "Allow": copies are recorded, no hint in the menu.
- [ ] "Ask": the menu shows the hint about the per-read question; copying still works or the hint explains why not.
- [ ] "Deny": the menu shows the "Lesen verboten" hint and the entry opens System Settings.
- [ ] Switching the setting back to "Allow" removes the hint the next time the menu opens.

## 3. Capture

- [ ] Copying text from Safari, Chrome, a terminal and an editor creates entries with the right source app.
- [ ] Window title and address are recorded where the permissions are granted.
- [ ] "Aufzeichnung pausieren" stops capture, the menu bar logo is dimmed, "Aufzeichnung fortsetzen" resumes it and the logo is back to full strength.
- [ ] "Snippets automatisch erfassen" is checked by default. With it on, copying a shell command, a SQL statement or a YAML block adds a snippet (secrets shown as placeholders, never the value); with it off, or while capture is paused, nothing is added. The choice survives a restart.
- [ ] "Snippets aus Verlauf übernehmen …" asks for confirmation first; "Abbrechen" changes nothing. After "Übernehmen" the menu item reads "Snippets werden übernommen …" until a dialog reports how many entries were checked and how many snippets were added (counts only, no text). Parked secrets are not taken over, a snippet removed in the palette does not come back, and running it a second time reports 0 new snippets without raising any snippet's count. The history itself is unchanged.
- [ ] "… ignorieren" for the front app stops recording from that app; removing it under "Ignorieren" resumes.
- [ ] A content rule ("Inhaltsregel hinzufügen …") skips matching copies; an invalid pattern shows "Regel nicht übernommen".

## 4. Secrets and notifications

- [ ] The first secret copy asks for notification permission.
- [ ] Copying a token or private key shows "Secret gesichert" and the history shows only a placeholder.
- [ ] The "Kein Secret" action works from the notification without a prompt, as long as the Mac is unlocked, and the text is then stored normally. Reopen the history window afterwards to see it (the window does not refresh by itself yet).
- [ ] After the undo window has passed, "Rückgängig nicht mehr möglich" appears.
- [ ] "Secret-Ausnahmen" lists the exception; removing it parks the next copy again.
- [ ] With notifications denied, secrets are still parked and nothing breaks.

## 5. Hotkey and palette

- [ ] <kbd>⌃</kbd><kbd>⌥</kbd><kbd>V</kbd> opens the palette from any app.
- [ ] Palette rows start with the same type icon as the history list; the selected row is a rounded highlight. Light and dark appearance both look right.
- [ ] Typing searches the history, arrow keys and Return copy the entry, Escape closes the palette.
- [ ] When another app owns the shortcut the menu reads "Kurzbefehl ⌃⌥V ist belegt" and "Suchpalette öffnen" still works.
- [ ] <kbd>⌃</kbd><kbd>⌥</kbd><kbd>S</kbd> opens the palette from any app directly in snippet mode, with the placeholder "Snippets durchsuchen …". Pressing it again closes the palette; pressing <kbd>⌃</kbd><kbd>⌥</kbd><kbd>V</kbd> instead switches to the history.
- [ ] With the palette open, <kbd>Tab</kbd> switches between history and snippets and keeps the typed query.
- [ ] Snippet rows show the first line as title and "age · Shell/SQL/YAML · count×" below it; an empty query lists the most recently copied snippets first. With no snippets the list is empty and nothing breaks.
- [ ] <kbd>Return</kbd> on a snippet copies it and closes the palette; the copy does not appear as a new history entry and does not raise the snippet's count.
- [ ] In snippet mode <kbd>⌘</kbd><kbd>⌫</kbd> removes the selected snippet without touching the query, and copying the same text again does not bring it back. In history mode <kbd>⌘</kbd><kbd>⌫</kbd> still deletes the query text.
- [ ] When another app owns <kbd>⌃</kbd><kbd>⌥</kbd><kbd>S</kbd>, <kbd>⌃</kbd><kbd>⌥</kbd><kbd>V</kbd> still opens the palette and Tab still reaches the snippets.

## 5a. Snippet explorer and menu

- [ ] The menu groups "Suchpalette öffnen" and "Verlauf öffnen …" in one block and everything about snippets ("Snippet-Suche öffnen", "Snippet-Explorer öffnen …", "Snippets automatisch erfassen", "Snippets aus Verlauf übernehmen …") in a second block, with a separator between the two blocks and another before "Textdatei importieren …".
- [ ] The menu reads "Snippet-Suche öffnen (⌃⌥S)" and opens the palette in snippet mode; when another app owns the shortcut it reads "Snippet-Suche öffnen (Kurzbefehl ⌃⌥S ist belegt)" and still works.
- [ ] "Snippet-Explorer öffnen …" opens a window listing every snippet with the columns Snippet, Sprache, Thema, Zuletzt genutzt, Angelegt and Häufigkeit; the count under the list reads "N Snippets". Light and dark appearance both look right.
- [ ] Clicking a column header sorts by it and a second click reverses it (Snippet, Sprache and Thema start A to Z, Zuletzt genutzt and Häufigkeit start newest or most first); a snippet without a topic stays at the end of a Thema sort.
- [ ] The language menu limits the list to Shell, SQL or YAML and the topic menu then lists only that language's topics with their counts; the search field narrows the list by text and topic as you type, and the count reads "N von M Snippets".
- [ ] Selecting a snippet shows its full text and a line with language, topic, created, last used, origin and source app. "Kopieren" and a double click put it on the clipboard without adding a history entry.
- [ ] Narrowing the filters so the selected snippet disappears leaves nothing selected (the text area is empty and "Kopieren" and "Löschen …" are disabled) instead of selecting another snippet; relaxing the filters afterwards removes the "Kein Snippet passt zu den Filtern." message.
- [ ] "Löschen …" asks first; after confirming the snippet is gone, copying the same text again does not bring it back.
- [ ] A snippet captured while the window is open appears after clicking out of and back into the window. With no snippets the window says so instead of showing an empty table.

## 6. History window

- [ ] "Verlauf öffnen …" lists days, sessions and topics; the detail view shows the entry with its context.
- [ ] The window has a toolbar with the sidebar toggle, the "Tag"/"Themen" switch, the entity filter and the search field. The sidebar collapses and expands from the toolbar, keeps its width after reopening the window, and reaches under the toolbar. Light and dark appearance both look right.
- [ ] Both dividers on the right can be dragged: between the entry list and the detail, and between the copied text and the details of the copy. Neither pane collapses to nothing, and the list header never touches the toolbar.
- [ ] Every row of the entry list starts with an icon for its type (text, link, e-mail, path, command, JSON, stacktrace, code, number, secret). Hovering the icon shows the type name. Icons look right in light and dark appearance.
- [ ] Selecting a session fills the entry list with its entries and their text; selecting an entry shows its text and the importance breakdown. The list and the detail text keep a visible height when the window is resized.
- [ ] Copy, pin, star and delete work; the undo restores a deleted entry.
- [ ] "Als Snippet speichern" on a SQL statement stores it as a SQL snippet and the header reads "Als Snippet gespeichert."; the snippet appears in the palette's snippet mode. On a short text like `ls` a dialog asks for Shell, SQL or YAML; "Abbrechen" stores nothing. A snippet removed in the palette can be saved again this way. The button is disabled for a parked secret, and the history entry stays unchanged.
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
- [ ] The preview shows counts, samples and the split mode; changing the mode updates it. The samples sit on a rounded card without a frame.
- [ ] A file in which a long block holds one secret shows the warning about the share of text that is dropped.
- [ ] Importing creates entries labelled "Import" before the live history; running it again adds nothing.
- [ ] The preview names the time distribution: with date headings in the file the entries sit on those days, without them every block is a session of its own.
- [ ] Cancelling mid-import keeps the entries imported so far.
- [ ] Imported secrets are parked, and the result reports any that could not be parked.

## 8. Bitwarden (real vault)

Needs the `bw` CLI and a test vault; never use your main vault.

- [ ] Without `bw`, the status line says it is not installed and parked secrets stay in the Keychain.
- [ ] Without `bw` but with Homebrew, "Bitwarden-CLI installieren …" is offered; cancelling the dialog installs nothing, confirming installs `bw` and the status updates without a restart, and the item disappears.
- [ ] Without `bw` and without Homebrew, no install item is offered; only the "not installed" status shows.
- [ ] A failing installation (e.g. offline) shows a short message without paths, and the item stays available.
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

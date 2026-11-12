# CLIPK-54: Snippet collection for shell, SQL and YAML

## Intent

Developers re-need code they copied recently: a SQL query, a shell command, a YAML block. They no
longer remember it and end up searching the web again. Clipkeep already sees everything that is
copied, so it can keep the useful code automatically and make it findable from the hotkey palette.

The collection is a **history of meaningful code that fills itself**, not a folder the user curates.
Success means: when the user needs "that query from last week", it is in the snippet palette, and
the palette is not full of junk.

## Goals

- A separate snippet store that is independent of the history: history upkeep (tiers, ranking,
  purging) never touches it, and snippets never expire on their own.
- Automatic capture from the clipboard, limited to shell, SQL and YAML that look like real code.
- Secrets inside a snippet are replaced by placeholders before anything is stored.
- Search through a palette opened by a global hotkey; Return copies the snippet.
- A snippet the filter missed can be promoted from the history by hand; an unwanted one can be
  deleted and is not captured again.
- The filter is measured against the real history before capture goes live.

## Non-goals

- Placeholders/variables to fill in, templates, folders, tags and manual editing of snippets.
- Languages other than shell, SQL and YAML. The language is a column, so more can follow.
- A learning filter that adapts from deletes and promotions.
- Any network access, sync or AI at runtime (Clipkeep has none and keeps it that way).
- Changing how the history is captured, ranked or purged.

## Anti-goals

These make the feature a failure even if it technically works:

- **Noise.** A list full of single variables, one-line fragments or arbitrary YAML scraps makes the
  tool useless. Precision wins over recall.
- **Missing a snippet the user needed.** Mitigated, not eliminated, by promotion from the history.
- **A secret in clear text** in the snippet store, the search index or the palette.

## Decisions made with the user

- Snippets are managed separately from the clipboard history.
- They are filled automatically from the clipboard; code is nearly always copied, from any source.
- Only meaningful code is kept (a variable definition is not a snippet). The filter is **strict**;
  what it misses is recovered from the history by hand.
- Secrets are anonymised, never stored as they were copied.
- Languages are shell, SQL and YAML.

## Existing code this builds on

| Area | Where | Relevance |
|---|---|---|
| Capture | `ClipkeepCore/Capture/CapturePipeline.swift` | Runs pause, blocked apps, marker types, ignore rules and length checks, then **skips any text containing a secret** before storing. The snippet stage must run on the text before that skip. |
| Secrets | `ClipkeepCore/Secrets/SecretDetector.swift` | `detect(in:)` returns `SecretMatch` values with kind and range, never the value. Enough to build placeholders. |
| Classification | `ClipkeepCore/Analysis/ContentClassifier.swift` | Knows `command`, `code`, `json`, `stacktrace`, `url`, `path`. Recognises neither SQL nor YAML. |
| Storage | `ClipkeepCore/Storage/Schema.swift`, `Migrator.swift` | SQLCipher, versioned migrations (latest is 11), FTS5 trigram index pattern over a folded `search_text`. |
| Search | `ClipkeepCore/Search/`, `Palette/PaletteRow.swift` | `PaletteSearch` and `PaletteRow` for the existing palette. |
| Palette UI | `Clipkeep/PaletteController.swift`, `AppDelegate.swift` | One floating panel, one global hotkey (Control+Option+V). |
| Own copies | `OwnCopyWriter` | Copies written by Clipkeep carry a marker and are skipped by capture, so copying a snippet does not capture it again. |
| Evaluation | `Sources/ClipkeepEval`, `eval/README.md`, `scripts/eval.sh` | Existing harness for search quality. |

## Design

### Storage

A new migration (version 12) adds a `snippets` table that has **no foreign key to `contents`**:

- `id`, `text` (already anonymised), `hash` (unique, over the normalised anonymised text),
  `language` (`shell`, `sql`, `yaml`), `search_text`, `created_at`, `last_copied_at`, `copy_count`,
  `origin` (`auto`, `history`), `app_name` (the source app, informational).
- An FTS5 trigram index over `search_text`, with the same insert/delete/update triggers as
  `contents_fts`.
- A `snippet_rejections` table holding the `hash` of every snippet the user deleted.

Deleting a snippet removes the row and records its hash, so the same text is not captured again.
Promoting it from the history by hand clears the rejection. Nothing in `MaintenanceService` reads or
writes these tables.

A new module folder `ClipkeepCore/Snippets` holds `SnippetStore` (insert with deduplication, list,
search, delete, rejection check), `SnippetFilter` and `SnippetAnonymizer`.

### Filter: what counts as a snippet

`SnippetFilter.evaluate(text)` returns a language or `nil`. It is deterministic, pure and strict:

- Runs independently of `ContentClassifier`, which stays unchanged. It calls
  `ContentClassifier.classify` read-only as a first pass and rejects what it identifies as `url`,
  `email`, `path`, `number`, `json`, `stacktrace` or `secret`, plus anything that is single-line and
  very short. The shell, SQL and YAML rules are its own.
- **Shell:** a command with real arguments (flags, pipes, redirects, substitutions, multiple
  arguments), or several command lines. A bare command name, `cd x` or `ls` is rejected.
- **SQL:** a statement with a recognised verb and its structure (`SELECT … FROM`, `INSERT INTO …`,
  `UPDATE … SET`, `CREATE TABLE`, `WITH … AS`). A lone keyword is rejected.
- **YAML:** several `key: value` lines with consistent indentation, nesting or list items. A single
  `key: value` line or a `.env`-style flat list is rejected.
- Rejects text that is mostly prose.

The numeric thresholds (minimum length, minimum signals) are **starting values** and are fixed by
the evaluation below, not guessed up front.

### Anonymisation

`SnippetAnonymizer` runs `SecretDetector.detect(in:)` over the text and replaces each match range
with a placeholder named after the kind (`<OPENAI_API_KEY>`, `<GITHUB_TOKEN>`, `<PRIVATE_KEY>`, …).
For `keyValueSecret` and `highEntropyToken` only the value is replaced and the key stays, so
`DB_PASSWORD=<VALUE>` remains readable. The original value is not kept anywhere for snippets: no
Keychain item, no database column. The history keeps following its existing path (secret copies are
parked and never stored as text).

The filter runs on the anonymised text, so a placeholder never makes text look like a secret again.

### Capture integration

A snippet stage in `CapturePipeline.process`, after pause, blocked-app, marker-type, length and
ignore-rule checks and **before** the secret skip. It therefore inherits every existing "do not
record this" rule, and secret-bearing code is still snippet-worthy after anonymisation. The stage
asks `SnippetStore` whether the hash is rejected or already known (known: bump `last_copied_at` and
`copy_count`), otherwise stores it. A failure in this stage is logged and never blocks the history
capture. Whether the copy is also stored in the history is unchanged.

A menu item switches automatic snippet capture on and off (stored in `SettingsStore`). It is on by
default. This is safe because the capture ticket is merged only after the evaluation review (see
Child tickets), so no build ever captures with an unreviewed filter.

### Palette

One palette, two sources. A second global hotkey (Control+Option+S) opens it directly in snippet
mode; Tab switches the mode while it is open. `PaletteController` takes its source through a small
protocol so the existing history search is unchanged. A snippet row shows the first non-empty line
as title and `age · language · count×` as subtitle. An empty query lists snippets by
`last_copied_at`; a query uses the trigram index and orders by match, then recency and copy count.
Return copies through `OwnCopyWriter`.

### Promote and delete

- **Promote:** the history window already has a context menu and toolbar actions per entry (copy,
  pin, star, delete, undo). "Als Snippet speichern" is added there. It stores the entry with
  `origin = history`, bypasses the strictness of the filter but still runs the anonymiser, and
  clears a matching rejection. The language comes from the filter when it recognises one;
  otherwise a small menu offers shell, SQL and YAML and the user picks.
- **Delete:** the palette has no per-row action mechanism today (only arrows, Return and Esc, handled
  in `doCommandBy`). In snippet mode the palette gains Command+Delete on the selected row. The
  palette ticket owns this extension.

### Evaluation

`ClipkeepEval` gains a snippet mode that runs `SnippetFilter` over the user's real history and prints
accepted entries with their language and rejected code-like entries, for the user to review. Output
stays local and is never committed. A labelled set of synthetic examples lives in the unit tests as
the regression suite. The user reviews the real run before the capture ticket is merged. The
history never contains copies with secrets (they are parked, not stored), so the real run cannot
exercise the anonymiser; synthetic secret-bearing examples in the unit tests cover it.

The same code serves a one-time backfill action that seeds the collection from the existing history.

## Constraints

- Swift 6, macOS 14+, Command Line Tools only (no Xcode): UI in AppKit, formatting with
  `swift-format`, tests via `scripts/test.sh`.
- User-facing strings are German; code, comments, docs and commits are English.
- Every behaviour change carries a test; unit tests cover store, filter, anonymiser and the capture
  stage. Update README, CHANGELOG (Unreleased) and `docs/manual-e2e-checklist.md`.

## Child tickets (proposed order)

1. Storage: migration 12, `SnippetStore`, rejections, FTS search, tests.
2. Filter and anonymiser with a labelled regression set.
3. Snippet evaluation in `ClipkeepEval` and the review against the real history (gate before
   capture goes live).
4. Capture integration and the on/off menu item.
5. Palette snippet mode and the second hotkey.
6. Promote from history, delete, one-time backfill from the history.

Documentation (README, CHANGELOG, manual checklist) is part of the ticket that changes the
behaviour. Tickets 1 and 2 are independent. 3 needs 2. 4 needs 1 to 3. 5 needs 1. 6 needs 1, 2 and 5.

## Decisions left to the builder

Marked as the author's calls, not agreed with the user:

- Exact deduplication on the anonymised text only. Near-duplicate variants stay separate snippets;
  SimHash linking is a possible later step.
- Deleting is a hard delete plus a rejection hash, not a soft delete.
- Menu toggle for automatic capture, on by default, with the review gate before merge.
- Second hotkey Control+Option+S plus Tab to switch mode.
- Command+Delete for deleting in the palette; the history context menu for promotion.
- Placeholder naming scheme and the starting thresholds of the filter.

## Further decisions made with the user

- **Acceptance bar for the filter.** The user reviews the real-history run in rounds (run, review,
  adjust, re-run) and signs off when, in a sample of about 30 accepted entries, at most 3 are junk
  and the user misses no more than a few snippets they expected. The plan includes an explicit
  hand-off point where the user reviews the output.
- **Backfill.** The collection can be seeded once from the existing history through a manual menu
  action built on the evaluation code. It is a deliverable of the promote/delete ticket and uses the
  same filter and anonymiser as live capture.

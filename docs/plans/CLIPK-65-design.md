# CLIPK-65: Extend the snippet collection

## Intent

The snippet collection fills itself from the clipboard. Used daily, it fills with near-copies of the
same command that differ only in a path or a value, which makes the list long and hard to scan.
Snippets are also read-only and unannotated, and the user cannot add one that was never copied.

Success means: the explorer shows one entry per command shape, code is readable at a glance, a
snippet tells the user whether it is well-formed, and the user can add and annotate snippets by hand.

## Goals

- **Merge near-copies.** Snippets that are identical apart from variable values (paths, numbers,
  quoted strings, URLs, IP addresses, hashes) become one snippet with several variants.
- **Syntax highlighting** for shell, SQL and YAML in the explorer detail view and the palette.
- **Syntax check** for the same three languages: a snippet is valid, invalid (with a short hint) or
  not checked.
- **Comments:** one free-text comment per snippet, shown in the explorer and searchable.
- **Manual creation** of a snippet (text, language, optional comment).

## Non-goals

- Executing snippets, in the check or anywhere else.
- Languages beyond shell, SQL and YAML.
- Sync between devices, network access, AI at runtime.
- Comments per group, comment history, tags, folders, templates with fill-in variables.
- Editing the text of an existing snippet. (Manual creation is in; edit-in-place is a later step.)

## Anti-goals

- **Wrong merges.** Merging two commands that do different things is worse than leaving near-copies
  separate. Command, flags and structure must match for a merge.
- **A check that cries wolf.** A false "invalid" on valid code erodes trust. When a check is not
  confident it reports "not checked", never "invalid".
- **Losing data.** Merging must not drop any copied text, count, or timestamp.
- **A secret in clear text.** Manually added text passes through the anonymiser like captured text.

## Constraints

- Swift 6, macOS 14+, Command Line Tools only (no Xcode), AppKit UI, `swift-format`, tests through
  `scripts/test.sh`. The only package dependency is SQLCipher; no new dependencies are added.
- No code path runs a snippet or spawns a process for the check.
- User-facing strings are German; code, comments, docs and commits are English.
- Every behaviour change carries a test. README, CHANGELOG (Unreleased) and
  `docs/manual-e2e-checklist.md` are updated in the ticket that changes the behaviour.
- Existing behaviour that must keep working: the exact-hash dedupe and rejection list on delete,
  trigram search over `search_text`, history independence (maintenance never reads snippets),
  anonymisation before storage.

## Approaches considered

1. **Merge in storage, keep variants (chosen).** A snippet has a shape key and one or more variants.
   Capture adds a variant to a matching snippet or creates a new one. Delete, counts and comments
   work on the snippet. Moderate effort: a new table, a migration, and changes to capture, search
   and the explorer.
2. **Group only in the explorer.** Storage stays as it is and the explorer groups by shape. Cheap,
   but counts, delete and comments stay per variant and the duplicates remain in the data, which is
   not what the user asked for.
3. **Merge into a single template with placeholders** (`ls -la <PATH>`), dropping the concrete
   values. Rejected: the concrete values are the part the user wants back.

The user chose approach 1, with redirects ignored in the shape (see below).

## Design

### Shape key

`SnippetShape.of(text, language)` returns a normalised string; its hash is the merge key. It is
pure and deterministic. Normalisation, per language:

- **All languages:** trim; collapse whitespace; lower-case keywords only where the language is
  case-insensitive (SQL keywords), never string contents.
- **Shell:** every word that is a path (starts with `/`, `~/`, `./`, `../`, or contains `/` and no
  flag prefix), a number, a quoted string, a URL, an IPv4/IPv6 address, or a long hex/base64 token is
  replaced by a kind token (`<path>`, `<num>`, `<str>`, `<url>`, `<ip>`, `<hash>`). Redirections
  (`2>/dev/null`, `>/dev/null 2>&1`, `&>file`) are removed from the shape. Program, flags, pipes,
  operators and the order of words stay.
- **SQL:** string and numeric literals become `<str>` and `<num>`; whitespace and keyword case are
  normalised; identifiers, operators and structure stay.
- **YAML:** scalar values become `<str>`, `<num>` or `<bool>`; keys, nesting and list structure stay.

Two snippets merge only when language and shape key are equal. Multi-line snippets use the same rules
per line and must have the same number of lines; a snippet with an extra or missing line is a
different shape.

Guards against wrong merges:

- **Shell:** the first word of every command (the start of the text and after `|`, `&&`, `||`, `;`)
  is never masked, so `./deploy.sh` and `/usr/bin/rm` stay distinct programs. The quoted argument of
  `-c`, `eval` and `exec` is never masked, because it is code, not a value.
- The shape runs on the **anonymised** text only. Placeholders produced by the anonymiser
  (`<OPENAI_API_KEY>`, …) are kept literally in the shape. Shape tokens use a marker character that
  cannot occur in text (for example `\u{1}path`), so they never clash with placeholders.
- Two texts that differ only by a secret become byte-identical after anonymising, hash to the same
  variant and are a bump, as today.

The shape algorithm is versioned: `snippets.shape_version` records which rules produced
`shape_hash`. A later rule change re-keys rows whose version is older (see Storage).

### Storage

A migration (next version after the current latest) adds:

- `snippet_variants(id, snippet_id → snippets(id) ON DELETE CASCADE, text, hash UNIQUE,
  created_at, last_copied_at, copy_count)`.
- On `snippets`: `shape_hash`, `shape_version`, `comment` (nullable text) and
  `representative_variant_id`. `snippets.origin` gains the value `manual`. `snippets.hash` is
  dropped from the lookup path (variants carry the exact hash).
- The existing `snippets_fts` is dropped and recreated as external content over
  `snippets.search_text`, still keyed per snippet (`rowid = snippets.id`), so the search join, the
  per-snippet ranking and the triggers keep their shape. `snippets.search_text` becomes the folded
  concatenation of all variant texts and the comment; the store rewrites it whenever a variant or
  the comment changes.

`snippets` keeps one row per merged snippet. Its `text` (the representative variant, the most
recently copied), `copy_count` (sum) and `last_copied_at` (latest) stay denormalised, so list and
sort queries stay cheap. `app_name` stays on the snippet and holds the source app of the
representative variant.

**Migration.** `Migration` gains an optional Swift step that runs inside the same transaction after
its SQL statements, because the shape rules are Swift, not SQL. The step moves every existing
snippet into one variant, computes `shape_hash` and `shape_version`, then merges rows that share a
language and shape key: counts are summed, the earliest `created_at` and the latest
`last_copied_at` are kept, the strongest origin wins (`manual` > `history` > `auto`) and the longest
non-empty comment is kept. A failure rolls the whole migration back. A later change of the shape
rules ships as a new migration that re-keys and re-merges rows with an older `shape_version`.
Existing `snippet_rejections` stay valid as hashes of variant texts.

### Capture and store

`SnippetStore.add` computes the shape and looks up the snippet by `(language, shape_hash)`:

- A variant with the same hash exists: bump that variant and the snippet.
- A snippet with the same shape exists: insert a new variant, bump the snippet, make the new variant
  the representative.
- Otherwise insert a snippet and its first variant.
- A text whose hash is in `snippet_rejections` is rejected as before (manual add overrides, as
  promotion does today).
- With `bumpingExisting: false` (promotion from the history): an existing variant is left as it is
  (`unchanged`); a new variant of a known shape is still added, without counting a copy, and the
  outcome is `unchanged(snippetId)`.
- A manual add that joins an existing snippet raises its origin to `manual`.

**Public shape.** `Snippet` keeps its fields (`text` and `appName` are the representative's) and
gains `comment`, `variantCount` and `shapeHash`. A separate `variants(of:)` returns the variants of
one snippet for the detail view. List and search never load variants. `SnippetExplorer`,
`SnippetTopic`, `SnippetPaletteSearch` and `SnippetPromoter` keep consuming `Snippet`.

`delete(id:)` removes the snippet and records the hash of every variant in `snippet_rejections`.
`SnippetOutcome` values keep their meaning; `inserted`/`bumped` refer to the snippet id.

### Explorer and palette

- One row per snippet. Title is the representative variant's first line, subtitle adds a variant
  count (`3 Varianten`) when more than one exists. The detail view lists the variants (text, count,
  last copied) and lets the user pick which one to copy; the default is the representative.
- The palette shows one row per snippet and copies the representative variant.
- Search matches any variant text and the comment.
- Sorting by count uses the summed count; "last used" uses the latest variant.
- `SnippetTopic` stays as is and still groups by program/table/kind on top of the merged snippets.

### Highlighting

`SnippetHighlighter.tokens(text, language)` returns ranges with a token kind (keyword, string,
number, comment, operator, variable/flag, key, punctuation). It is a small hand-written lexer per
language. The AppKit layer maps kinds to theme colours (light and dark) and builds an
`NSAttributedString` for the explorer detail view and the palette row preview. Lexing is
best-effort: unknown input renders as plain text, and it never throws.

### Syntax check

`SnippetValidator.check(text, language)` returns `valid`, `invalid(hint, range?)` or `notChecked`.
It never runs the snippet.

- **Shell:** unterminated quotes, unbalanced `(`, `{`, `` ` ``, `$(`; dangling `|`, `&&`, `||`, `;;`
  without a command; unterminated heredoc. Constructs the checker does not model (functions, `case`,
  process substitution, here-strings) lead to `notChecked`, not `invalid`.
- **SQL:** unterminated strings or comments, unbalanced parentheses, a statement that starts with a
  verb but lacks the structure its verb needs (`SELECT` without projection, `INSERT INTO` without
  `VALUES`/`SELECT`, `UPDATE` without `SET`). Dialect-specific input leads to `notChecked`.
- **YAML:** tabs used for indentation, inconsistent indentation, a mapping key without separator
  inside a block mapping, unbalanced flow brackets, unterminated quoted scalars.

The result is computed in memory when a snippet is shown (no column), and shown as a small status
mark and a hint in the detail view. Manual creation shows the result before saving and does not
block saving an invalid snippet.

### Comments and manual creation

- A comment is one free-text field on the snippet, edited in the explorer detail view (German
  labels), saved on commit. Searching matches it.
- Manual creation: an "add snippet" action in the explorer opens a sheet with text, language (a
  guess from `SnippetFilter` pre-selected, user can override) and comment. The text goes through
  `SnippetAnonymizer` and the secret residual check; the store receives `origin = manual`, skips the
  filter entirely (the chosen language is trusted), and clears a matching rejection. A text over the
  filter's byte cap, or one that still contains a secret after anonymising, is not saved and the
  sheet says why. A text that merges into an existing
  snippet becomes one of its variants and the user is told which snippet it joined.

## Decisions made with the user

- Snippets that differ only in values are merged into one snippet; the user wanted merging, not
  only a grouped view.
- Redirections such as `2>/dev/null` do not count towards the shape.
- Approach 1 (merge in storage, variants kept).

## Decisions left to the builder

Marked as the author's calls, not agreed with the user:

- Highlighting and check cover shell, SQL and YAML only.
- The check is a hand-written structural checker and never executes or spawns anything; no new
  dependency, no `bash -n`.
- One comment per snippet, not per variant or group.
- Merge key details: which word kinds are masked, token names, the representative variant being the
  most recently copied one.
- The check result is not persisted.
- Manual add may save an invalid snippet.
- Migration merge precedence (origin priority, longest comment), and extending `Migration` with a
  Swift step.
- FTS keyed per snippet over a concatenated `search_text`; `representative_variant_id` as a column.
- Which shell words are never masked (command words, `-c`/`eval`/`exec` arguments), line count must
  match for multi-line shapes, shape versioning.
- `app_name` on the snippet, manual add raising origin, `unchanged` semantics for promotion.
- Manual add trusts the chosen language and blocks oversize or secret-bearing text.
- Exact UI layout of the variant list, check mark and add sheet.

## Deviations in the build

- The snippet palette is not highlighted: it has no preview pane, only one-line rows.
- A SQL `SELECT` without a projection yields `notChecked`, not invalid: the anti-goal (no false
  "invalid" on working code) outranks the check.
- The redirect rule is narrower than "redirections do not count": only stderr redirections
  (`2>`, `2>>`), fd duplications (`2>&1`, `>&2`) and redirections to `/dev/null` are dropped. Any
  other redirection keeps its operator and a masked target, so `echo hi > /etc/hosts` and
  `echo hi` stay apart. The user's example, `2>/dev/null`, still does not count.
- More shell words stay literal than listed under "Guards against wrong merges": words with
  `$( … )`, backticks or process substitution, the argument of `-e`, `--command`, `--eval` and
  `--exec`, the command or script after a wrapper (`sudo`, `env`, `bash`, `python3`, …) and the
  remote command after the host of `ssh`.
- Comments are anonymised like snippet text, and a comment with a residual secret is refused; a
  manual add that joins a snippet with a comment tells the user the existing comment was kept.
- YAML containing `{{` or `{%` (Helm, Jinja) is `notChecked`.
- `snippet_variants.origin` records how each variant came in; it does not affect which variant
  represents the snippet.

## Proposed child tickets (order)

1. Shape key and merge in storage: migration, `SnippetShape`, store changes, delete/rejections,
   search, tests.
2. Explorer and palette on merged snippets: one row per snippet, variants in the detail view.
3. Comments: column, edit in the detail view, search.
4. Manual creation sheet.
5. Highlighter and theme mapping.
6. Validator and detail-view status.

1 blocks 2, 3 and 4; 5 and 6 are independent of the rest and of each other.

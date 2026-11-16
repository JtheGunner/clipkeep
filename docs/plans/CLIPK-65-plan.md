# Snippet Collection Extensions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge near-copy snippets into one snippet with variants, and add comments, manual creation, syntax highlighting and a syntax check for shell, SQL and YAML snippets.

**Architecture:** Snippets get a shape key (the text with variable values masked); snippets with the same language and shape share one `snippets` row and own several rows in a new `snippet_variants` table. `snippets` keeps denormalised columns for the representative variant, so list and sort stay cheap. The highlighter and the validator are pure, hand-written functions in `ClipkeepCore/Snippets`; AppKit only maps their output to colours and labels.

**Tech Stack:** Swift 6, AppKit, SQLCipher through `Database`, Swift Testing (`@Suite`, `@Test`, `#expect`), macOS 14+. No new dependencies.

**Spec:** `docs/plans/CLIPK-65-design.md`

## Global Constraints

- Swift 6, macOS 14+, Command Line Tools only (no Xcode): UI in AppKit, no SwiftUI `@State`.
- Format with `./scripts/lint.sh --fix`; test with `./scripts/test.sh --filter <Suite>`; run the full `./scripts/test.sh` before handing a task over.
- Tests use Swift Testing and `TemporaryDatabase` (`Tests/ClipkeepCoreTests/TemporaryDatabase.swift`), like the neighbouring suites.
- User-facing strings are German. Code, comments, docs and commit messages are English.
- Commit format `<type>: <description> (CLIPK-65)`, no attribution or co-author trailers.
- SQL uses bound parameters only. `Database.read`/`write` are never nested. Copied content is never logged.
- No network access, no AI, no new package dependency, no process spawned and no snippet executed (not even for the check).
- Do not change how the history is captured, ranked or purged, and do not change `ContentClassifier`.
- Existing behaviour that must keep working: rejection list on delete, trigram search over `search_text`, anonymisation before storage, `SnippetPromoter.backfill()` adds nothing on a second run.
- README, CHANGELOG (`Unreleased`) and `docs/manual-e2e-checklist.md` are updated in the task that changes the behaviour.

## Review Focus

- A real database with thousands of snippets migrates in bounded time and loses no copy count, timestamp or comment (Task 1).
- Deleting a merged snippet blocks every variant text from being captured again (Task 1).
- Merging destructive commands (`rm -rf /tmp/x`, `rm -rf /`) is accepted by the design, so the detail view must show exactly the text that Return/Copy will put on the clipboard (Task 2).
- An empty or whitespace-only manual text, one above the byte cap, and one containing a secret are refused with a message (Task 4).
- The lexer and the validator terminate in bounded time on unterminated strings, a multi-megabyte paste and non-ASCII text, and never throw (Tasks 5 and 6).
- A comment edit on a snippet that was deleted in the meantime does not crash or resurrect it (Task 3).

Order: Task 1 blocks Tasks 2, 3 and 4. Tasks 5 and 6 are independent of the rest and of each other. Documentation lines are folded into the task that changes the behaviour.

---

### Task 1: Shape key and merge in storage

**Files:**
- Create: `Sources/ClipkeepCore/Snippets/SnippetShape.swift`
- Create: `Sources/ClipkeepCore/Snippets/SnippetShapeMigration.swift`
- Modify: `Sources/ClipkeepCore/Storage/Migrator.swift` (`Migration` gains a Swift step)
- Modify: `Sources/ClipkeepCore/Storage/Schema.swift` (add `version13`, `latestVersion = 13`)
- Modify: `Sources/ClipkeepCore/Snippets/SnippetStore.swift`
- Test: `Tests/ClipkeepCoreTests/SnippetShapeTests.swift`, `SnippetStoreTests.swift`, `MigratorTests.swift`

**Interfaces:**
- Produces:
  - `Migration.init(version: Int, statements: [String], step: (@Sendable (Connection) throws -> Void)? = nil)`; `Migrator` runs `step` after the statements, in the same transaction.
  - `enum SnippetShape { static let version: Int; static func of(_ text: String, language: SnippetLanguage) -> String; static func hash(of text: String, language: SnippetLanguage) -> String }`
  - `SnippetOrigin` gains `case manual`, and `var priority: Int` (`manual` 2, `history` 1, `auto` 0).
  - `Snippet` gains `comment: String?`, `variantCount: Int`, `shapeHash: String`, `searchText: String` (folded text of all variants plus the comment).
  - `struct SnippetVariant: Sendable, Equatable { id: Int64, snippetID: Int64, text: String, createdAt: Date, lastCopiedAt: Date, copyCount: Int }`
  - `SnippetStore.variants(of snippetID: Int64) throws -> [SnippetVariant]`, newest `last_copied_at` first.
  - `add`, `list`, `search`, `delete`, `count` keep their signatures; their behaviour changes as described below.

- [ ] **Step 1: Write the failing shape tests** in `SnippetShapeTests` (suite `SnippetShapeTests`), each as `SnippetShape.hash(of:language:)` equality or inequality:
  - `pathsAreMasked`: `ls -la /mnt/a/plugin/` equals `ls -la /mnt/b/prefs/`.
  - `redirectsAreIgnored`: `ls -la /mnt/a/ 2>/dev/null` equals `ls -la /mnt/b/`; `cmd >/dev/null 2>&1` equals `cmd`.
  - `flagsAndProgramStayDistinct`: `ls -la /x` differs from `ls -l /x`; `./deploy.sh /x` differs from `./build.sh /x`; `cmd | grep foo` differs from `cmd | sort`.
  - `commandArgumentsOfDashCAreNotMasked`: `sh -c "echo a"` differs from `sh -c "echo b"`; `echo "a"` equals `echo "b"`.
  - `numbersUrlsIpsAndHashesAreMasked`: `curl http://a.example/x -m 5` equals `curl http://b.example/y -m 9`; `ping 10.0.0.1` equals `ping 10.0.0.2`.
  - `lineCountMustMatch`: a two-line shell text differs from the same text with a third line.
  - `sqlLiteralsAreMaskedAndKeywordCaseIgnored`: `SELECT * FROM t WHERE id = 5` equals `select * from t where id = 9`; `FROM t` differs from `FROM u`.
  - `yamlScalarsAreMaskedKeysAreNot`: `replicas: 2` equals `replicas: 5`; `replicas: 2` differs from `copies: 2`.
  - `anonymiserPlaceholdersStayLiteral`: `export K=<OPENAI_API_KEY>` differs from `export K=<GITHUB_TOKEN>`.
  - `languageIsPartOfTheKey`: the same text as shell and as yaml gives different hashes.
- [ ] **Step 2: Run** `./scripts/test.sh --filter SnippetShapeTests`. Expected: compile failure.
- [ ] **Step 3: Implement `SnippetShape`** per the design's Shape key section. One regex or small scanner per kind; shape tokens use a `\u{1}` prefix (`\u{1}path`, `\u{1}num`, `\u{1}str`, `\u{1}url`, `\u{1}ip`, `\u{1}hash`); `hash` is `ContentHashing.exactHash` of `"\(version):\(language.rawValue):\(of)"`. Input is bounded by the filter's byte cap, so a linear scan per line is enough.
- [ ] **Step 4: Run** `--filter SnippetShapeTests`. Expected: PASS.
- [ ] **Step 5: Write the failing store tests** in `SnippetStoreTests` (extend the suite; keep the existing tests, adapting only what the changed `Snippet` initialiser needs):
  - `sameShapeAddsAVariantNotASnippet`: add `ls -la /a/` then `ls -la /b/`; `count() == 1`, `list` returns one snippet with `variantCount == 2`, `copyCount == 2`, `text == "ls -la /b/"` (the representative is the most recently copied), `variants(of:)` returns both.
  - `sameTextBumpsTheVariant`: adding `ls -la /a/` twice leaves one variant with `copyCount == 2`.
  - `redirectVariantJoinsTheSnippet`: the three texts from CLIPK-65 (`…/spotty/ 2>/dev/null`, `…/plugin/`, `…/prefs/`) end up as one snippet with three variants.
  - `unchangedWhenNotBumping`: `add(..., bumpingExisting: false)` for a known text returns `.unchanged` and changes no count; for a new variant of a known shape it adds the variant, does not change `copyCount`, and returns `.unchanged(snippetID)`.
  - `deleteRejectsEveryVariant`: after `delete(id:)`, re-adding any variant text returns `.rejected`; `overridingRejection: true` stores it again.
  - `manualAddRaisesOrigin`: adding an `.auto` snippet's shape with origin `.manual` makes the snippet's origin `.manual`; adding `.auto` to a `.manual` snippet keeps `.manual`.
  - `searchFindsAnyVariant`: after the two adds above, `search("/a/", limit: 5)` and `search("/b/", limit: 5)` both return the one snippet exactly once.
  - `snippetSearchTextCoversAllVariants`: `snippet.searchText` contains both folded variant texts.
  - `maintenanceLeavesSnippetsAlone` and the existing rejection, search-order and migration tests keep passing.
- [ ] **Step 6: Run** `--filter SnippetStoreTests`. Expected: FAIL.
- [ ] **Step 7: Write the failing migration test** in `MigratorTests` (or `SnippetStoreTests`, next to the existing migration test): open a database migrated to version 12 only (`Migrator(migrations: Array(Schema.migrations.prefix(12)))` or the existing helper), insert three version-12 snippet rows with shapes `ls -la /a/` (count 2, `created_at` 10, `last_copied_at` 30, origin auto), `ls -la /b/` (count 3, created 5, last 20, origin history), `kubectl get pods` (count 1); migrate to 13. Expect two snippets; the merged one has `copyCount == 5`, `createdAt` 5, `lastCopiedAt` 30, origin `history`, `variantCount == 2`, and its `searchText` contains both texts; rejections from before still reject. Also: a failing step rolls back (`user_version` stays 12).
- [ ] **Step 8: Implement migration 13 and the store.**
  - `Migrator.migrate` calls `try step(connection)` after the statements and before the `user_version` pragma.
  - `version13`: statements create `snippet_variants`, add `shape_hash`, `shape_version`, `comment`, `representative_variant_id`; because `snippets.hash` is `NOT NULL UNIQUE`, rebuild `snippets` without it (create `snippets_new`, copy, drop `snippets_fts`, its triggers and the old table, rename, recreate `snippets_last_copied_at`, an index on `(language, shape_hash)`, the FTS table and the three triggers unchanged in shape). The `step` is `SnippetShapeMigration.run`, which copies each old row into one variant (using the old `hash` from before the rebuild: select it into a temporary table `snippet_variant_seed` in the statements), computes `shape_hash`/`shape_version`, then merges rows with equal `(language, shape_hash)` using the precedence in the design (summed counts, earliest `created_at`, latest `last_copied_at`, strongest origin, longest comment, representative = latest `last_copied_at`) and rewrites `search_text`. Drop the seed table at the end.
  - `SnippetStore`: `add` follows the design's Capture and store section; one private `refreshAggregates(connection, snippetID)` recomputes `text`, `app_name`, `copy_count`, `last_copied_at`, `representative_variant_id` and `search_text` (folded variants plus comment) after any variant or comment change. `delete` inserts every variant hash into `snippet_rejections` before the cascade delete. `list` and `search` select the new columns; `search` keeps `snippets_fts.rowid = s.id`.
- [ ] **Step 9: Run** `./scripts/test.sh --filter SnippetStoreTests`, `--filter SnippetShapeTests`, `--filter SnippetPromoterTests`, `--filter SnippetCaptureTests`, `--filter MigratorTests`. Expected: PASS. Fix call sites that build `Snippet` or call `add` (`SnippetPromoter`, `SnippetCapture`, tests).
- [ ] **Step 10: Docs and commit.** CHANGELOG `Unreleased`: merged snippets. Run `./scripts/lint.sh --fix`, then commit `feat: merge near-copy snippets into variants (CLIPK-65)`.

---

### Task 2: Explorer and palette on merged snippets

**Files:**
- Modify: `Sources/ClipkeepCore/Palette/PaletteRow.swift` (`init(snippet:now:calendar:)`)
- Modify: `Sources/ClipkeepCore/Snippets/SnippetExplorer.swift` (search haystack)
- Modify: `Sources/Clipkeep/SnippetExplorerWindowController.swift`
- Test: `Tests/ClipkeepCoreTests/SnippetExplorerTests.swift`, `SnippetPaletteTests.swift`

**Interfaces:**
- Consumes: `Snippet.variantCount`, `Snippet.searchText`, `SnippetStore.variants(of:)` (Task 1).
- Produces: `PaletteRow` subtitle `age · language · N× · M Varianten` (the variants part only when `M > 1`).

- [ ] **Step 1: Write the failing tests:**
  - `PaletteTests.snippetRowShowsVariantCount`: a snippet with `variantCount == 3` has a subtitle containing `3 Varianten`; with `1`, no `Varianten`.
  - `SnippetExplorerTests.searchMatchesAnyVariantText`: a snippet whose `searchText` contains `"/b/"` but whose `text` does not is found by the query `"/b/"`.
  - `SnippetExplorerTests.sortByCountUsesTheSummedCount` (the existing count sort keeps working with merged counts).
- [ ] **Step 2: Run** `--filter SnippetExplorerTests --filter SnippetPaletteTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** In `SnippetExplorer.apply`, build the haystack from `snippet.searchText + " " + (topic ?? "")` instead of `snippet.text`. In `PaletteRow(snippet:)` append the variants part.
- [ ] **Step 4: Explorer UI.** Add a `variantMenu: NSPopUpButton` to the `infoLabel` row (hidden when `variantCount == 1`), filled from `store.variants(of:)` for the selected snippet (title: first line plus `Nx · zuletzt …`). The selected variant's text is what `detailView` shows and what `copySelected` copies (default: the first, i.e. the representative). `updateSelectionState` reloads the menu and resets it to the first entry. The info label gains `N Varianten` when more than one. Keep `loadFailed` handling for a failing `variants(of:)` (show the representative only).
- [ ] **Step 5: Run** the two filters, then the full `./scripts/test.sh`. Expected: PASS. Build with `swift build`.
- [ ] **Step 6: Docs and commit.** `docs/manual-e2e-checklist.md`: explorer shows one row per command shape, the variant menu copies the chosen variant. CHANGELOG line. Commit `feat: show merged snippets with variants in the explorer (CLIPK-65)`.

---

### Task 3: Comments

**Files:**
- Modify: `Sources/ClipkeepCore/Snippets/SnippetStore.swift`
- Modify: `Sources/Clipkeep/SnippetExplorerWindowController.swift`
- Test: `Tests/ClipkeepCoreTests/SnippetStoreTests.swift`, `SnippetExplorerTests.swift`

**Interfaces:**
- Consumes: `Snippet.comment`, `refreshAggregates` (Task 1).
- Produces: `SnippetStore.setComment(id: Int64, comment: String?) throws -> Bool` (false when the snippet no longer exists; whitespace-only or empty clears the comment; text is trimmed; capped at 2000 characters).

- [x] **Step 1: Write the failing tests:**
  - `setCommentRoundTrips`: set, `list` returns it; set `"  "` clears it (`comment == nil`).
  - `setCommentIsSearchable`: after `setComment(id:, comment: "rotate nightly")`, `search("nightly", limit: 5)` returns the snippet; after clearing it, it does not.
  - `setCommentOnMissingSnippetReturnsFalse`: for an id that was deleted.
  - `longCommentIsCapped`: 5000 characters stored as 2000.
  - `commentIsFoundInTheExplorer`: `SnippetExplorer.apply` with the query `"nightly"` finds it through `searchText`.
- [x] **Step 2: Run** `--filter SnippetStoreTests`. Expected: FAIL.
- [x] **Step 3: Implement `setComment`** in one `database.write`: update `comment`, call `refreshAggregates`, return whether a row was updated.
- [x] **Step 4: Explorer UI.** A one-line `NSTextField` "Kommentar" (placeholder `Kommentar hinzufügen`) under the info label, enabled with a selection. Commit on end of editing (`controlTextDidEndEditing`) by calling `setComment`, then `reload()` keeping the selection; on `false` show `Das Snippet existiert nicht mehr.` in the info label and reload. The comment is shown in the table's detail only (no new column).
- [x] **Step 5: Run** the filters and the full suite. Expected: PASS.
- [x] **Step 6: Docs and commit.** Checklist and CHANGELOG; commit `feat: add comments to snippets (CLIPK-65)`.

---

### Task 4: Manual creation

**Files:**
- Create: `Sources/ClipkeepCore/Snippets/SnippetCreator.swift`
- Modify: `Sources/Clipkeep/SnippetExplorerWindowController.swift`
- Test: `Tests/ClipkeepCoreTests/SnippetCreatorTests.swift`

**Interfaces:**
- Consumes: `SnippetStore.add`, `setComment` (Tasks 1 and 3), `SnippetAnonymizer`, `SecretDetector`, `SnippetFilter`.
- Produces:
  - `enum SnippetCreateOutcome: Sendable, Equatable { case created(Int64), joined(Int64), empty, tooLarge, residualSecret }`
  - `struct SnippetCreator: Sendable { init(store: SnippetStore, anonymizer: SnippetAnonymizer = SnippetAnonymizer(), residualDetector: SecretDetector = SecretDetector()); func guessLanguage(_ text: String) -> SnippetLanguage; func create(text: String, language: SnippetLanguage, comment: String?) throws -> SnippetCreateOutcome }`

- [ ] **Step 1: Write the failing tests** (suite `SnippetCreatorTests`):
  - `createStoresAManualSnippet`: `.created(id)`, the snippet has `origin == .manual`, the chosen language and the comment.
  - `createAnonymisesSecrets`: a text containing a secret-like token (use the fixtures `SnippetAnonymizerTests` uses) is stored with the placeholder, never the value.
  - `emptyAndWhitespaceTextIsRefused`: `.empty`, nothing stored.
  - `oversizeTextIsRefused`: a text above `SnippetFilter.Threshold.maximumBytes` returns `.tooLarge`.
  - `residualSecretIsRefused`: use the same fixture `SnippetPromoterTests` uses for `.residualSecret`.
  - `joiningAnExistingShapeReportsJoined`: after an auto snippet `ls -la /a/`, creating `ls -la /b/` returns `.joined(sameID)`, the snippet has two variants and origin `.manual`; a given comment is set only when the snippet had none.
  - `createClearsARejection`: delete a snippet, create the same text, `.created`.
  - `guessLanguageUsesTheFilterAndDefaultsToShell`.
- [ ] **Step 2: Run** `--filter SnippetCreatorTests`. Expected: compile failure.
- [ ] **Step 3: Implement `SnippetCreator`.** Order: trim check (`empty`), source size cap as in `SnippetPromoter`, anonymise, size cap on the anonymised text, residual check, `store.add(origin: .manual, appName: nil, overridingRejection: true)`, map `.inserted` to `created` and `.bumped`/`.unchanged` to `joined`, then `setComment` as specified. The filter is not consulted for the verdict, only by `guessLanguage` (`SnippetFilter.evaluate(text) ?? .shell`).
- [ ] **Step 4: Run** `--filter SnippetCreatorTests`. Expected: PASS.
- [ ] **Step 5: Explorer UI.** A button `Neu …` in the footer opens a sheet (`NSWindow` sheet, German labels): multiline text field (`Text`), language popup (`Sprache`, pre-selected from `guessLanguage` as the text changes until the user picks one), comment field (`Kommentar`), buttons `Speichern` and `Abbrechen`. `Speichern` calls `create`; `.empty`, `.tooLarge` and `.residualSecret` show `Der Text ist leer.`, `Der Text ist zu gross für ein Snippet.` and `Der Text enthält ein Geheimnis, das nicht entfernt werden konnte.` in the sheet and keep it open; `.created`/`.joined` close it, reload and select the snippet; `.joined` additionally sets the info label to `Zu einem bestehenden Snippet hinzugefügt.`.
- [ ] **Step 6: Run** the full suite and `swift build`. Expected: PASS.
- [ ] **Step 7: Docs and commit.** README (the section that lists snippet features), checklist, CHANGELOG; commit `feat: add snippets by hand (CLIPK-65)`.

---

### Task 5: Syntax highlighting

**Files:**
- Create: `Sources/ClipkeepCore/Snippets/SnippetHighlighter.swift`
- Create: `Sources/Clipkeep/SnippetSyntaxStyle.swift`
- Modify: `Sources/Clipkeep/SnippetExplorerWindowController.swift`, `Sources/Clipkeep/Theme.swift`
- Test: `Tests/ClipkeepCoreTests/SnippetHighlighterTests.swift`

**Interfaces:**
- Produces:
  - `enum SnippetTokenKind: Sendable { case keyword, string, number, comment, op, variable, key, punctuation }`
  - `struct SnippetToken: Sendable, Equatable { kind: SnippetTokenKind; range: NSRange }`
  - `enum SnippetHighlighter { static func tokens(in text: String, language: SnippetLanguage) -> [SnippetToken] }` (sorted by location, non-overlapping, ranges inside the text's UTF-16 length)
  - `enum SnippetSyntaxStyle { static func attributedString(for text: String, language: SnippetLanguage) -> NSAttributedString }` (Clipkeep target)

- [ ] **Step 1: Write the failing tests** (suite `SnippetHighlighterTests`; helper `kinds(_ text, _ language) -> [(String, SnippetTokenKind)]` mapping tokens back to substrings):
  - `shellFlagsVariablesStringsAndComments`: `grep -rn "foo" $HOME # note` yields `-rn` as `.variable`, `"foo"` as `.string`, `$HOME` as `.variable`, `# note` as `.comment`, `grep` as `.keyword`.
  - `shellPipesAreOperators`: `|`, `&&`, `>` are `.op`.
  - `sqlKeywordsAreCaseInsensitive`: `select`, `FROM`, `Where` are `.keyword`; `'x'` is `.string`; `42` is `.number`; `-- c` is `.comment`.
  - `yamlKeysValuesAndComments`: in `name: web # c`, `name` is `.key`, `web` is not tokenised as a keyword, `# c` is `.comment`; `- item` marks `-` as `.punctuation`; `replicas: 3` has `3` as `.number`.
  - `unterminatedStringRunsToTheEndWithoutCrashing` for all three languages.
  - `rangesAreOrderedNonOverlappingAndInBounds` over a text with emoji and umlauts (UTF-16 ranges).
  - `largeInputIsBounded`: a 1 MB single-line text returns within the `PerformanceBudget` helper's budget (see `Tests/ClipkeepCoreTests/PerformanceBudget.swift`).
  - `emptyTextHasNoTokens`.
- [ ] **Step 2: Run** `--filter SnippetHighlighterTests`. Expected: compile failure.
- [ ] **Step 3: Implement the lexers.** One small scanner per language over `Array(text.utf16)`-based indices, single pass, no regex backtracking. Shell: first word of a command is `.keyword`. SQL: a fixed keyword set (select, from, where, join, insert, into, values, update, set, delete, create, table, drop, alter, group, order, by, having, limit, and, or, not, null, as, on, with, union, distinct, case, when, then, else, end, in, is, like, exists, if). YAML: key = text before the first `: ` of a line at any indentation.
- [ ] **Step 4: Run** `--filter SnippetHighlighterTests`. Expected: PASS.
- [ ] **Step 5: AppKit mapping.** `SnippetSyntaxStyle.attributedString` applies `Typography.mono` and a foreground colour per kind, defined in `Theme.swift` with dynamic `NSColor` values for light and dark. Use it in `updateSelectionState` for the detail view (set `textStorage`, keep `isRichText = false` semantics by only styling, not allowing edits). Palette rows stay plain: the palette has no preview pane.
- [ ] **Step 6: Run** the full suite and `swift build`. Expected: PASS.
- [ ] **Step 7: Docs and commit.** Checklist (open the explorer in light and dark appearance), CHANGELOG; commit `feat: highlight snippet syntax (CLIPK-65)`.

---

### Task 6: Syntax check

**Files:**
- Create: `Sources/ClipkeepCore/Snippets/SnippetValidator.swift`
- Modify: `Sources/Clipkeep/SnippetExplorerWindowController.swift`
- Test: `Tests/ClipkeepCoreTests/SnippetValidatorTests.swift`

**Interfaces:**
- Consumes: `SnippetHighlighter.tokens` may be reused for string and comment ranges; the validator does not depend on it for correctness.
- Produces:
  - `enum SnippetCheck: Sendable, Equatable { case valid, invalid(hint: String), notChecked }` (hints in German)
  - `enum SnippetValidator { static func check(_ text: String, language: SnippetLanguage) -> SnippetCheck }`

- [ ] **Step 1: Write the failing tests** (suite `SnippetValidatorTests`):
  - Shell: `ls -la /x | grep foo` is `.valid`; `echo "abc` is `.invalid` (hint mentions the quote); `echo $(date` is `.invalid`; `ls |` is `.invalid`; `cmd &&` is `.invalid`; a function definition `f() { echo a; }` and a `case … esac` block are `.notChecked`, never `.invalid`.
  - SQL: `SELECT id FROM t WHERE a = 1` is `.valid`; `SELECT id FROM t WHERE (a = 1` is `.invalid`; `SELECT 'abc FROM t` is `.invalid`; `UPDATE t WHERE a = 1` is `.invalid`; `INSERT INTO t` is `.invalid`; a statement starting with an unknown verb (`PRAGMA user_version`) is `.notChecked`.
  - YAML: `a:\n  b: 1\n  c: 2` is `.valid`; a tab used for indentation is `.invalid`; `a: [1, 2` is `.invalid`; `a: "x` is `.invalid`; inconsistent indentation (`a:\n  b: 1\n   c: 2`) is `.invalid`.
  - `emptyTextIsNotChecked`.
  - `largeInputIsBounded`: 1 MB input returns within the `PerformanceBudget` helper's budget for every language.
- [ ] **Step 2: Run** `--filter SnippetValidatorTests`. Expected: compile failure.
- [ ] **Step 3: Implement the checkers** as described in the design's Syntax check section: a single-pass scanner per language tracking quote state and bracket depth; any construct outside the modelled subset returns `.notChecked` for the whole snippet. When unsure, `.notChecked`.
- [ ] **Step 4: Run** `--filter SnippetValidatorTests`. Expected: PASS.
- [ ] **Step 5: UI.** The explorer info label gets a leading mark and text: `✓ Syntax gültig`, `✗ Syntax ungültig: <hint>` or nothing for `.notChecked`; computed for the shown variant in `updateSelectionState`. The manual-creation sheet (Task 4) shows the same result under the text field, updated as the text changes, and never disables `Speichern`. If Task 4 is not merged yet, only the info label changes.
- [ ] **Step 6: Run** the full suite and `swift build`. Expected: PASS.
- [ ] **Step 7: Docs and commit.** README (snippet section), checklist, CHANGELOG; commit `feat: check snippet syntax (CLIPK-65)`.

# Snippet Collection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A separate, automatically filled, searchable collection of shell, SQL and YAML snippets in Clipkeep, with secrets anonymised, opened from a second hotkey.

**Architecture:** A new `ClipkeepCore/Snippets` module owns storage (`snippets` table, no link to `contents`), a strict pure filter and a secret anonymiser. `CapturePipeline` gets a snippet stage that runs on the normalised text before the secret skip. The existing palette gains a second source and mode; the history window gains "Als Snippet speichern".

**Tech Stack:** Swift 6, AppKit, SQLCipher through `Database`, Swift Testing (`@Suite`, `@Test`, `#expect`), macOS 14+.

**Spec:** `docs/plans/CLIPK-54-design.md`

## Global Constraints

- Swift 6, macOS 14+, Command Line Tools only (no Xcode): UI in AppKit, no SwiftUI `@State`.
- Format with `./scripts/lint.sh --fix`; test with `./scripts/test.sh --filter <Suite>`; run the full `./scripts/test.sh` before handing a task over.
- Tests use Swift Testing and `TemporaryDatabase` (`Tests/ClipkeepCoreTests/TemporaryDatabase.swift`), like the neighbouring suites.
- User-facing strings are German. Code, comments, docs and commit messages are English.
- Commit format `<type>: <description> (CLIPK-<child ticket>)`, no attribution or co-author trailers.
- SQL uses bound parameters only. `Database.read`/`write` are never nested. Copied content is never logged.
- No network access, no AI at runtime.
- Do not change how the history is captured, ranked or purged, and do not change `ContentClassifier`.

## Review Focus

- A multi-megabyte paste or tens of thousands of lines must not stall capture: the filter and anonymiser return in bounded time (Task 2).
- CRLF line endings and trailing whitespace must not change the filter's verdict (Task 2).
- Git SHAs, UUIDs and long paths in a shell command must not be replaced by placeholders (Task 2).
- The same text copied twice, or after a restart, bumps the existing snippet instead of adding a second one (Task 1).
- A deleted snippet is not captured again, but promoting it by hand brings it back (Tasks 1 and 6).
- Opening the snippet palette with zero snippets shows an empty list and does not crash (Task 5).

Order: Tasks 1 and 2 are independent. Task 3 needs 2 and ends with a **hand-off to the user** before anything else merges. Task 4 needs 1 to 3, Task 5 needs 1, Task 6 needs 1, 2 and 5. Each task is one child ticket of CLIPK-54 on its own branch; documentation lines are folded into the tasks.

---

### Task 1: Snippet storage

**Files:**
- Modify: `Sources/ClipkeepCore/Storage/Schema.swift` (add `version12`, `latestVersion = 12`)
- Create: `Sources/ClipkeepCore/Snippets/SnippetStore.swift`
- Test: `Tests/ClipkeepCoreTests/SnippetStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum SnippetLanguage: String, Sendable, CaseIterable { case shell, sql, yaml }`
  - `enum SnippetOrigin: String, Sendable { case auto, history }`
  - `struct Snippet: Sendable, Equatable { id: Int64, text: String, language: SnippetLanguage, origin: SnippetOrigin, appName: String?, createdAt: Date, lastCopiedAt: Date, copyCount: Int }`
  - `enum SnippetAddOutcome: Sendable, Equatable { case inserted(Int64), bumped(Int64), rejected }`
  - `struct SnippetStore: Sendable` with `init(database: Database)`, `add(text: String, language: SnippetLanguage, origin: SnippetOrigin, appName: String?, overridingRejection: Bool = false, at: Date = Date()) throws -> SnippetAddOutcome`, `list(limit: Int) throws -> [Snippet]`, `search(_ query: String, limit: Int) throws -> [Snippet]`, `delete(id: Int64) throws -> Bool`, `count() throws -> Int`

- [ ] **Step 1: Write the failing tests** in `SnippetStoreTests` (suite `SnippetStoreTests`):
  - `addInsertsAndListReturnsNewestFirst`: two adds with `at` one minute apart, `list(limit: 10)` returns the later one first.
  - `addingTheSameTextBumpsInsteadOfDuplicating`: second `add` returns `.bumped(id)`, `count() == 1`, `copyCount == 2`, `lastCopiedAt` is the later date.
  - `deleteRemovesAndRemembersTheText`: `delete(id:)` returns true, `count() == 0`, re-adding the same text returns `.rejected`.
  - `overridingARejectionStoresAgain`: after delete, `add(..., overridingRejection: true)` returns `.inserted`.
  - `searchFindsByTrigramAndShortTerms`: with snippets "SELECT * FROM orders" and "kubectl get pods", `search("orders", limit: 5)` returns the first only; `search("ku", limit: 5)` (two characters) returns the second only; a German query `"ÜBER"` finds a snippet containing "über" (folded).
  - `searchOrdersByRelevanceThenCopyCountThenRecency`.
  - `maintenanceLeavesSnippetsAlone`: add a snippet, run `MaintenanceService(database:).run()`, `count()` is still 1.
  - `migrationCreatesTables`: after `Schema.migrator.migrate`, `snippets`, `snippets_fts` and `snippet_rejections` exist (query `sqlite_master`).
- [ ] **Step 2: Run** `./scripts/test.sh --filter SnippetStoreTests`. Expected: compile failure (types missing).
- [ ] **Step 3: Implement** migration `version12` with the columns from the spec's Storage section (`snippets`: `id`, `text`, `hash` unique, `language`, `origin`, `app_name`, `search_text`, `created_at`, `last_copied_at`, `copy_count`; `snippet_rejections(hash TEXT PRIMARY KEY)`), an FTS5 trigram table `snippets_fts` over `search_text` with insert/delete/update triggers copied from `contents_fts` (version 2), then `SnippetStore`. Hash with `ContentHashing.exactHash(text)`, fold with `SearchText.fold`. `search` mirrors `SearchService`: terms of three or more characters through `snippets_fts MATCH` ordered by `bm25(snippets_fts), copy_count DESC, last_copied_at DESC`; shorter terms through `instr(search_text, ?) > 0`; an empty query behaves like `list`. `delete` removes the row and inserts the hash into `snippet_rejections` in one `database.write`. `add` with `overridingRejection` deletes the rejection first.
- [ ] **Step 4: Run** `./scripts/test.sh --filter SnippetStoreTests` and `--filter MigratorTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: add snippet storage (CLIPK-<child>)`, after `./scripts/lint.sh --fix`.

---

### Task 2: Snippet filter and anonymiser

**Files:**
- Create: `Sources/ClipkeepCore/Snippets/SnippetFilter.swift`, `Sources/ClipkeepCore/Snippets/SnippetAnonymizer.swift`
- Test: `Tests/ClipkeepCoreTests/SnippetFilterTests.swift`, `Tests/ClipkeepCoreTests/SnippetAnonymizerTests.swift`

**Interfaces:**
- Consumes: `SnippetLanguage` (Task 1), `SecretDetector.detect(in:) -> [SecretMatch]`, `ContentClassifier.classify(_:) -> ContentKind`.
- Produces:
  - `enum SnippetFilter { static func evaluate(_ text: String) -> SnippetLanguage? }`
  - `struct SnippetAnonymizer: Sendable` with `init(detector: SecretDetector = SecretDetector())` and `func anonymize(_ text: String) -> String`

- [ ] **Step 1: Write the failing filter tests.** Table-driven (`@Test(arguments:)`), accepted:
  - `docker run --rm -v "$PWD":/app -w /app node:20 npm test` → `.shell`
  - `kubectl get pods -n prod | grep Crash` followed by a second line `kubectl delete pod web-1 -n prod` → `.shell`
  - `SELECT u.id, count(*) FROM users u JOIN orders o ON o.user_id = u.id GROUP BY u.id HAVING count(*) > 5;` → `.sql`
  - `services:\n  web:\n    image: nginx:1.27\n    ports:\n      - "80:80"` → `.yaml`

  Rejected (`nil`): `cd src`, `ls`, `git status`, `let count = 5`, `name: Alice`, `SELECT`, `FOO=bar\nBAZ=qux`, `https://example.com/a/b`, `{"a": 1}`, a three-line stack trace, and the prose sentence `Please run the query again tomorrow after lunch`.

  Review Focus tests: `crlfDoesNotChangeTheVerdict` (the YAML example with `\r\n` and trailing spaces still returns `.yaml`); `hugeInputReturnsInBoundedTime` (a 2 MB string of repeated `echo hello | cat\n` returns within `PerformanceBudget.limit(1.0)` seconds, no verdict asserted).
- [ ] **Step 2: Write the failing anonymiser tests.**
  - `replacesKeyValueValueOnly`: `export DB_PASSWORD=hunter2hunter2` becomes `export DB_PASSWORD=<VALUE>`.
  - `replacesKnownTokenFormats`: a text containing `sk-ant-api03-` followed by 30 letters and digits yields `<ANTHROPIC_API_KEY>` and does not contain the key; same pattern for `ghp_` plus 36 characters → `<GITHUB_TOKEN>`.
  - `replacesSeveralSecretsWithoutShiftingRanges`: two secrets in one text are both replaced and the text between them is unchanged.
  - `leavesHashesUuidsAndPathsAlone`: `git checkout 3f786850e387550fdab836ed7e265a98c0ffee12 -- /usr/local/etc/some/very/long/path/file.conf` and a UUID argument come back unchanged.
  - `textWithoutSecretsIsReturnedUnchanged`.
- [ ] **Step 3: Run** `./scripts/test.sh --filter SnippetFilterTests` and `--filter SnippetAnonymizerTests`. Expected: compile failure.
- [ ] **Step 4: Implement.**
  - `SnippetFilter.evaluate`: normalise line breaks and trim first; inspect at most the first 60 lines and 32 KiB, like the classifier, so cost stays bounded; run `ContentClassifier.classify` and reject `url`, `email`, `path`, `number`, `json`, `stacktrace`, `secret`; then the shell, SQL and YAML rules from the spec's Filter section. Keep the starting thresholds as named constants in one place, so Task 3 can tune them.
  - `SnippetAnonymizer.anonymize`: `detector.detect(in:)`, replace ranges from last to first. Placeholders: `openAIKey` `<OPENAI_API_KEY>`, `anthropicKey` `<ANTHROPIC_API_KEY>`, `githubToken` `<GITHUB_TOKEN>`, `awsAccessKeyID` `<AWS_ACCESS_KEY_ID>`, `slackToken` `<SLACK_TOKEN>`, `gitlabToken` `<GITLAB_TOKEN>`, `stripeKey` `<STRIPE_KEY>`, `googleAPIKey` `<GOOGLE_API_KEY>`, `jwt` `<JWT>`, `privateKey` `<PRIVATE_KEY>`, `keyValueSecret` `<VALUE>`, `highEntropyToken` `<TOKEN>`. The detector's `keyValueSecret` range already covers the value only.
- [ ] **Step 5: Run** both suites. Expected: PASS. Lint, then commit `feat: add snippet filter and secret anonymiser (CLIPK-<child>)`.

---

### Task 3: Evaluate the filter against the real history (user gate)

**Files:**
- Create: `Sources/ClipkeepCore/Snippets/SnippetEvaluation.swift`
- Modify: `Sources/ClipkeepEval/main.swift`, `eval/README.md`
- Test: `Tests/ClipkeepCoreTests/SnippetEvaluationTests.swift`

**Interfaces:**
- Consumes: `SnippetFilter`, `SnippetAnonymizer`, `Database`.
- Produces: `struct SnippetEvaluationReport: Sendable { accepted: [Entry], rejectedCodeLike: [Entry], examined: Int }` where `Entry` is `(language: SnippetLanguage?, text: String)`; `enum SnippetEvaluation { static func run(database: Database, rejectedLimit: Int = 50) throws -> SnippetEvaluationReport }`; CLI `clipkeep-eval --snippets [--report FILE]`.

- [ ] **Step 1: Write the failing tests** (`SnippetEvaluationTests`): a `TemporaryDatabase` filled through `ContentStore.record` with one SQL statement, one `ls`, one deleted entry containing code and one parked-secret placeholder (`kind: .secret`). `run` returns `examined == 2` (deleted and secret excluded), the SQL in `accepted` with `.sql`, and `ls` neither accepted nor in `rejectedCodeLike`; a multi-line non-code text with three lines appears in `rejectedCodeLike`.
- [ ] **Step 2: Run** `./scripts/test.sh --filter SnippetEvaluationTests`. Expected: compile failure.
- [ ] **Step 3: Implement** `SnippetEvaluation.run` over non-deleted, non-secret `contents` ordered by `last_copied_at DESC`, applying anonymiser then filter. "Code-like but rejected" means `ContentClassifier` kind `command` or `code`, or at least three lines. Extend `clipkeep-eval` with `--snippets`: open `~/Library/Application Support/Clipkeep/clipkeep.db` with `KeychainDatabaseKeyStore().loadOrCreateKey()` (the same path and key store `AppDatabase.open` uses), print accepted and rejected entries grouped, to stdout or `--report FILE`. Document in `eval/README.md` that the report contains private clipboard content and must be written outside the repository. Expect a one-time Keychain prompt for the eval binary.
- [ ] **Step 4: Run** `./scripts/test.sh --filter SnippetEvaluationTests`. Expected: PASS. Lint, commit `feat: add snippet filter evaluation against the history (CLIPK-<child>)`.
- [ ] **Step 5: Hand off to the user (gate).** Run `swift run clipkeep-eval --snippets --report <scratch path>`, give the user the report path and the counts. The user reviews it. Sign-off bar: in a sample of about 30 accepted entries at most 3 are junk and no more than a few expected snippets are missing. If not met, adjust the thresholds from Task 2, extend `SnippetFilterTests` with the misjudged examples (synthetic, no real content), and repeat. **Tasks 4 to 6 do not merge before the sign-off.**

---

### Task 4: Capture integration

**Files:**
- Create: `Sources/ClipkeepCore/Snippets/SnippetCapture.swift`, `Sources/ClipkeepCore/Snippets/SnippetCaptureControl.swift`
- Modify: `Sources/ClipkeepCore/Capture/CapturePipeline.swift`, `Sources/Clipkeep/AppDelegate.swift`, `Sources/Clipkeep/StatusItemController.swift`, `CHANGELOG.md`
- Test: `Tests/ClipkeepCoreTests/SnippetCaptureTests.swift`

**Interfaces:**
- Consumes: `SnippetStore`, `SnippetFilter`, `SnippetAnonymizer`, `CopyContext`, `SettingsStore`, `CaptureControlError.corruptSetting(String)`.
- Produces:
  - `final class SnippetCaptureControl: @unchecked Sendable` with `init(settings: SettingsStore) throws`, `init(enabled: Bool = true)`, `var isEnabled: Bool`, `func setEnabled(_ value: Bool) throws`; setting key `snippets.captureEnabled`, absent means enabled, any value other than `"0"`/`"1"` throws `corruptSetting`.
  - `struct SnippetCapture: Sendable` with `init(store: SnippetStore, control: SnippetCaptureControl, anonymizer: SnippetAnonymizer = SnippetAnonymizer(), onError: @escaping @Sendable (Error) -> Void)` and `func capture(text: String, context: CopyContext, at: Date)`; it never throws.
  - `CapturePipeline.init` gains `snippets: SnippetCapture? = nil` as the last parameter.

- [ ] **Step 1: Write the failing tests** (`SnippetCaptureTests`, building `CapturePipeline` with `TemporaryDatabase`, `PasteboardSnapshot(changeCount:types:text:)` as in `CaptureTests`):
  - `codeCopyBecomesASnippetAndAHistoryEntry`: a SQL statement is stored as a snippet (`origin == .auto`, `appName` from the context) and `process` returns `.recorded`.
  - `secretBearingCodeIsStoredAnonymisedAndSkippedInTheHistory`: a shell command with `export DB_PASSWORD=hunter2hunter2` yields `.skipped(.secret)`, one snippet whose text contains `<VALUE>` and not `hunter2hunter2`.
  - `nothingIsCapturedWhenPausedBlockedConcealedOwnCopyOrIgnored`: one case per reason (`.paused`, a blocked bundle ID, `org.nspasteboard.ConcealedType`, the `OwnCopyWriter.markerType`, an ignore pattern); the snippet count stays 0.
  - `nothingIsCapturedWhenSwitchedOff`: `SnippetCaptureControl(enabled: false)`.
  - `aDeletedSnippetIsNotCapturedAgain`: capture, `delete`, copy again, count is 0.
  - `aSnippetStoreFailureDoesNotBlockTheHistory`: drop the `snippets` table through `database.write`, `process` still returns `.recorded` and `onError` was called once.
  - `controlPersistsAndRejectsCorruptValues` (`SnippetCaptureControl` with a `SettingsStore`).
- [ ] **Step 2: Run** `./scripts/test.sh --filter SnippetCaptureTests`. Expected: compile failure.
- [ ] **Step 3: Implement.** In `CapturePipeline.process`, call `snippets?.capture(text:context:at:)` right after the `control.matchesPattern(text)` check and before the secret branch, using `source` as the context. `SnippetCapture.capture`: return if the control is off; anonymise; `SnippetFilter.evaluate`; return if `nil`; `store.add(..., origin: .auto, appName: context.appName)`; catch errors into `onError`. In `AppDelegate.startCapture` build the store, control and capture and pass them to the pipeline; log errors without content. Add a menu item "Snippets automatisch erfassen" with a checkmark to `StatusItemController`, enabled after attach, toggling `setEnabled`. Add a CHANGELOG line under Unreleased/Added.
- [ ] **Step 4: Run** `./scripts/test.sh --filter SnippetCaptureTests`, then the full `./scripts/test.sh`. Expected: PASS. Lint, commit `feat: capture snippets from the clipboard (CLIPK-<child>)`.

---

### Task 5: Palette snippet mode and second hotkey

**Files:**
- Create: `Sources/ClipkeepCore/Snippets/SnippetPaletteSearch.swift`
- Modify: `Sources/ClipkeepCore/Palette/PaletteRow.swift`, `Sources/Clipkeep/PaletteController.swift`, `Sources/Clipkeep/AppDelegate.swift`, `docs/manual-e2e-checklist.md`, `CHANGELOG.md`
- Test: `Tests/ClipkeepCoreTests/SnippetPaletteTests.swift`

**Interfaces:**
- Consumes: `SnippetStore.list/search/delete`, `PaletteRow`, `PaletteSearch`.
- Produces:
  - `protocol PaletteSource: Sendable { func rows(for query: String, now: Date) throws -> [PaletteRow] }`; `PaletteSearch` conforms.
  - `PaletteRow.init(snippet: Snippet, now: Date = Date(), calendar: Calendar = .current)`: `contentID` is the snippet id, `title` is the first non-empty line, `subtitle` is `<age> · <Shell|SQL|YAML> · <count>×` (count only above 1), the symbol kind is `command` for shell and `code` otherwise.
  - `struct SnippetPaletteSearch: PaletteSource` with `init(store: SnippetStore)`, limit `PaletteSearch.rowLimit`.
  - `PaletteController`: `init(history: any PaletteSource, snippets: any PaletteSource, deleteSnippet: @escaping (Int64) throws -> Void, copyWriter: OwnCopyWriter = OwnCopyWriter())`, `func toggle(mode: PaletteMode)` with `enum PaletteMode { case history, snippets }`.

- [ ] **Step 1: Write the failing tests** (`SnippetPaletteTests`): `emptyQueryListsNewestFirst`; `queryFiltersAndOrders`; `rowShowsFirstLineAndLanguageAndCount` (title `SELECT 1`, subtitle contains `SQL` and `2×`); `zeroSnippetsGiveAnEmptyList` (no throw); `historyPaletteSearchStillConformsAndIsUnchanged` (existing `PaletteTests` keep passing).
- [ ] **Step 2: Run** `./scripts/test.sh --filter SnippetPaletteTests`. Expected: compile failure.
- [ ] **Step 3: Implement** the protocol, `SnippetPaletteSearch` and the row initialiser. Rework `PaletteController` to hold both sources: placeholder `Snippets durchsuchen …` in snippet mode; `toggle(mode:)` hides when the palette is visible in that mode and otherwise shows in that mode; Tab switches mode while open (handle `insertTab:` in `doCommandBy`); Command+Delete deletes the selected row in snippet mode through `deleteSnippet` and reloads, and must not delete query text (handle it as a key equivalent on the panel, not in the field editor). In `AppDelegate`, register a second `GlobalHotKey` (`kVK_ANSI_S`, `controlKey | optionKey`) calling `palette.toggle(mode: .snippets)`; the first hotkey calls `toggle(mode: .history)`. A failed second registration must not affect the first.
- [ ] **Step 4: Run** `./scripts/test.sh --filter SnippetPaletteTests`, `--filter PaletteTests`, then the full suite. Add the manual steps to `docs/manual-e2e-checklist.md` (hotkey opens snippet mode, Tab switches, Return copies and does not re-capture, Command+Delete removes). Add a CHANGELOG line. Lint, commit `feat: search snippets in the palette (CLIPK-<child>)`.

---

### Task 6: Promote from history, delete and backfill

**Files:**
- Create: `Sources/ClipkeepCore/Snippets/SnippetPromoter.swift`
- Modify: `Sources/Clipkeep/HistoryWindowController.swift`, `Sources/Clipkeep/StatusItemController.swift`, `Sources/Clipkeep/AppDelegate.swift`, `README.md`, `docs/manual-e2e-checklist.md`, `CHANGELOG.md`
- Test: `Tests/ClipkeepCoreTests/SnippetPromoterTests.swift`

**Interfaces:**
- Consumes: `SnippetStore.add(... overridingRejection:)`, `SnippetFilter`, `SnippetAnonymizer`, `Database`.
- Produces:
  - `enum PromotionOutcome: Sendable, Equatable { case stored(Int64), needsLanguage, unavailable }`
  - `struct BackfillReport: Sendable, Equatable { examined: Int, added: Int }`
  - `struct SnippetPromoter: Sendable` with `init(database: Database, store: SnippetStore, anonymizer: SnippetAnonymizer = SnippetAnonymizer())`, `promote(contentID: Int64, language: SnippetLanguage?) throws -> PromotionOutcome`, `backfill() throws -> BackfillReport`

- [ ] **Step 1: Write the failing tests** (`SnippetPromoterTests`):
  - `promoteStoresTheAnonymisedTextAsHistoryOrigin`.
  - `promoteWithoutRecognisedLanguageAsksForOne`: `ls` returns `.needsLanguage`; with `language: .shell` it returns `.stored`.
  - `promoteIgnoresDeletedAndSecretPlaceholderEntries`: `.unavailable`.
  - `promoteRevivesADeletedSnippet`: add, `store.delete`, `promote` returns `.stored`.
  - `backfillAddsOnlyAcceptedEntries`: a history with SQL, `ls` and a deleted code entry yields `added == 1`.
  - `backfillIsIdempotent`: a second run has `added == 0`.
  - `backfillRespectsRejections`: a deleted snippet is not re-added by `backfill`.
- [ ] **Step 2: Run** `./scripts/test.sh --filter SnippetPromoterTests`. Expected: compile failure.
- [ ] **Step 3: Implement** `promote` (load the non-deleted, non-secret content, anonymise, language from the argument else the filter, `store.add(..., origin: .history, overridingRejection: true)`) and `backfill` (page through non-deleted, non-secret contents 500 at a time, anonymise, filter, `store.add(..., origin: .history, appName: nil)` without overriding rejections; count examined and added). In the history window add "Als Snippet speichern" to the entry actions; when the outcome is `.needsLanguage`, show an alert with a Shell, SQL, YAML choice and promote again; show a short note on success through the existing header-note mechanism. Add a status menu item "Snippets aus Verlauf übernehmen …" that confirms, runs `backfill` off the main thread and reports the counts in an alert. Update the README feature table (snippets, second hotkey) and the manual checklist, add a CHANGELOG line.
- [ ] **Step 4: Run** `./scripts/test.sh --filter SnippetPromoterTests`, then the full suite and `./scripts/lint.sh`. Expected: PASS and clean. Commit `feat: promote history entries and backfill snippets (CLIPK-<child>)`.

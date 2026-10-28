# Contributing to Clipkeep

Thanks for your interest! Issues and pull requests are welcome.

## Reporting issues

Open an issue and include:

- your macOS version and how Clipkeep was installed,
- what you did, what you expected and what happened,
- steps to reproduce, if you have them.

Never paste real clipboard contents, tokens or passwords into an issue.

## Proposing changes

1. Fork the repository and branch off `main` (`feat/…`, `fix/…`, `docs/…`).
2. Keep each pull request focused on one change and add or update a test for any behaviour change.
3. Write commit messages as `<type>: <description>` with a type of `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci` or `build`.
4. Update `README.md` and `CHANGELOG.md` when you change user-visible behaviour.
5. Open a pull request against `main` and describe what you changed and how you tested it.

## Local development

Requirements: macOS 14 or newer and the Xcode Command Line Tools (full Xcode is not needed).

```bash
swift build                 # debug build
./scripts/test.sh           # run the test suite
./scripts/lint.sh           # check formatting (--fix rewrites files)
./scripts/bundle-app.sh     # assemble build/Clipkeep.app (ad-hoc signed)
```

Run the tests and the linter before opening a pull request. Changes to search ranking should also be checked with `./scripts/eval.sh`; see [`eval/README.md`](eval/README.md).

## Code and language conventions

- Code, comments, identifiers, commit messages and documentation are written in English.
- Only user-facing text in the app (menus, dialogs, notifications) may be German or English.
- Clipkeep makes no network connections; changes must not add any.

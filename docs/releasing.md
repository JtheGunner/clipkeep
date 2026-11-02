# Releasing

Clipkeep ships as a zip attached to a GitHub release. The Homebrew cask in
[`JtheGunner/homebrew-tap`](https://github.com/JtheGunner/homebrew-tap) downloads that zip, so the
repository and the release asset must be public.

## Before the repository goes public

The repository becomes public together with the first release. Before that:

1. README has the Installation, License, Changelog and Contributing sections.
2. `LICENSE` and `CONTRIBUTING.md` exist.
3. `CHANGELOG.md` has an entry for the first version (rename `[Unreleased]`).
4. The version tag exists (see below).
5. The git history is scanned for secrets (for example `gitleaks detect`). Rotate anything it finds.

## Publishing a version

Use the Mac that holds the `Clipkeep Local Signing` certificate. Every release must be signed with
that same certificate: the Keychain approval and the Accessibility and Automation grants are bound
to it, so a different identity makes every user grant them again.

1. Move the `[Unreleased]` entries in `CHANGELOG.md` under `## [x.y.z] - YYYY-MM-DD` and commit.
2. Tag and push: `git tag vx.y.z && git push origin vx.y.z`.
3. Build the archive: `VERSION=x.y.z ./scripts/release.sh`. This writes
   `build/Clipkeep-x.y.z.zip` and `build/Clipkeep-x.y.z.zip.sha256`.
4. Create the release and attach both files:
   `gh release create vx.y.z build/Clipkeep-x.y.z.zip build/Clipkeep-x.y.z.zip.sha256 --title vx.y.z --notes-file <notes>`.
5. Update `Casks/clipkeep.rb` in the tap: set `version` and `sha256` (the value printed by
   `release.sh`), then run `brew audit --cask --online clipkeep` and
   `brew install --cask ./Casks/clipkeep.rb`.
6. Commit and push the tap.

## Notes

- The archive is built for the architecture of the build Mac (`arm64` on Apple silicon). The cask
  depends on `arch: :arm64` accordingly.
- Without an Apple Developer ID the app is not notarised. Users see the Gatekeeper warning once and
  open the app with right click → "Open". The cask only mentions this in its `caveats` and never
  strips the quarantine attribute.

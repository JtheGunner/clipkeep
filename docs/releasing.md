# Releasing

Clipkeep ships as a zip attached to a GitHub release. The Homebrew cask in
[`JtheGunner/homebrew-tap`](https://github.com/JtheGunner/homebrew-tap) downloads that zip, so the
release asset must be publicly downloadable without a login.

## Publishing a version

A tag `vX.Y.Z` on `main` starts the [Release workflow](../.github/workflows/release.yml). It builds
and signs the archive, publishes the GitHub release and opens the cask pull request in the tap.

1. Move the `[Unreleased]` entries in `CHANGELOG.md` under `## [x.y.z] - YYYY-MM-DD`, merge that
   change to `main`.
2. Tag the merge commit and push the tag: `git tag -a vx.y.z -m vx.y.z && git push origin vx.y.z`.
3. Watch the workflow run. It stops early if the tag is not on `main`, the changelog has no entry
   for the version, or the app is not signed with the expected certificate. The tests are not run
   again: the CI workflow has tested the commit on `main`.
4. Merge the pull request that the workflow opened in `JtheGunner/homebrew-tap`.
5. Check the release: install it with `brew install --cask JtheGunner/tap/clipkeep` and open the
   app with right click → "Open".

## Secrets

Set these in the repository settings under Secrets and variables → Actions.

| Secret | Content |
| --- | --- |
| `SIGNING_P12` | The `Clipkeep Local Signing` identity as a base64-encoded `.p12` file |
| `SIGNING_P12_PASSWORD` | The password of that `.p12` file |
| `HOMEBREW_TAP_GITHUB_TOKEN` | A token that can push branches and open pull requests in `JtheGunner/homebrew-tap` (fine-grained, only that repository, Contents and Pull requests: read and write) |

Every release must be signed with the same certificate: the Keychain approval and the
Accessibility and Automation grants are bound to it, so a different identity makes every user grant
them again. The workflow checks the certificate hash and fails otherwise.

To export the identity, open Keychain Access, select the certificate `Clipkeep Local Signing`
together with its private key (login keychain, category "My Certificates"), choose File → Export
Items, format `.p12`, and set a password. Then store it:

```sh
base64 -i Clipkeep.p12 | gh secret set SIGNING_P12 --repo JtheGunner/clipkeep
gh secret set SIGNING_P12_PASSWORD --repo JtheGunner/clipkeep
```

Delete the `.p12` file afterwards. The private key of a self-signed certificate lets anyone who
holds it sign apps that look like Clipkeep to Macs that trust the certificate, so keep the secrets
restricted to this repository.

## Publishing by hand

If the workflow cannot run, use the Mac that holds the certificate:

1. `VERSION=x.y.z ./scripts/release.sh` runs the tests and writes `build/Clipkeep-x.y.z.zip` and
   `build/Clipkeep-x.y.z.zip.sha256`.
2. `gh release create vx.y.z build/Clipkeep-x.y.z.zip build/Clipkeep-x.y.z.zip.sha256 --title vx.y.z --notes-file <notes>`.
3. In the tap, set `version` and `sha256` in `Casks/clipkeep.rb`, run
   `brew audit --cask --online clipkeep` and open a pull request.

## Notes

- The archive is built for the architecture of the build Mac (`arm64` on Apple silicon). The cask
  depends on `arch: :arm64` accordingly.
- Without an Apple Developer ID the app is not notarised. Users see the Gatekeeper warning once and
  open the app with right click → "Open". The cask only mentions this in its `caveats` and never
  strips the quarantine attribute.

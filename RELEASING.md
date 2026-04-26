# Releasing meee2

Releases are **tag-driven**. Push a tag `v<semver>` to `main`; the GitHub Actions workflow at [`.github/workflows/release.yml`](.github/workflows/release.yml) does the rest.

## Cutting a release

```bash
# 1. Make sure main is green and your local checkout is clean
git checkout main
git pull --ff-only
./scripts/validate.sh       # last sanity before tagging

# 2. Tag — use semver, with leading v
git tag -a v0.2.0 -m "Release v0.2.0"

# 3. Push the tag
git push origin v0.2.0
```

That's it. Within ~5 minutes the workflow:

1. Runs `swift test --parallel` as a sanity gate
2. Builds a signed (ad-hoc) release binary
3. Bundles into `meee2.app` + creates `dist/meee2-v0.2.0.dmg` via [`create-dmg.sh`](create-dmg.sh)
4. Generates `.sha256` checksum
5. Creates a GitHub Release titled `meee2 v0.2.0` with auto-generated notes (since the previous tag)
6. Attaches both the DMG and the checksum file

See **[Releases](../../releases)** after push — the new release will appear with the artifacts.

## Dev / test builds without a tag

The same workflow has a `workflow_dispatch` trigger. In the GitHub UI go to **Actions → Release → Run workflow**, fill in a version string (e.g. `0.2.0-rc1`), and it produces a **prerelease** with that version. These are flagged as prereleases so they don't overshadow stable tags.

## Version propagation

The version string from the tag (or dispatch input) is the single source — it gets injected into:

- `Info.plist` — `CFBundleShortVersionString` (via `sed` in `create-dmg.sh`)
- Built-in plugin manifests — e.g. `Plugins/cursor/plugin.json` `version` field
- DMG filename — `dist/meee2-v<version>.dmg`

**Don't** hardcode versions in source files — they'd drift from the tag.

## Signing caveat

The workflow uses **ad-hoc signing** (`codesign --sign -`). This is enough for a developer-audience download, but first-time Gatekeeper will refuse to open the app — users need to right-click → Open → Open anyway, or run:

```bash
xattr -dr com.apple.quarantine /Applications/meee2.app
```

When the project enrolls in the Apple Developer Program:

1. Store `APPLE_CERTIFICATE_P12` (base64-encoded .p12) + `APPLE_CERTIFICATE_PASSWORD` in repo secrets
2. Add a step in `release.yml` to import the cert via `actions/import-keychain` or an inline security unlock script, then replace `codesign --sign -` with `codesign --sign "Developer ID Application: <Team>"` in `create-dmg.sh` (parametrize via env)
3. Add notarization via `xcrun notarytool submit ... --wait` using `AC_API_KEY_ID` + `AC_API_KEY_ISSUER` + `AC_API_KEY_P8` secrets
4. Staple with `xcrun stapler staple`

That's a one-time setup; the rest of this file doesn't change.

## If something goes wrong

- **Tag already pushed but build failed**: fix, re-tag (delete old tag locally + remote, re-push) OR push a new tag `v0.2.1`. Don't reuse a release tag — users may have already pulled it.
  ```bash
  git tag -d v0.2.0                # local delete
  git push origin :refs/tags/v0.2.0 # remote delete
  git tag -a v0.2.0 -m "Release v0.2.0"
  git push origin v0.2.0
  ```
  The workflow handles re-uploads on existing releases via `--clobber`.

- **Workflow red**: check the Actions log. Common failures:
  - Tests fail → fix the regression, re-tag
  - `swiftlint` not installed on the runner → CI workflow installs it automatically; release doesn't run lint (sanity is `swift test` only)
  - DMG too large → the `hdiutil create -size 200m` line in `create-dmg.sh`; bump if the app grows past ~180 MB

- **Workflow artifact upload fails but release was created**: `workflow_dispatch` re-run with the same version will `--clobber` the DMG asset; no need to delete the release.

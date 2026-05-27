# Releasing meee2

Releases are **manual workflow-dispatch**. Start the GitHub Actions workflow at
[`.github/workflows/release.yml`](.github/workflows/release.yml), enter the
version string, then approve the publish job after checking the build artifact.

## Cutting a release

```bash
# 1. Make sure main is green and your local checkout is clean
git checkout main
git pull --ff-only
./scripts/validate.sh       # last local sanity before dispatch

# 2. GitHub UI:
# Actions → Release → Run workflow
# version: 0.2.0
# prerelease: false

# 3. Wait for the build artifact, sanity-check it, then approve
# the `release` environment gate so the publish job can run.
```

The workflow:

1. Runs `swift test --parallel` as a sanity gate
2. Builds WebDist, then a universal macOS app
3. Bundles into `meee2.app` + creates `dist/meee2-v0.2.0.dmg` via [`create-dmg.sh`](create-dmg.sh)
4. Uses Developer ID signing + notarization when the Apple secrets are configured; otherwise falls back to ad-hoc signing
5. Generates `.sha256` checksum and uploads the DMG as a workflow artifact
6. Waits for the `release` environment approval
7. Creates or updates a GitHub Release titled `meee2 v0.2.0` with auto-generated notes
8. If `SPARKLE_ED_PRIVATE_KEY_BASE64` is configured, signs the DMG for Sparkle and updates `appcast.xml` on the `appcast` branch

See **[Releases](../../releases)** after the publish job finishes.

## Dev / Test Builds

Use the same workflow with a prerelease version such as `0.2.0-rc1`, or set
the `prerelease` input. Versions containing `-` are treated as prereleases by
default.

## Version propagation

The workflow dispatch `version` input is the single source — it gets injected into:

- `Info.plist` — `CFBundleShortVersionString` and `CFBundleVersion` (via `plutil` in `create-dmg.sh`)
- Built-in plugin manifests — e.g. `Plugins/cursor/plugin.json` `version` field
- DMG filename — `dist/meee2-v<version>.dmg`

**Don't** hardcode versions in source files — they'd drift from the workflow
input and release artifact names.

## Signing And Appcast Caveats

When the Apple signing and notary secrets are configured, the release workflow
uses Developer ID signing, hardened runtime, secure timestamps, notarization,
and stapling. If any Apple signing secret is missing, it falls back to
**ad-hoc signing** (`codesign --sign -`). Ad-hoc builds are useful for testing,
but first-time Gatekeeper will refuse to open a downloaded app — users need to
right-click → Open → Open anyway, or run:

```bash
xattr -dr com.apple.quarantine /Applications/meee2.app
```

Sparkle appcast publishing is gated separately by
`SPARKLE_ED_PRIVATE_KEY_BASE64`. If that secret is missing, the GitHub Release
and DMG still publish, but `appcast.xml` is not updated and existing clients
will not auto-discover that version.

## If something goes wrong

- **Build failed before publish**: fix the branch and re-run the workflow with
  the same version, or bump to a new version if a broken artifact was already
  shared externally.

- **Workflow red**: check the Actions log. Common failures:
  - Tests fail → fix the regression and re-run the workflow
  - `swiftlint` not installed on the runner → CI workflow installs it automatically; release doesn't run lint (sanity is `swift test` only)
  - DMG too large → the `hdiutil create -size 500m` line in `create-dmg.sh`; bump if the app grows past the image size

- **Workflow artifact upload fails but release was created**: `workflow_dispatch` re-run with the same version will `--clobber` the DMG asset; no need to delete the release.

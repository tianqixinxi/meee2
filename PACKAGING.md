# Packaging & Release

How meee2 builds, signs, notarizes, and ships. The scripts gracefully
degrade — without any signing creds you still get a working ad-hoc DMG
(Gatekeeper requires right-click → Open). Wire up Developer ID + notary
to get a frictionless install for end users.

## TL;DR

```bash
# Local dev iteration (host arch, ad-hoc signed → tested in /Applications)
./deploy.sh

# Local "real" release build, signed + notarized + universal:
export IDENTITY="Developer ID Application: Your Name (TEAMID0123)"
export NOTARY_PROFILE=meee2-notary    # one-time setup below
export VERSION=0.3.0
NOTARIZE=1 NOTARIZE_APP=1 UNIVERSAL=1 ./create-dmg.sh

# CI auto-release (push tag v0.3.0): GitHub Actions does the same thing
# IF the secrets below are configured. Otherwise it produces an ad-hoc DMG.
git tag v0.3.0 && git push origin v0.3.0
```

## Scripts

| Script | Purpose |
|---|---|
| `build.sh` | Release Swift build + plugin install + sign binary & PluginKit |
| `deploy.sh` | Calls build.sh, pushes to `/Applications/meee2.app`, signs bundle, launches |
| `create-dmg.sh` | Calls build.sh, assembles `.app`, packs & signs `.dmg`, optionally notarizes |
| `scripts/notarize.sh` | Standalone wrapper around `xcrun notarytool submit + staple` |
| `scripts/lib-codesign.sh` | Shared signing helper (sourced; not run directly) |
| `uninstall.sh` | Remove app + state + Claude/Codex hook & MCP registrations |

### Env knobs

| Variable | Effect |
|---|---|
| `IDENTITY` | Developer ID Application identity. Unset → ad-hoc + warning |
| `UNIVERSAL=1` | Build fat arm64 + x86_64. Slower 2x, only needed for distribution |
| `NOTARIZE=1` | After packing the DMG, submit to Apple notary + staple ticket |
| `NOTARIZE_APP=1` | Also notarize the `.app` inside the DMG before packing (extra round trip) |
| `NOTARY_PROFILE` | Keychain profile alias for notarytool credentials |
| `VERSION` | Version string baked into Info.plist (default `0.0.0-dev`) |
| `SKIP_WEB_BUILD=1` | Reuse existing `Sources/Board/WebDist` (CI sets this in chain) |
| `SKIP_FINDER_UI=1` | Skip the AppleScript DMG-window styling (CI / headless) |

## What you need from Apple

These are all manual steps on **your** end. No way to automate them.

### 1. Apple Developer Program enrollment ($99/year)

1. Go to <https://developer.apple.com/programs/>
2. Enroll as Individual or Organization
3. Wait for approval (usually < 24h for individuals)

### 2. Generate a "Developer ID Application" certificate

1. <https://developer.apple.com/account/resources/certificates/list>
2. **+ →** "Developer ID Application"
3. Follow the CSR (Certificate Signing Request) flow:
   - Keychain Access → Certificate Assistant → Request a Certificate from a CA
   - "Saved to disk", upload the `.certSigningRequest`
4. Download the issued `.cer` and double-click to install in Keychain
5. Verify with:
   ```bash
   security find-identity -v -p codesigning
   # Expect a line like:
   # 1) DEADBEEF... "Developer ID Application: Your Name (TEAMID0123)"
   ```
6. Use that exact full string as `IDENTITY`.

### 3. Generate an App-Specific Password for notarization

`xcrun notarytool` doesn't accept your normal Apple ID password.

1. <https://appleid.apple.com> → Sign-In and Security → App-Specific Passwords
2. **+ →** label it "meee2 notary"
3. Save the 16-char password (`xxxx-xxxx-xxxx-xxxx`); Apple won't show it again.

### 4. Store notary credentials in your local keychain

One-time on each machine that does notarization (your laptop and the CI signing machine):

```bash
xcrun notarytool store-credentials meee2-notary \
    --apple-id  you@example.com \
    --team-id   TEAMID0123 \
    --password  xxxx-xxxx-xxxx-xxxx
```

`meee2-notary` is the profile alias. Match the value of `NOTARY_PROFILE`.

Verify:
```bash
xcrun notarytool history --keychain-profile meee2-notary
```

## GitHub Secrets (for CI auto-release)

`.github/workflows/release.yml` looks for these. Missing ANY of the
signing trio → auto-fallback to ad-hoc. Missing notary trio → sign but
don't notarize.

**Settings → Secrets and variables → Actions → New repository secret**

### Signing (3 secrets — required as a set)

| Name | Value |
|---|---|
| `APPLE_DEV_ID_CERT_P12_BASE64` | base64 of your Developer ID Application `.p12` export. See command below |
| `APPLE_DEV_ID_CERT_PASSWORD` | the password you set when exporting the .p12 |
| `APPLE_DEV_ID_IDENTITY` | exact identity string, e.g. `Developer ID Application: Your Name (TEAMID0123)` |

Export the cert as `.p12`:

1. Keychain Access → My Certificates
2. Right-click the "Developer ID Application: ..." cert → Export
3. Save as `meee2-dev-id.p12`, set a password (anything; you'll paste it as `APPLE_DEV_ID_CERT_PASSWORD`)
4. Base64 encode:
   ```bash
   base64 -i meee2-dev-id.p12 | pbcopy
   # Paste into APPLE_DEV_ID_CERT_P12_BASE64
   ```
5. **Delete `meee2-dev-id.p12` after** — the cert is now in the GH secret, leaving copies on disk is risk.

### Notary (3 secrets — required as a set)

| Name | Value |
|---|---|
| `APPLE_NOTARY_APPLE_ID` | your Apple ID email |
| `APPLE_NOTARY_TEAM_ID` | the 10-char team ID (same as the parens in IDENTITY) |
| `APPLE_NOTARY_PASSWORD` | the App-Specific Password from §3 |

### One-time: Create the `release` environment for the manual approval gate

The release workflow is a two-stage manual flow:

1. **build** job — automatic (runs on workflow_dispatch). Builds, signs,
   notarizes, uploads DMG as artifact. Anyone with run-workflow permission
   can trigger it.
2. **publish** job — gated. Uses `environment: release` which GitHub
   pauses on until a configured reviewer approves. Reviewer downloads /
   sanity-checks the build artifact, then clicks "Approve" → publish
   creates a GitHub Release with the DMG.

To wire the gate:

1. GitHub repo → **Settings** → **Environments** → **New environment**
2. Name it exactly `release` (case-sensitive — must match the workflow YAML)
3. Tick **Required reviewers**, add yourself (and/or the team)
4. Save

Without this environment configured the publish job runs immediately
without a gate (GitHub treats undefined environments as no-op). Setting
it up once is the difference between "manual triggered, auto published"
and "manual triggered, human-approved publish."

## What's in / what's NOT in the box right now

### Done

- [x] **Single source of truth for `Info.plist`** — `App/Info.plist`, version
  injected via `plutil -replace` at build time. Was previously duplicated
  inline in `create-dmg.sh` with drift between the two.
- [x] **Signing helper** (`scripts/lib-codesign.sh`) — `IDENTITY` env or
  ad-hoc fallback with warning. Adds `--options=runtime` + `--timestamp`
  when real, both required for notarization.
- [x] **Hardened runtime** — gated on real IDENTITY (Apple's `codesign`
  rejects `--options=runtime` on ad-hoc). Entitlements
  (`meee2.entitlements`) explicitly disable sandbox and library
  validation; both compatible with hardened runtime.
- [x] **Universal binary** — `UNIVERSAL=1` env produces fat arm64 + x86_64
  via SwiftPM's native multi-arch (`--arch arm64 --arch x86_64`). Build
  paths auto-resolve (single → `.build/release/`, universal →
  `.build/apple/Products/Release/`).
- [x] **Notarization** (`scripts/notarize.sh`) — submits + waits + staples.
  CI workflow gates it on secrets being set.
- [x] **DMG signing** — both the `.app` inside AND the `.dmg` envelope are
  signed (the latter was missing before).
- [x] **CI release pipeline** — `.github/workflows/release.yml` imports the
  cert into a runner-scoped keychain, configures notary creds, builds
  universal + signs + notarizes. Falls back gracefully when secrets are
  missing.
- [x] **Uninstall script** (`uninstall.sh`) — surgical cleanup of state +
  Claude hooks + MCP registrations. dry-run by default.

### NOT done — needs your input

- [ ] **Apple Developer Program** — manual ($99/yr).
- [ ] **Developer ID cert + .p12** — manual (Keychain export, GH secret).
- [ ] **App-Specific Password + notarytool profile** — manual (Apple ID web).
- [ ] **GitHub Secrets** — paste the six values above into repo settings.
- [ ] **Sparkle auto-update** — not added. Decisions needed first:
  - Where to host the appcast XML? (your server / GitHub Releases / S3)
  - EdDSA signing key: I can't generate it for you — `generate_keys` from
    Sparkle distribution makes a private key that must NOT be committed.
  - Once decided, the integration is: SwiftPM dep on `sparkle-project/Sparkle`,
    `SUFeedURL` + `SUPublicEDKey` in `App/Info.plist`, wire up
    `SPUStandardUpdaterController` in `AppDelegate`. ~30 lines.

### Known gaps (low priority)

- [ ] Plugin-kit dylibs in `~/.meee2/lib/` are signed by `build.sh` but the
  ones in `/Applications/meee2.app/Contents/MacOS/*.dylib` are signed by
  `deploy.sh` — sign command is the same but signature lives in two
  places. Cosmetic.
- [ ] No tests for the packaging scripts themselves. `bash -n` syntax check
  in CI would catch typos at least.
- [ ] `Bridge/mcp-meee2/node_modules` is ~5MB of JS deps shipped inside
  the .app. License audit not done; if you go App Store this matters.

## Daily workflow recipes

### "I just want to test my change locally"

```bash
./deploy.sh           # ad-hoc OK; will warn but works
```

### "I'm shipping a release tag right now"

```bash
git tag v0.3.0
git push origin v0.3.0
# CI does the rest (assuming secrets are wired)
```

### "I want to manually sanity-check a notarized DMG before tagging"

```bash
export IDENTITY="Developer ID Application: ... (TEAMID)"
export NOTARY_PROFILE=meee2-notary
export VERSION=0.3.0-rc1
NOTARIZE=1 UNIVERSAL=1 ./create-dmg.sh
spctl --assess --type open --context context:primary-signature -vvv "dist/meee2-v${VERSION}.dmg"
# Expected: "accepted" + "Notarized Developer ID"
```

### "Someone got a stuck Gatekeeper warning"

The notarization ticket isn't stapled to the .app inside the DMG (only
the DMG envelope). Set `NOTARIZE_APP=1` next build — it does an extra
round trip to staple the .app too, so the user can copy it out of the DMG
and still launch without a network check.

### "I need to roll the signing key"

Apple lets you have multiple Developer ID Application certs. Generate a
new one, update `APPLE_DEV_ID_CERT_P12_BASE64` + `APPLE_DEV_ID_IDENTITY`
secrets, **don't revoke the old one yet** — already-signed binaries stay
valid as long as the timestamp authority signed them while the cert was
live, but new builds use the new cert.

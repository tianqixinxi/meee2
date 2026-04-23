# Contributing to meee2

Thanks for your interest — meee2 is a small macOS menu bar app and plugin SDK, and external PRs are welcome. This doc covers what you need to build, test, and submit changes.

## Requirements

- macOS 13.0 or later
- Xcode 15+ / Swift 5.7+ toolchain
- [SwiftLint](https://github.com/realm/SwiftLint) — `brew install swiftlint`

The app runs as a menu bar `.accessory` process and loads plugins as dynamic libraries, so development requires a real Mac — no Linux / Docker path.

## Getting Started

```bash
git clone https://github.com/<your-fork>/meee2
cd meee2

# Install the local git hooks (runs a quick build + hardcoded-path/secret scan on commit)
./.githooks/setup.sh || cp .githooks/pre-commit .git/hooks/pre-commit

swift build            # debug build; fastest iteration
swift test             # run the unit test suite
./scripts/validate.sh  # full local gate: build + test + lint + path/print scans
```

For a release build with codesigning and the plugin dylib installed:

```bash
./build.sh
```

## Before You Open a PR

All of the following must pass locally and in CI:

1. `swift build` — clean debug build
2. `swift test` — all existing tests pass; add new tests when you change behavior
3. `swiftlint lint --strict --quiet` — no lint violations
4. `./scripts/validate.sh` — runs the above plus the hardcoded-path and bare-`print()` scanners

CI runs the same gates on every PR; see [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## Code Conventions

See `CLAUDE.md` for the full list. The load-bearing ones:

- **Logging**: use `MLog / MDebug / MInfo / MWarn / MError` in `Sources/`. Never `print()` in `Sources/Services/` — it's scanned and will fail CI. `print()` is only allowed for CLI stdout (`Sources/CLI/`).
- **No hardcoded user paths**: use `NSHomeDirectory()`, `FileManager`, `Bundle.main`. Any occurrence of `"/Users/<name>"` fails both SwiftLint and the path scanner.
- **Plugins**: subclass `SessionPlugin` (in `meee2-plugin-kit`). Inter-plugin communication goes through `PluginManager`, never direct references.
- **Persistence**: `SessionData` is persisted to `~/.meee2/sessions/`. If you change the on-disk schema, bump `SessionData.currentSchemaVersion` and add a migrator — see `Sources/Services/SessionStore.swift`.
- **Comments**: Chinese inline comments are fine; keep public doc comments descriptive.

## Commit & PR

- One logical change per PR. Split refactors from behavior changes when you can.
- Reference any related issue in the PR body.
- Include a short "Test plan" describing what you verified manually (menu bar UI, TUI, CLI, web board — whatever surfaces your change touches).
- For UI changes, a short screenshot or GIF helps reviewers a lot.

## Architectural Gotchas

A few things that will bite you if you don't know:

- `HookSocketServer` **keeps the client socket open** for `PermissionRequest` events until the user responds (or the request times out, see `HookSocketServer.permissionTimeoutSeconds`). Don't close it early.
- `DynamicIslandWindow`'s `NSHostingView` must have `sizingOptions = []` to avoid infinite constraint update loops.
- Entitlements intentionally disable sandbox and library validation — required for loading plugin dylibs. Keep it that way.
- Ad-hoc codesigning (`--sign -`) invalidates macOS Accessibility permissions every rebuild. Use a stable signing identity for day-to-day dev if you rely on Accessibility features (terminal jumping, Ghostty focus).

## Reporting Bugs / Suggesting Features

Use the issue templates. For anything security-related, see [`SECURITY.md`](SECURITY.md) — please do not file a public issue.

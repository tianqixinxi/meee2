# Security Policy

## Reporting a Vulnerability

If you believe you've found a security issue in meee2 — especially anything in these areas — **please do not file a public GitHub issue**:

- The Unix domain socket at `/tmp/meee2.sock` and the hook bridge protocol
- The dynamic plugin loader (`DynamicPluginLoader` / `PluginManager`) — entitlements disable library validation, so a malicious dylib in `~/.meee2/plugins/` runs with full app privileges
- Custom card templates (`Sources/Board/CardTemplateStore.swift` + `web/src/cardCompile.ts`) — user code is compiled via Babel and rendered in the board
- Permission-request handling in `HookSocketServer` (the allow/deny/ask decision path)
- The local HTTP server (`BoardServer`) that exposes `/api/state` and related endpoints
- Anything that could lead to arbitrary code execution, sandbox escape, or exposure of data under `~/.meee2/`

Email the maintainers privately at **security@meee2.dev** (or open a GitHub Security Advisory on the repo) with:

- A description of the issue and its impact
- Steps to reproduce, ideally a minimal proof of concept
- Affected version / commit hash (`git rev-parse HEAD`)
- Your name / handle for acknowledgement (optional)

We'll acknowledge within **7 days** and aim to ship a fix or clear timeline within **30 days** of confirmation.

## Scope

In scope:

- The meee2 app binary, the CLI/TUI entry points, the plugin SDK (`meee2-plugin-kit`), the built-in plugins, and the Board HTTP server + React frontend.

Out of scope:

- Third-party plugins not shipped in this repo — report to the plugin author.
- Attacks that require an already-compromised local account (meee2 is a local-only app; it trusts processes running as the same user).
- Social engineering, physical attacks, or DoS against an attacker-controlled local socket.

## Supported Versions

Only the latest `main` branch and the most recent tagged release receive security fixes. There is no LTS track.

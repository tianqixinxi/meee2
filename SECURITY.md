# Security Policy

## Local data wipe endpoints (same-origin only)

`POST /api/system/delete-local-data/token` and `POST /api/system/delete-local-data`
on `BoardServer` are destructive (they erase `~/.meee2/` state) and are
**not** exposed under wildcard CORS. Both routes go through
`BoardServer.requireLocalUIOrigin`, which rejects any request whose
`Origin` / `Referer` is outside the local meee2 UI allow list
(`http://localhost:9876`, `http://127.0.0.1:9876`, dev server
`http://localhost:5002` + `127.0.0.1:5002`) with `403 forbidden_origin`.
The pre-existing in-app confirmation token remains as a second line of
defense against accidental clicks inside the trusted UI itself. If you
add another destructive `/api/system/*` route, add it to
`BoardServer.localUIOnlyPaths` and wrap it with `requireLocalUIOrigin`
instead of `cors`.

## Reporting a Vulnerability

If you believe you've found a security issue in meee2 — especially anything in these areas — **please do not file a public GitHub issue**:

- The Unix domain socket at `/tmp/meee2.sock` and the hook bridge protocol
- The dynamic plugin loader (`DynamicPluginLoader` / `PluginManager`) — entitlements disable library validation, so a malicious dylib in `~/.meee2/plugins/` runs with full app privileges
- Custom card templates (`Sources/Board/CardTemplateStore.swift` + `web/src/cardCompile.ts`) — user code is compiled via Babel and rendered in the board
- The global Web Board assistant (`Sources/Board/AssistantTools.swift` + `AssistantAPI.swift`) — when the user enables a hosted provider (OpenAI / Anthropic) and invokes content tools (`get_session_transcript`, `get_channel_messages`), redacted previews of session transcripts and A2A channel messages are sent to that provider as `tool_result` payloads. Each tool can be opted out per-request via the `enabledTools` setting; previews are capped (~16 KB total per call, per-string truncation at 1 KB), and raw tool input/output is never returned in full. Operators who don't want any assistant-side egress should leave the assistant on the `local` provider or disable the content tools entirely.
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

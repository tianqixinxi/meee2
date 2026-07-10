# Security Policy

## Local control plane

`BoardServer` is always bound to `127.0.0.1`; the legacy
`MEEE2_BOARD_BIND` override is ignored. Loopback binding alone does not stop a
website opened in the user's browser from calling localhost, so the server also
enforces one policy before routing any `/api/*` request:

- Browser origins must match the server's actual bound port. Development
  origins are disabled unless explicitly listed in `MEEE2_BOARD_DEV_ORIGINS`.
- Every `POST`, `PUT`, `PATCH`, and `DELETE` requires the launch-scoped
  `X-Meee2-Control-Token`. The bundled board receives it in its no-store HTML;
  the MCP shim reads it from the mode-0600 runtime-info file.
- `/api/events` requires the same token in the first WebSocket application frame. The server does not attach the client to broadcasts until it replies with `auth.ok`, and rejects missing or invalid authentication after a short timeout.
- CORS echoes a validated origin and never uses a wildcard.

Repository scripts that mutate the local API must read the current token with
`scripts/lib/board_control.py`; the helper validates the mode-0600 runtime-info
file and emits a curl-compatible header with `--header`.

The local-data wipe confirmation token remains an independent second defense
against accidental clicks inside the authenticated UI. New API routes inherit
the centralized control-plane middleware automatically; do not add mutation
bypasses at individual route handlers.

Legacy message retention has its own purpose-bound, one-time confirmation
token. The token records the exact candidate count and byte total shown to the
user and is rejected if that scope changes. Confirmed files are copied
byte-for-byte into a timestamped directory under `~/.meee2/backups`, verified,
and made visible with a same-directory rename before any source file is
removed. Pending and held messages are never candidates; backup failures leave
all original files untouched.

The native WebView bridge accepts messages only from the main frame at the
currently bound Board origin. External main-frame navigation opens in the
system browser; subframes, redirects, and arbitrary network documents cannot
invoke native actions. Online login callbacks use one-time, expiring state and
S256 PKCE; callback HTML has no script capability and never accepts credentials
in query parameters.

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

- The meee2 app binary, the CLI entry point, the plugin SDK (`meee2-plugin-kit`), the built-in plugins, and the Board HTTP server + React frontend.

Out of scope:

- Third-party plugins not shipped in this repo — report to the plugin author.
- Attacks that require an already-compromised local account (meee2 is a local-only app; it trusts processes running as the same user).
- Social engineering, physical attacks, or DoS against an attacker-controlled local socket.

## Supported Versions

Only the latest `main` branch and the most recent tagged release receive security fixes. There is no LTS track.

# Stream-JSON Ingestion Design

> Issue [#28](https://github.com/tianqixinxi/meee2/issues/28). Plan for adopting Claude Code's `--output-format stream-json` as a first-class ingestion path for sessions meee2 spawns itself, while keeping the hook + transcript-tail flow untouched for externally-launched sessions.

This is a design doc, not a change log. The recommended Phase-1 PR scope is in §6.

---

## 1. Schema reference

`stream-json` is Claude Code's NDJSON streaming protocol — one JSON object per line on stdout. Activated via `claude --print --output-format stream-json --verbose [--include-partial-messages] [--input-format stream-json]`. `--verbose` is required by the CLI when `--output-format stream-json` is combined with `--print` (otherwise CLI errors out). `--include-partial-messages` opts into Anthropic-API-shaped `stream_event` envelopes carrying SSE-style deltas.

The **trace below was captured live** on this machine at doc-write time:

```bash
$ claude --output-format stream-json --print --verbose --include-partial-messages "count to 3"
```

(Reproducible — see "Capture command" at the end of this section. Trace was verified during doc authoring; redacted of session_id only.)

### 1.1 Top-level event taxonomy

| `type` | Subtype / shape | When emitted | Notes |
|---|---|---|---|
| `system` | `subtype: "init"` | First message after process start | Carries `cwd`, `session_id`, `model`, `tools[]`, `mcp_servers[]`, `apiKeySource`, `claude_code_version`. Equivalent to Claude's old `SessionStart` info. |
| `system` | `subtype: "hook_started"` / `"hook_response"` | Around every hook execution if `--include-hook-events` is set; some hooks (e.g. `SessionStart:startup`) are emitted unconditionally | Includes `hook_id`, `hook_name`, `hook_event`, `outcome`, `exit_code`, `stdout`, `stderr`. **This is the same data the hook bridge sees today**, but in-band on the streaming channel. |
| `system` | `subtype: "status"` | Mid-turn liveness pings (e.g. `"requesting"`) | Only seen with `--include-partial-messages`. Useful as a "we're still alive" tick. |
| `stream_event` | wraps Anthropic API SSE event in `event:{...}` | Only with `--include-partial-messages` | SSE event types observed: `message_start`, `content_block_start`, `content_block_delta` (with `delta.type` = `text_delta` / `input_json_delta` / `thinking_delta`), `content_block_stop`, `message_delta` (carries `stop_reason`), `message_stop`. Direct mirror of Anthropic Messages API streaming. |
| `assistant` | `message: {role, content[], usage, model, …}` | Once per assistant message (after streaming, before the result row) | `content[]` items have `type: "text" \| "thinking" \| "tool_use"`. `usage` carries token + cache metrics. |
| `user` | `message: {role: "user", content[]}` | After a tool returns; content items are `tool_result` blocks | *(unverified — needs runtime check)* — not seen in our short single-turn capture; documented behaviour from Anthropic docs and confirmed by `AssistantProvider.swift:585-611` parsing assumption. |
| `rate_limit_event` | `rate_limit_info: {status, resetsAt, rateLimitType, …}` | Periodic / on rate-window changes | Useful for surfacing "5h window resets at …" to users. |
| `result` | `subtype: "success"` or error variants | Last message before clean exit | Carries `duration_ms`, `duration_api_ms`, `num_turns`, `total_cost_usd`, `usage`, `terminal_reason`, `permission_denials[]`. **This is the canonical "turn done" signal** — equivalent to a `Stop` hook. |

Every event also carries `uuid` and `session_id` (the latter is Claude's own UUID, identical to the JSONL filename meee2 already keys on).

### 1.2 Lifecycle ordering (single-turn, partial messages on)

Observed sequence (`hook_started/hook_response` for `SessionStart` straddle the front; partial-message `stream_event`s only with the flag):

```
system{init}
system{hook_started SessionStart} → system{hook_response …}
system{status: "requesting"}                  ← only with --include-partial-messages
stream_event{message_start}                   ← API SSE wrapped
stream_event{content_block_start type=text}
stream_event{content_block_delta text_delta}+ ← N times for N tokens
assistant{message …}                          ← coalesced full message
stream_event{content_block_stop}
stream_event{message_delta stop_reason=end_turn}
stream_event{message_stop}
rate_limit_event{…}
result{subtype=success terminal_reason=completed}
<EOF>
```

Multi-turn / tool-using turns interleave additional `assistant` (with `tool_use` blocks) → optional `system{hook_started:PreToolUse}` / `system{hook_response:PreToolUse}` → `user` (with `tool_result` blocks) → next `assistant`. The protocol does not emit a separate "tool finished" envelope — the next `user` message *is* the result. *(unverified — needs runtime check that meee2's permission-required tool denial propagates as a `permission_denials` row in `result` rather than an inline event.)*

### 1.3 Input side (`--input-format stream-json`)

When `--input-format stream-json` is set, stdin must be the same NDJSON shape on the input side: one `{"type":"user","message":{"role":"user","content":[…]}}` per turn. This is what enables **mid-stream cancel** and **multi-turn drive without re-spawning** the process. `--replay-user-messages` echoes inputs back on stdout for ack.

We did not exercise the input side in the capture — the schema is taken from `claude --help` (verified) plus the official Anthropic SDK docs.

### 1.4 Capture command (reproducibility)

```bash
claude --output-format stream-json --print --verbose --include-partial-messages "count to 3" \
  | jq -c 'del(.session_id, .uuid, .parent_tool_use_id)'
```

Use this when extending the schema reference. Pipe through `jq -r '.type + " " + (.subtype // .event.type // "")'` for a quick lifecycle silhouette.

### 1.5 Sources

- Live trace from local `claude` CLI v2.1.137 on darwin/arm64.
- `claude --help` output (verified).
- Existing in-tree usage: `Sources/Board/AssistantProvider.swift:455-633` already wraps `claude -p --output-format stream-json --include-partial-messages --verbose` for the local-claude assistant provider, parsing `stream_event.content_block_delta` and `assistant.message.content[*].text`.
- Public Anthropic Messages API streaming docs (event names match 1:1 — `message_start`, `content_block_*`, `message_delta`, `message_stop`).

---

## 2. Current architecture (briefly)

The hook → state pipeline (`docs/ARCHITECTURE.md` §3, §5, §6) is the part stream-json could displace for self-spawned sessions. Anchored in code:

- **Hook ingress** — `Bridge/claude-hook-bridge.sh` writes hook JSON into `/tmp/meee2.sock`. `HookSocketServer.start(...)` (`Sources/ClaudeCLI/HookSocketServer.swift`) reads it, decodes `HookEvent` (`Sources/ClaudeCLI/HookEvent.swift`), dispatches to `ClaudePlugin.handleHookEvent(_:)` (`Sources/ClaudeCLI/ClaudePlugin.swift:312`).
- **State write** — `ClaudePlugin.handleHookEvent` upserts a `SessionData` into `SessionStore` (`Sources/Core/SessionStore.swift:333` — the sticky-field-preserving merge).
- **Status reconciliation** — `TranscriptStatusResolver.resolve(for:)` (`Sources/ClaudeCLI/TranscriptStatusResolver.swift:208`) reads the hook-derived `data.status`, then calls `resolveUncached` (`:238`) which `readTail(path:bytes: 4096)` (`:511`), finds the last user/assistant/system entry (`findLastRelevantEntry` `:532`), and runs `decideFromTail` (`:300`) to refine the status.
- **Reads** — Island, CLI, Board, and `BoardDTOBuilder.sessionDTO` all funnel through `TranscriptStatusResolver.resolve(for:)`. Don't read `SessionData.status` directly.

### 2.1 What stream-json could replace

`decideFromTail` is doing **inference** because the underlying ground truth isn't available:

| Inference today (`TranscriptStatusResolver.swift`) | Direct stream-json signal |
|---|---|
| "Is the assistant still streaming?" — `assistant` tail + `assistantIsFresh` (< 30s) + hook ∈ resting → guess `.active` (`:354-360`) | `stream_event{message_start}` until `stream_event{message_stop}` is the literal interval |
| "Did the tool actually finish?" — `system` tail + working hook + > 90s → guess `.idle` ESC-during-tool (`:387-390`) | The `user{tool_result}` envelope arriving *is* the finish event |
| "Did Claude write its first token yet?" — fresh `user` tail with `set("thinking")` override (`resolveCurrentTool` `:418-…`) | First `content_block_delta{text_delta}` is the first-token signal |
| "Is this an ESC-mid-stream?" — `assistant-tail-stale(>60s+hook=working)` (`:374`) | `result{terminal_reason=interrupted}` (or stdout EOF without `result`) gives a clean answer *(unverified — exact `terminal_reason` value on user-interrupt not seen in our trace)* |
| "Stop hook arrived?" / "Compact happened?" | `result{subtype=success}` / `system{subtype=compact_*}` *(unverified — compact subtype name)* |

Replacing these for self-spawned sessions removes 4 of the 5 ESC heuristics and the `_staleAssistantTailThreshold` / `_staleSystemTailThreshold` timers from that subset. Resolver fixtures stay relevant for externally-launched sessions, which is most of them.

---

## 3. Proposed ingestion path

### 3.1 New module

```
Sources/ClaudeCLI/
  StreamJSONReader.swift     ← NEW. owns the spawned process + stdout NDJSON loop.
  StreamJSONEvent.swift      ← NEW. Codable enum of decoded event types.
  StreamJSONIngest.swift     ← NEW. event → SessionStore mutation mapper.
                                Also writes a richer event log to SessionEventBus
                                for the Web Board's TranscriptPanel.
```

These slot next to `ClaudePlugin.swift`, `HookSocketServer.swift`, `TranscriptParser.swift`. They do **not** subclass `SessionPlugin` — they're called by `ClaudePlugin` for sessions we own. Same trust boundary, same `meee2Kit` import surface.

The existing `Sources/Board/AssistantProvider.swift:566-613` ad-hoc parser becomes a thin wrapper over the new `StreamJSONReader` so we don't fork two parsers (the assistant provider was the original prototype — the new module generalises it).

### 3.2 Lifecycle

A "self-spawned" Claude session is one where meee2 owns the `Process` handle. Today that's only the assistant's `create_session` tool (`Sources/Board/AssistantTools.swift:529-576`), which delegates to `SpawnerRouter.forTerminal(...).spawn(...)` (`Sources/Terminal/TerminalSpawner.swift`). That spawner currently launches `claude` in a Ghostty/iTerm tab so the user can interact — i.e. *interactive* mode, no `--print`.

For stream-json to apply, we need a **headless spawn variant**: a `claude` process whose stdout/stdin meee2 owns. Two clean options:

1. **Headless companion process**, no terminal. Used for scripted / agent-to-agent sessions where there's no human at the keyboard. This is the pure stream-json case.
2. **Sidecar attach to interactive sessions**. *(unverified — likely not feasible: a single Claude session has one stdin owner; we can't fork the user's terminal.)* Skip for now.

Phase 1 implements (1) only. Phase 2 may extend `create_session` with a `mode: "interactive" | "headless"` arg that picks the spawner.

```
[meee2 process]
  ClaudePlugin.spawnHeadless(cwd:prompt:opts:)
    → StreamJSONReader.start(args)
        process: claude --print --output-format stream-json --input-format stream-json
                        --verbose --include-partial-messages --include-hook-events
                        --session-id <uuid>           ← we pre-allocate the sid
                        --add-dir <cwd>
        stdout pipe → readline loop on background DispatchQueue
        stdin pipe  → owned by StreamJSONReader; `send(text:)` writes one
                      `{"type":"user","message":{"role":"user","content":[…]}}` line
    → each parsed StreamJSONEvent →
        StreamJSONIngest.apply(event, sessionId:)
          → SessionStore.update(sessionId) { … }    ← status writes
          → SessionEventBus.publish(.streamJsonEvent(...))
          → AuditLogger.append(...)                 ← keep replayability
```

The Ghostty terminal jump path simply doesn't apply to headless sessions — the Board UI shows a "headless" affordance instead of "Open Terminal". The Web Board can render the live token stream by subscribing to `SessionEventBus`.

### 3.3 Concrete Swift sketch

```swift
// Sources/ClaudeCLI/StreamJSONEvent.swift
public enum StreamJSONEvent {
    case systemInit(SystemInit)            // type=system subtype=init
    case hookStarted(HookFrame)            // type=system subtype=hook_started
    case hookResponse(HookFrame)           // type=system subtype=hook_response
    case statusPing(String)                // type=system subtype=status
    case messageStart(model: String, msgId: String)
    case textDelta(String)                 // content_block_delta text_delta
    case thinkingDelta(String)             // content_block_delta thinking_delta
    case toolInputDelta(idx: Int, json: String)
    case contentBlockStart(idx: Int, kind: BlockKind)
    case contentBlockStop(idx: Int)
    case assistantMessage(AssistantMsg)    // coalesced full assistant turn
    case userMessage(UserMsg)              // typically tool_result-bearing
    case messageDelta(stopReason: String?) // mid-message stop info
    case messageStop
    case rateLimit(RateLimitInfo)
    case result(Result)                    // turn done — duration, cost, terminal_reason
    case unknown(rawType: String, raw: Data)  // forward-compat: forward to log, never crash
}

// Sources/ClaudeCLI/StreamJSONReader.swift
public final class StreamJSONReader {
    public init(args: Args, onEvent: @escaping (StreamJSONEvent) -> Void)
    public func start() throws            // spawns Process, starts readline loop
    public func send(userText: String) throws
    public func cancelTurn()              // writes ESC-equivalent: close stdin or send a stop frame (unverified — needs runtime check on which actually cancels)
    public func terminate()               // SIGTERM, then close pipes
}

// Sources/ClaudeCLI/StreamJSONIngest.swift  -- pure mapper, easy to unit-test
public enum StreamJSONIngest {
    public static func apply(
        _ event: StreamJSONEvent,
        sessionId: String,
        store: SessionStore = .shared
    ) {
        switch event {
        case .systemInit(let s):
            store.update(sessionId) { $0.cwd = s.cwd; $0.model = s.model }
        case .messageStart:
            store.update(sessionId) { $0.status = .active }     // streaming begins
        case .textDelta(let s):
            // Forward to SessionEventBus for live token rendering.
            // Don't churn SessionStore on every token — those don't need persistence.
            SessionEventBus.shared.publish(.streamJsonTextDelta(sid: sessionId, text: s))
        case .assistantMessage(let m) where m.containsToolUse:
            store.update(sessionId) { $0.status = .tooling; $0.currentTool = m.firstToolName }
        case .userMessage(let m) where m.containsToolResult:
            store.update(sessionId) { $0.currentTool = nil }    // tool actually finished
        case .messageStop:
            // assistant block done — don't switch to .idle yet, may have more
            break
        case .result(let r):
            store.update(sessionId) {
                $0.status = (r.terminal_reason == "interrupted") ? .idle : .completed
                $0.usage = r.usage
            }
        case .hookStarted, .hookResponse:
            // Re-emit to ClaudePlugin.handleHookEvent so existing logic still
            // fires (permission UI, A2A inbox drain). Same shape as socket path.
            break
        // …
        }
    }
}
```

`StreamJSONIngest.apply` is **pure**: in/out arguments only, no I/O. That keeps it trivially fixturable (§5).

### 3.4 IO ownership

- The spawned `Process` lives inside `StreamJSONReader` — same lifetime as the session. Killed on `ClaudePlugin.stopSession(sid)` or process exit.
- The readline loop runs on a dedicated `DispatchQueue("com.meee2.streamjson.<sid>", qos: .userInitiated)` — one queue per session. Mutations onto `SessionStore` go through `DispatchQueue.main.async` exactly like `ClaudePlugin` does today (`SessionStore`'s `@Published` requires main).
- stdin writes are also on the per-session queue, serialised against reads — no torn writes.

### 3.5 Hooks still fire

Critically: even with stream-json, the spawned `claude` still triggers user-level hooks from `~/.claude/settings.json` — including our own `claude-hook-bridge.sh`. That means **`/tmp/meee2.sock` will continue to receive duplicate hook events for self-spawned sessions** unless we do something. Three options, in order of preference:

1. **Dedupe at ingest** — the `system{hook_response}` event in stream-json carries `hook_id`. The bridge can stamp the same id on socket payloads (it already enriches with tty etc.; one more field is cheap). `ClaudePlugin` ignores socket events whose `hook_id` arrived via stream-json within the last N seconds.
2. **Spawn with `--bare`** — the `claude --bare` flag (visible in `--help`) skips hooks entirely. *(unverified — needs runtime check that it suppresses the hook bridge specifically.)* Cleaner but loses A2A inbox drain via the permission-block trick.
3. Per-session env var that tells the bridge to no-op for self-spawned sids. Possible but invasive in `Bridge/claude-hook-bridge.sh`.

Recommend **(1)**. It preserves all existing hook-side behaviour (including A2A inbox drain via `decision: "block"`) and is a 5-line shim.

---

## 4. Migration strategy

The issue's "out of scope" note is the rule: **externally-launched sessions are not touched.** The hook + transcript-tail flow is the fallback for everything we don't own.

| Session type | Today | After this design |
|---|---|---|
| User runs `claude` themselves | hook bridge → socket → ClaudePlugin → resolver tail | unchanged |
| Spawned via Web/CLI `create_session` (interactive Ghostty tab) | same as above | unchanged in Phase 1; could opt in via `mode: "headless"` later |
| Future: scripted agent (no human terminal) | n/a — doesn't exist yet | StreamJSONReader is the only ingest path; resolver still runs but on a thin transcript |

### 4.1 Phased rollout

- **Phase 1 — Build & wire, opt-in.** Land `StreamJSONReader` + `StreamJSONEvent` + `StreamJSONIngest` + decoder unit tests, gated behind `MEEE2_STREAM_JSON_HEADLESS=1` env var. New CLI subcommand `meee2 spawn-headless --cwd … "<prompt>"` exercises the full path. No changes to interactive `create_session`. Hook+tail still authoritative for everything else. **Resolver gets a new fast-path**: if a session has been streaming events in the last 5s, return its in-memory status without re-tailing the file. Otherwise nothing changes.
- **Phase 2 — Default-on for headless `create_session`.** Extend the assistant tool with `mode: "headless" | "interactive"` (default `"interactive"`). Headless mode uses `StreamJSONReader`; the Board renders live tokens by subscribing to `SessionEventBus.streamJsonTextDelta`. Hook bridge dedupe (§3.5 option 1) lands in this phase.
- **Phase 3 — Retire transcript-tail polling for stream-json sessions.** `TranscriptStatusResolver.resolve(for:)` learns to short-circuit when a session has an active `StreamJSONReader` registered. The 4 ESC heuristics in §2.1 stop running for those sessions. Existing fixtures remain valid for the externally-launched majority. Transcript file is still written by `claude` itself for replayability — we just don't tail it.

Phases ship as separate PRs, each independently revertable.

### 4.2 Why keep hook+tail as fallback (verbatim from the issue, restated)

- Externally-launched sessions have no stream-json channel — there's literally no other way to observe them.
- Even in stream-json mode, hook bridge events still fire and meee2 still uses them for A2A inbox drain (the `decision: "block"` permission-response trick documented in `docs/ARCHITECTURE.md` §9). Removing that breaks message routing.
- Rollout safety: bugs in the new path collapse back to the old one without action.

---

## 5. Open questions / risks

1. **Process death mid-stream.** Does stream-json emit a clean termination event in all cases, or do we infer death from EOF? Observed: clean exit emits `result{terminal_reason:"completed"|...}`. *(unverified)* — what does a SIGTERM'd `claude` emit? What about an OOM? Plan: treat EOF without a preceding `result` row as `.dead`, log the partial state, and compare on the next run.
2. **Permission-blocked tools.** The current hook bridge handles permission round-trips synchronously by holding the socket open (`HookSocketServer.permissionTimeoutSeconds`, default 300s). With stream-json, does the spawned `claude` still call out to the hook bridge for permissions? *(unverified — needs runtime check.)* If yes, no change needed: the socket path stays authoritative for permissions, stream-json just observes the resulting `permission_denials` row in `result`. If no, we need to surface `PermissionRequest` events on the stream-json channel and add a counter-write path on stdin.
3. **Backpressure on long tool outputs.** A single `Bash` result can be megabytes. The current resolver only reads the last 4 KB of the transcript file (`TranscriptStatusResolver.swift:261`). For stream-json we get the *full* `tool_result` block in one event — could spike memory if we forward to `SessionEventBus` verbatim. Plan: cap each `userMessage{tool_result}` payload at 64 KB before forwarding to UI subscribers (same as `FullTranscriptReader._toolResultCap = 8000` chars on the read side; 64 KB raw is the live-streaming budget). The full payload is still written to the transcript file by `claude`, so replay tools can read it.
4. **Sessions with no transcript file.** If a self-spawned session bypasses transcript writes (it shouldn't by default, but `--no-session-persistence` does this — already used by `AssistantProvider.swift:523`), then `TranscriptStatusResolver` has no tail to read. For Phase 2/3, `StreamJSONIngest` must write enough to `SessionData` so the resolver's transcript-missing branch (`TranscriptStatusResolver.swift:262`) returns the correct `hookStatus` — basically: in stream-json mode, the in-memory status *is* the truth and the resolver is a no-op. Acceptable trade-off; document it.
5. **Test fixture story.** The current state-trace fixtures (`Tests/Fixtures/StateTraces/*.json`) capture `SessionData` + transcript tail + expected resolver output. They are still relevant for hook+tail sessions. For stream-json, propose a parallel fixture format under `Tests/Fixtures/StreamJSON/`: each fixture is an NDJSON file (real captured stream-json output, redacted) + an `expected_mutations.json` listing the `(SessionData field, value)` pairs the ingest mapper should produce. New `StreamJSONIngestFixtureTests` runs each fixture through `StreamJSONIngest.apply` against a fake `SessionStore` and diffs the mutation log. Same "log-as-testcase" philosophy as the resolver fixtures (CLAUDE.md, "State-trace regression fixtures").

---

## 6. Recommended next step

**Phase 1 PR — decoder + unit tests + CLI smoke command. No SessionStore wiring yet.**

Smallest valuable slice:

1. `Sources/ClaudeCLI/StreamJSONEvent.swift` — `Codable` enum + `init(from decoder:)` that handles every `type` we observed in §1.1, with `.unknown` fallthrough.
2. `Sources/ClaudeCLI/StreamJSONReader.swift` — owns `Process` + readline loop; `onEvent` callback. No SessionStore touching.
3. `Tests/StreamJSONDecoderTests.swift` — golden-file tests against ~5 captured NDJSON fixtures: single-turn text, multi-turn with one `Bash` tool, permission denial, `terminal_reason=interrupted` *(if reproducible)*, malformed/unknown-type event.
4. `meee2 stream-json --cwd <dir> "<prompt>"` CLI subcommand that runs `StreamJSONReader` and prints decoded events to stdout. Used for manual smoke testing and for capturing the fixtures in (3).
5. Refactor `Sources/Board/AssistantProvider.swift:566-613` to use `StreamJSONReader` instead of its inline parser. Single-file change, no behaviour change; gives us a real-world integration test for the new module the moment it lands.

What this PR explicitly **does not** do:

- No `SessionStore` writes — that's Phase 2.
- No changes to `ClaudePlugin`, `HookSocketServer`, `TranscriptStatusResolver`.
- No new spawn modes for `create_session`.
- No hook bridge dedupe — needed only when (5) starts producing duplicate state writes, which it can't because there are none.

Validation:

```bash
swift test --filter StreamJSONDecoderTests
swift run meee2 stream-json --cwd /tmp "say hi" | head
./scripts/validate.sh
```

Follow-up issues the doc proposes (file these when Phase 1 lands):

- "Phase 2: headless mode for `create_session` + live token stream on Board."
- "Phase 3: bypass transcript-tail for sessions with active StreamJSONReader."
- "Hook bridge: stamp `hook_id` on socket payloads so stream-json sessions can dedupe."

---

## Appendix A — Existing in-tree usage of stream-json

`Sources/Board/AssistantProvider.swift` (the `LocalClaudeProvider`) already spawns `claude -p --output-format stream-json --include-partial-messages --verbose` and parses a subset of events:

- `Sources/Board/AssistantProvider.swift:520-527` — argv construction.
- `Sources/Board/AssistantProvider.swift:566-613` — line-buffered NDJSON parse + `content_block_delta` text-delta extraction.

This is the prototype the new module generalises. It is **not** wired to `SessionStore` — the assistant uses it purely as a Claude-API-replacement for the chat dock, not for session monitoring. Phase 1's refactor (step 5) keeps its behaviour while consolidating the parser.

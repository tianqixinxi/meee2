# meee2

macOS menu bar app that monitors Claude Code (and other AI) sessions via a Dynamic Island overlay + web board + ncurses TUI + CLI.

Deeper references: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (+ §6 for hook → state → UI flow and ESC handling), [`docs/SCHEMAS.md`](docs/SCHEMAS.md).

## Build

```bash
swift build                 # Debug (fastest iteration)
swift build -c release      # Release
swift test                  # Full test suite (currently 100 tests)
./scripts/validate.sh       # Pre-commit gate: build + test + swiftlint + hardcoded-path/print scans
./build.sh                  # Release + codesign + dylib install to ~/.meee2/lib
```

## Architecture

Hook flow:

```
Claude CLI hook → Bridge/claude-hook-bridge.sh → /tmp/meee2.sock
               → HookSocketServer → ClaudePlugin → SessionStore
               → StatusManager / BoardServer → Island / TUI / Web
```

Core runtime services (`Sources/Services/`) — the authoritative state layer:

| Module | Role |
|---|---|
| `SessionStore` | Single source of truth, `@Published`, persists to `~/.meee2/sessions/<sid>.json` |
| `HookSocketServer` | `/tmp/meee2.sock` + pending permissions (`permissionTimeoutSeconds`) |
| `TranscriptStatusResolver` | Canonical `SessionStatus` — Island / TUI / Board all read through this |
| `MessageRouter` | A2A message store + per-session inbox queue |
| `ChannelRegistry` | A2A channels |
| `PluginManager` | Dynamic plugin loader (`~/.meee2/plugins/<id>/*.dylib`) |

Surfaces:
- **Island** — SwiftUI `IslandView`, menubar overlay
- **TUI** — `meee2 dashboard`, ncurses
- **CLI** — `meee2 list / send / jump / note / channel / msg / board / whoami`
- **Web Board** — React + Vite @ `localhost:5002` (dev) or `localhost:9876` (served by `BoardServer`)

Plugin SDK: `meee2-plugin-kit/` (shared dylib, defines `SessionPlugin` open class + public types).

## Code Conventions

- **Logging**: `MLog / MDebug / MInfo / MWarn / MError` in `Sources/`. NEVER `print()` in `Sources/Services/` — validate.sh enforces. `print()` only in `Sources/CLI/` for stdout output.
- **No hardcoded user paths**: `NSHomeDirectory() / Bundle.main / FileManager`. SwiftLint + validate.sh enforce.
- **`SessionData` schema**: Bump `SessionData.currentSchemaVersion` + add a migrator in `SessionDataMigrations` when on-disk shape changes. Include a regression test with a frozen legacy JSON fixture.
- **Single `SessionStatus` enum**: Don't fork a parallel status type. Extend `TranscriptStatusResolver` if new case logic is needed. **Every resolver behavior change should add a captured fixture** (see "State-trace regression fixtures" below) — the diff alone doesn't tell you whether you broke an existing case.
- **Plugins**: Subclass `SessionPlugin`. Inter-plugin comm through `PluginManager`.
- **Comments**: Chinese inline comments are fine. Doc comments describe *why*, not *what*.
- **Minimum**: macOS 13.0, Swift 5.7.

## Docs & Specs — what belongs in this repo

**Design/planning docs do NOT belong in this repo.** PRDs, feature plans, UI-gap specs,
workflow/run specs, decision records — anything describing *what to build and why* —
live in the private workspace (`meee2-workspace/doc/`: `prd/`, `decisions/`, …), never
committed here.

Only **codebase reference docs** belong in `docs/` — material that explains the code as
it exists now: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/SCHEMAS.md`](docs/SCHEMAS.md),
plugin/packaging guides. Rule of thumb: if it would go stale when the *plan* changes
(not the code), it's a spec — keep it out of the repo. Implementation PRs reference a
PRD only by `slug`, never by path or content.

## Debugging

Most debug loops follow one pattern: **tail the log + trigger the action + grep the trace**.

### Log file

meee2 writes all `NSLog` / `[StateTrace]` events to `/tmp/meee2.log` (plus `~/Library/Logs/meee2.log` as fd 3). Watch in real time:

```bash
tail -F /tmp/meee2.log | grep -a -E "StateTrace|TerminalJumper|MessageRouter"
```

Common trace tags:

| Tag | When |
|---|---|
| `[StateTrace][hook-ingress][socket]` | Incoming hook JSON hit the socket |
| `[StateTrace][hook]` | After ClaudePlugin processed it, with before/after hookStatus |
| `[StateTrace][resolver]` | `TranscriptStatusResolver` decision (+ tail reason) |
| `[StateTrace][boardDTO]` | What `/api/state` reports to Web |
| `[TerminalJumper]` | Open-terminal flow (marker → AppleScript focus) |
| `[MessageRouter]` | A2A send / deliver / drain / direct-push |

### Quick state inspection

```bash
curl -s http://localhost:9876/api/state | \
  jq '.sessions[] | {id: .id[:8], title, status, currentTool}'
```

### Restart meee2 after a rebuild

Swift changes need a restart; Vite web changes hot-reload themselves.

```bash
kill $(pgrep -f '\.build/.*meee2$') 2>/dev/null; sleep 1
nohup /Users/<you>/projects/meee1_code/meee2/.build/arm64-apple-macosx/debug/meee2 \
  >/tmp/meee2.log 2>&1 &
```

### Web UI (browser console)

For card / overlay bugs, drive a visible puppeteer yourself instead of asking the user to paste console output. Setup + runner live at `/tmp/meee2-browser-debug/debug.js`:

```bash
: > /tmp/browser.log
cd /tmp/meee2-browser-debug && (node debug.js >> /tmp/browser.log 2>&1 &)
tail -F /tmp/browser.log
```

The Chromium window is interactive — the user clicks, you read the log.

### State-trace regression fixtures

`TranscriptStatusResolver` 是 stuck-session bug 高发区。每次复现一个现场（"为什么这条
session 一直显示 thinking 不变"等），fix 完之后**用 `meee2 test capture` 把现场冻
进 git**，下次任何人改 resolver 都会被这堆历史 case 扫一遍，是性价比最高的回归保
护层（log 当 testcase 的思路）。

工作流：

```bash
# 1) 现场（GUI 打开 / 终端有 stuck 的 session），找到 sid 前缀
./.build/arm64-apple-macosx/debug/meee2 list --simple

# 2) 抓现场 —— 自动写到 Tests/Fixtures/StateTraces/<name>.json
./.build/arm64-apple-macosx/debug/meee2 test capture <sid-prefix> \
    --name "stuck-tooling-after-pretooluse-bash" \
    --desc "PreToolUse Bash 后 Stop hook 没回，hook=tooling，tail 是 fresh assistant；resolver 应保留 tooling"

# 3) 列出 / 单条 replay
./.build/arm64-apple-macosx/debug/meee2 test list
./.build/arm64-apple-macosx/debug/meee2 test replay stuck-tooling-after-pretooluse-bash

# 4) swift test 时自动跑 StateTraceFixtureTests，遍历目录里每条 fixture
swift test --filter StateTraceFixtureTests
```

捕获的内容 = `SessionData`（已脱敏：pid / ghosttyTerminalId / terminalInfo 都被
置 nil 让 fixture 跨机器可跑；`/Users/<user>` 全替换成 `~`）+ transcript 文件
tail（最后 N 行，再 cap 到 16KB —— resolver 实际只读 4KB，4× 余量足够）+
`/tmp/meee2.log` 里跟该 sid 有关的 `[StateTrace]` 行（人读用，不进 assertion）+
当时 resolver 输出的 status（作为 expected）。

约定：
- 每修一个 resolver bug，至少补一条 fixture（命名要描述 case，不是 sid）。
- `--desc` 必填的"半"约定 —— 不写 CLI 会提示，但不阻塞。
- fixture 直接 commit 进 git（一条 ~10 KB JSON，diff 友好）。
- fixture 目录从 `swift test` target 的 `path: "Tests"` exclude 出去，所以放在
  `Tests/Fixtures/StateTraces/` 不参与编译。

每条 fixture 同时断言两件事：
1. `TranscriptStatusResolver.resolve(for:)` → `expected_resolved_status`
2. `TranscriptStatusResolver.resolveCurrentTool(...)` → `expected_current_tool_override`
   三态：`no_change` / `clear` / `set("thinking")`

resolveCurrentTool 三种分支命中条件：

| 分支 | 触发 |
|---|---|
| `no_change` | tail 末尾是 `assistant` 条目（Claude 刚回完，tool 状态由 hook 主导） |
| `clear` | tail 末尾是 `system` 条目（Stop hook 收尾）/ user 条目带 interrupt marker / user 条目但 >180s 老 |
| `set("thinking")` | tail 末尾是 fresh user 条目（用户刚提交、Claude 还没出第一 token） |

抓 fixture 一般会落在 `no_change`（最常见，sessions 大多停在 assistant 收尾）。
碰上 `clear` / `set("thinking")` 的瞬态（用户刚提交还没回 / Stop hook 刚到尾巴）
就立刻 `meee2 test capture`，机会过了就抓不到那个分支了。

**安全注意**：transcript tail 是真实 .jsonl 文件最后几 KB —— **会包含会话内容**
（user prompt、assistant 回复、tool 调用、bash 输出）。capture 之前要确认：

- ⛔️ **不要从无关项目的 session 抓 fixture** —— 别项目代码 / 业务讨论混进 meee2
  repo 等于公开。只用 meee2 自身或纯 fake-session（cwd 不指向真实业务）的 session。
- ⛔️ **不要从近期粘过 secrets / API key / 密码的 session 抓** —— 即使你心里
  知道现在 tail 里没 secrets，下一次截到的 16KB 可能正好覆盖到。先跑一次
  `grep -E 'sk-|ghp_|Bearer|api[_-]?key|password' Tests/Fixtures/StateTraces/<name>.json`
  确认没东西再 commit。
- ✅ 安全的 capture 时机：刚修完一个 resolver bug、当前 session 是 meee2 自己的
  开发会话、最近没 paste 过 secrets。

## Acceptance / Validation

Before committing, **every PR**:

```bash
./scripts/validate.sh   # build + test + swiftlint + hardcoded-path + bare-print() scans
```

For non-trivial behavior changes, also smoke these by hand:

1. Launch the GUI — menubar icon appears, Island window renders
2. In a test Claude session, send a prompt — the card transitions `idle → thinking → tooling → idle` (not stuck)
3. Open Terminal from two different session cards — each focuses its own Ghostty tab (not all the same)
4. `meee2 msg send --channel __ops-<sid> --from operator --to session --human "ping"` — target session receives it within ~2s
5. `curl /api/state` returns current sessions with correct `status`

For UI changes, **hard-refresh** `localhost:5002` before evaluating (Vite HMR sometimes leaks stale chunks).

## Common Pitfalls

- `.accessory` activation policy — no Dock icon, menubar + Island only.
- `HookSocketServer` holds the permission socket open until user responds or `permissionTimeoutSeconds` (default 300s) expires. Don't close early.
- `meee2Kit` is imported by CLI/TUI/GUI — code in `Sources/` must not assume `NSApplication` is running.
- `DynamicIslandWindow`'s `NSHostingView` must have `sizingOptions = []` (prevents infinite constraint update loops).
- Entitlements disable sandbox + library validation — required for plugin dylib loading. Document any new code path that executes user-provided code in [`SECURITY.md`](SECURITY.md).
- **Ghostty tab jumping**: `focus (terminal id X)` per its sdef only raises the window, doesn't switch tab. Must walk `windows → tabs → terminals`, `select tab`, then `focus`. See `TerminalJumper.focusGhosttyTerminal`.
- Ad-hoc codesign (`--sign -`) invalidates Accessibility permissions every rebuild — use a stable identity for dev.
- `DEFAULT_TEMPLATE` is a backtick-wrapped template literal. Bare `\n` in its content gets evaluated at import time — breaks `//` comments and `'...'` strings. Write `\\n` inside to get literal `\n` at runtime.

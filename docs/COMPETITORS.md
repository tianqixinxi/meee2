# meee2 竞品分析（2026-05-08 多 session 调研沉淀）

本文档是 6 个 Claude session 在 channel-bf07 协作竞品调研的最终沉淀。
原始 transcript 在 `~/.claude/projects/-Users-qc-projects-meee1-code-meee2/`。

每条 verdict 标了 evidence（file:line + git SHA），未标的视为推论需自行验证。
如发现 verdict 与最新源码不符，更新条目并标日期；不要原地删。

---

## 0. TL;DR

1. **15 个竞品全部不抢 meee2 核心场景**：meee2 是「**用户已经手动起了一堆 Claude session，被动观测它们**」；其余产品要么是 spawn-orchestrator（自己起 agent + worktree + review），要么是 launcher（远程/手机起 CC），要么是 plugin marketplace。形态正交。
2. **真正的护城河有两条**：
   - `TranscriptStatusResolver` 三态状态机（thinking / tooling / idle）+ state-trace fixture 回归保护——**整个生态独此一家**（ruflo / claude-squad / claudecodeui 全部没有"session 状态"概念）。
   - hook-bridge 能接管「用户手起的 vanilla `claude`」——所有 spawn 派工具都看不见外部 session。
3. **CC `--settings` 是 layer / merge 不是 replace**——这是本轮调研最大的方法论翻车 + 修正，详见 §5。原本以为 Happy / ccr 是 P0 威胁，修正后只有 ruflo silent-fail 是真的（且 evidence 独立于此问题）。
4. **战略建议：B 主 + 轻 C，排除 A**——把观测做绝（B），轻量寄生 add-on 兼容 ruflo / squad / Crystal（C），不要追 ruflo 的编排表面积（A）。
5. **本轮意外副产品：发现 meee2 自己 3 个真 bug**，详见 §8。

---

## 1. 竞品全景一览

按 meee2 的"威胁度 × 形态"分层。威胁度 = 是否动用户的 `~/.claude/` hook slot 或抢 session 状态展示位。

| 竞品 | 形态 | 威胁度 | 与 meee2 关系 | Evidence |
|---|---|---|---|---|
| **ruvnet/ruflo**（前 claude-flow） | npx CLI + MCP server + Web UI，跨机 federation | 中（silent-fail 共存 bug）| 编排派，正交但表面积压力 | 见 §2.1 |
| **smtg-ai/claude-squad** | tmux + worktree TUI | 低 | 寄生 add-on 最强候选 | 见 §2.2 |
| **siteboon/claudecodeui** (`@cloudcli-ai/cloudcli`) | SDK 进程内 + Web 远程面板 | 低 | 远程接入缺口对照 | 见 §2.3 |
| **stravu/crystal**（即 Nimbalyst） | Electron + worktree | 低 | 借鉴 `--permission-prompt-tool` MCP 模式 | 见 §2.4 |
| **getAsterisk/claudia** | Tauri 桌面 app | 低 | macOS 原生护城河参照 | 见 §2.5 |
| **slopus/happy-cli**（Happy Coder） | 移动 + E2E + 推送 | 低（修正后）| 远程接入缺口 | 见 §2.6 |
| **musistudio/claude-code-router** (ccr) | proxy 层多 provider | 无 | 非威胁（修正后）| 见 §2.7 |
| **ericvtheg/claude-code-runner** | Docker headless | 无 | 形态错位，容器隔离 | 见 §2.7 |
| **multica-ai/multica** | Issue-board kanban + daemon | 低 | 不同 mental model | 见 §2.8 |
| **wshobson/agents** | CC plugin marketplace | 无 | 内容库 vs 观测面，可共存 | 见 §2.9 |
| **dlorenc/multiclaude** | Go supervisor + tmux | 低 | spawn 派 | 见 §2.9 |
| **gastownhall/gastown** | Mayor + Polecats，跨机 | 低 | spawn 派 | 见 §2.9 |
| **numman-ali/cc-mirror** | Multi-provider variant 隔离 | 无 | 不同领域 | 见 §2.9 |
| **ccusage** | Token / cost 用量观测 | 无 | 🟢 可嫁接，<1d add-on | 见 §2.10 |
| **闭源 5 家**（Tonkotsu / Terragon / Omnara / CodeRemote / YoloCode） | SaaS | 中 | Tonkotsu/Omnara 直接竞品但形态正交 | 见 §2.11 |

---

## 2. 关键竞品深度卡片

### 2.1 ruvnet/ruflo（46k⭐ TypeScript）— supervisor: 76f485

**定位**：multi-agent platform / "agent OS for Claude Code"。queen-led swarm + AgentDB (HNSW) + ReasoningBank + 32 plugin + mTLS federation + 27 hooks + 314 MCP tools。

**核心 verdicts**：

| 维度 | Verdict | Evidence |
|---|---|---|
| 100+ agents | ✅ 实锤 | 实测 136 个 agent .md 文件 |
| 210/300/314 MCP tools 数字打架 | ⚠️ 半真 | `v3/mcp/tools/*-tools.ts` 实测 250 个 name 字段，README 内部数字打架 |
| "89% routing accuracy" | ❌ broken | `hooks.ts:1399` 把 `routingAccuracy = routing.avgConfidence` —— **自评分 ≠ accuracy** |
| "HNSW 150x-12,500x faster" | ❌ broken | `vector-search.bench.ts:361` 是硬编码字符串 `'150x-12500x'`；100k/1M 数字是 10k 实测线性外推 |
| 状态机（idle/thinking/tooling）| ❌ 完全没有 | grep `thinking\|tooling\|idle\|waitingForUser` 命中 1 次（`idleTimeoutMillis` DB 配置）。读 transcript **唯一目的**是 `runAutopilot()` 估 token 用量 |
| ruflo init 写入行为 | ⚠️ 共存有约束 | `executor.ts:735-738`: `if (generated.hooks && !existing.hooks)` —— 用户已有 hooks 就 silent skip。ruflo helpers (`hook-handler.cjs`) **always overwrite**（注释明写）+ 无备份 |
| 商业模式 | personal-brand 漏斗 | ruv.io 1:1 咨询 $149-$50k；ruflo 是 lead-gen，不是产品 |
| npm 实际活跃度 | 1.1% CC 用户 | 周下载 70k vs `@anthropic-ai/claude-code` 6.4M；46k stars : 70k 周下载 ≈ 1:1.5（健康开源是 1:5–1:50）|

**安装顺序矩阵（meee2 ↔ ruflo 共存）**：

| 顺序 | meee2 hooks | ruflo hooks | 净结果 |
|---|---|---|---|
| meee2 → ruflo | ✅ | ❌ silent dropped | **ruflo 失活** |
| **ruflo → meee2** | ✅ | ✅ | **两边都活** |
| meee2 → ruflo --force | ❌ overwrite | ✅ | meee2 自愈 |

不对称是因为 meee2 `SettingsConfigManager.swift:92-160` 真 additive merge（按 `claude-hook-bridge.sh` 子串识别 entry，没找到才 append），ruflo 的 install merge guard 是 all-or-nothing。

**对 meee2 含义**：ruflo 不是产品竞品（personal brand），不必追 feature parity。但用户装了 ruflo 再装 meee2 时 ruflo 会失活——是 UX 责任，需要 detector + 一次性 toast。

---

### 2.2 smtg-ai/claude-squad（7.4k⭐ Go AGPL-3.0）— analyst: 3a2bc1 + f6613a

**定位**：tmux + worktree TUI 多 CC session 管理器。HEAD `a4ab698`，最近 push 2026-03-28（已 quiet），lifetime 14 contributors，30d 0 commit。

**核心 verdicts**：

| 维度 | Verdict | Evidence |
|---|---|---|
| Spawn vs attach | 实锤 pure spawn，无 attach | `session/tmux/tmux.go:98` `exec.Command("tmux","new-session","-d",...,t.program)`。`Restore()` 只 reattach squad 自己持久化的实例（`tmux.go:184`）。零 PID-discovery / 外部 tmux 扫描 / `.claude/projects/*` 枚举 |
| 状态数据源 | ⭐ 实锤 marketing-grade pane scrape | `tmux.go:233-256` `HasUpdated()` → `CapturePaneContent()` → 硬编码字符串匹配：`"No, and tell Claude what to do differently"` (Claude prompt L244)、`"(Y)es/(N)o/(D)on't ask again"` (aider L246)。Anthropic 改一个字就静默坏。**meee2 `TranscriptStatusResolver` 读结构化 jsonl 是范式胜出** |
| `~/.claude/` 写入 | 隔离不冲突 | config 在 `~/.claude-squad`（`config/config.go:26`）。`grep settings.json\|~/.claude` 零命中 |
| spawn 的是 vanilla `claude` | ✅ meee2 hook 自动接 | `config/config.go:17` `defaultProgram = "claude"`，全仓零 `--settings/--no-hooks/CLAUDE_*` |
| Lifecycle 落后 meee2 | 实锤 | `instance.go:407` `TmuxAlive() = i.tmuxSession.DoesSessionExist()` —— 只查 tmux，不查 Claude PID。Claude 自然退出 → squad 仍认 alive，meee2 通过 Stop hook 即刻知道 |
| GUI / menubar / electron 需求 | issue 信号弱 | `gui` 5 hits（#242 open，1👍）, `menubar` / `electron` **0 hits** —— 形态白地 |

**最值钱发现（→ 进 fixture）**：squad 路径下 ctrl-c 杀进程是 SIGHUP，**没有 Stop hook**，`TranscriptStatusResolver` 卡 `tooling`。是已有 stuck-session bug 的真实复现路径。

**战略**：squad 是寄生 add-on **最强候选**——零 squad-side 改动，meee2 strictly more accurate。

---

### 2.3 siteboon/claudecodeui (`@cloudcli-ai/cloudcli` v1.31.5 @ `beb0a50`)— analyst: 7ff1b3

**定位**：CC 启动器，web/mobile 多 CLI 远程面板。初始误以为同形态对手，深挖后是**正交**。

| 维度 | Verdict | Evidence |
|---|---|---|
| 观测机制 | 实锤 SDK subprocess wrap，非 hook 派 | `server/claude-sdk.js:15` `import { query } from '@anthropic-ai/claude-agent-sdk'`；L613-616 `queryInstance = query(...)`；L642-688 `for await` 状态从 SDK 推流 |
| 能否看见外部 CC | 看不见 | 只观测自己拉起的 session → meee2 hook bridge 是护城河 |
| `~/.claude` 写入面 | 实锤 只读不写 | `grep "writeFile.*\.claude\|fs\.write.*claude\.json"` 空集。读：`server/claude-sdk.js:421` `~/.claude.json`（mcpServers）、`server/utils/mcp-detector.js:23-24` `~/.claude/settings.json`（MCP 发现）|
| jsonl 用途 | 仅 token 计数 | `server/index.js:1232-1255` 读 `~/.claude/projects/<encoded>/<sid>.jsonl` 从尾扫 `entry.message?.usage`，**无状态推断** |
| 多 session UI | 树形侧栏 + WS 推 | `SidebarProjectSessions.tsx:117` + `AppContent.tsx:31,61` |

**SDK 模式下 jsonl 仍写标准路径**（76f485 + f6613a 交叉验证）—— `server/index.js:1232-1255` + Happy `path.ts:7` + `path.test.ts:24,31,38` 都断言 `~/.claude/projects/<encoded-cwd>/<sid>.jsonl`。SDK 是 CLI 打包成 npm，落盘格式没变。

**战略含义**：claudecodeui 跟 meee2 不抢用户。真缺口是「远程入口故事」——claudecodeui / Happy / claude-code-runner 都吃这块，meee2 没有。

---

### 2.4 stravu/crystal（前 Nimbalyst，Electron MIT）— analyst: f6613a + 双方 verifier

**定位**：worktree-派开源，Electron app。HEAD `1e18e0bc`。

**关键 evidence**（双方 verifier 字面对账）：
- `main/src/services/panels/claude/claudeCodeManager.ts:147` —— `args.push('--permission-prompt-tool', 'mcp__crystal-permissions__approve_permission', ...)`

**威胁分类**：**Type 3** 非侵入式合规——走官方 MCP permission 协议，**meee2 hooks 仍然 fire**。**不该进 detector**。

**战略含义**：Crystal 这个 pattern 是 meee2 PR #3 (`mcp__meee2__approve_permission`) 的同等防御能力 + macOS 原生体验的范本。值得抄。

---

### 2.5 getAsterisk/claudia（Tauri 桌面 GUI）— analyst: 634603

**定位**：Tauri 桌面 app for CC。

- **威胁分类**：**Type 4** 整个绕过——使用 `--dangerously-skip-permissions`，meee2 hook 在但 PreToolUse / PermissionRequest 不触发
- meee2 ambient / Dynamic Island / macOS 原生深度护城河实锤

---

### 2.6 slopus/happy-cli（Happy Coder）— analyst: f6613a → 全员修正

**定位**：移动 + E2E + 推送，重写 settings 配自己的 hooks。

**初始 verdict（错的）**：「整个替换 settings.json → meee2 hooks 失明 → THREAT」（`src/claude/claudeLocal.ts:208-210` spawn `claude --settings <自己的路径>`）

**修正后 verdict**：
- CC `--settings` 是 **MERGE 不 REPLACE**（详见 §5）
- Happy 的 `generateHookSettings.ts:32-46` 只配 `hooks.SessionStart` 一个 event，**没动其他 14 个**
- 实际：14/15 events 都 fire，仅 `SessionStart` 可能字段竞争
- **不是 THREAT**

**威胁分类**：**Type 1** 真替换（仅 SessionStart），余皆不威胁。

---

### 2.7 ccr（claude-code-router）vs runner（claude-code-runner）—— 必须区分

**这是 supervisor 一度搞混的两个 repo，区分要点：**

| 项 | claude-code-**router**（musistudio）| claude-code-**runner**（ericvtheg）|
|---|---|---|
| 用途 | proxy 层多 provider 路由 | Docker 容器 headless CI 跑 CC |
| 模式 | `--settings` 模式（曾被误以为 hijack）| `--dangerously-skip-permissions` 模式 |
| 对 meee2 | **修正后非威胁** | 错位 ignore（容器内 host socket 不可达）|

**ccr verdict**（HEAD `e270dea5`）：
- 4/4 path:line 实测 `--settings` 用法匹配
- grep `--setting-sources \| --bare` **0 命中**
- 修正后：`--settings` 是 layer 不 replace，且 ccr 配置里**完全没有 hooks 字段** → meee2 hooks 全 fire → ccr 不是威胁

---

### 2.8 multica-ai/multica（26k⭐，VC-flavored）— analyst: 3a2bc1 副线

**定位**：issue-board kanban + daemon 派活。push 2026-05-08（hyper-active），465 open issues，~4 月龄。

| 维度 | Verdict | Evidence |
|---|---|---|
| 真调 `claude`？ | 实锤 | `server/pkg/agent/claude.go:62` `cmd := exec.CommandContext(runCtx, execPath, args...)`，execPath 默认 `"claude"`（L26），args `[-p --output-format stream-json --verbose]`。真 CLI fork 不是 SDK 套壳 |
| UI 状态层级 | task-level kanban | `packages/core/types/issue.ts:3-11` `IssueStatus = backlog\|todo\|in_progress\|in_review\|done\|blocked\|cancelled`。daemon emit `running/completed/failed/timeout/aborted`（`server/pkg/agent/cursor.go:147,202,205`）只翻 kanban 列。**无 session-level thinking/tooling/waiting** |
| `~/.claude/settings.json` 冲突 | 无 | `PreToolUse/PostToolUse/settings.json` 写入零命中 |
| 改 `claude` 启动方式 | 是，根本性 | daemon (`server/cmd/multica/cmd_daemon.go:31`) 是唯一 invoker，free-form REPL 没了 |

**Q4 verdict: LOW 威胁**——*terminal-as-IDE* vs *issue-board-as-IDE*，两个非重叠 persona。只有 multica 加 "watch existing terminal sessions" 模式才会变 Medium/High——而那跟它核心 thesis 矛盾。

---

### 2.9 编排派其他几家（634603 整理）

- **wshobson/agents**：CC plugin marketplace（185 agents / 16 workflow / 153 skills / 100 commands）。**纯内容库**，不是 runtime。无 daemon，无跨机。**正交可共存**。
- **dlorenc/multiclaude**：Go supervisor + worker swarm，每 agent 一个 tmux window + git worktree。spawn 派，545⭐。
- **gastownhall/gastown**：15k⭐。Mayor (supervisor Claude) → spawn Polecats (worker)，mail / git worktree hooks 通信，状态存 git + SQLite + `.events.jsonl`，可选 daemon (`gt patrol`)，跨机 federation 走 DoltHub。
- **numman-ali/cc-mirror**：**不是**多 agent 编排，是 multi-provider variant 隔离器（Z.ai / MiniMax / Kimi / OpenRouter / Ollama / LiteLLM），生成 `mclaude / zai` 等 wrapper。完全不同领域。

---

### 2.10 ccusage —— 唯一可直接借鉴

**verdict**：🟢 绿灯。<1 天可嫁接 token / cost 显示，同源读 `~/.claude/projects/*.jsonl` 的 `entry.message.usage`，零摩擦。**可作为 P5 add-on 进 backlog**。

---

### 2.11 闭源 SaaS 5 家（634603 30min 时间盒扫描）

| 项目 | Verdict | vs meee2 |
|---|---|---|
| **Tonkotsu** | 实锤 | 直接竞品 — doc 编排 spawn agent |
| **Terragon** | 实锤（已关停）| 相邻 — 云端 spawn |
| **Omnara** | 实锤 | 直接竞品 — 移动接管，⚠️ 远程接入线撞 |
| **CodeRemote** | 实锤 | 不重叠 — 单 session Tailscale 透传 |
| **YoloCode** | 实锤 | 不重叠 — agent-as-a-service backend |

**Threat level: 中**——Tonkotsu / Omnara 直接竞品但形态正交（SaaS vs macOS native），meee2 没有 SaaS GTM 配套不必追。

---

## 3. 威胁四型分类（终态）

跨产品 hook-bypass 行为分四型，每型对策不同：

| 型 | 工具 | 行为 | meee2 hooks fire? | meee2 对策 |
|---|---|---|---|---|
| **1 真替换** | Happy Coder | `--settings` 配 `hooks.SessionStart`（仅一个 event）| 14/15 events ✅ | PR-X informational tag |
| **2 侵入式 silent fail** | ruflo | install-time merge guard `if (generated.hooks && !existing.hooks)` skip | ✅（共存正常）| **PR #0 detector + toast** |
| **3 非侵入式合规** | Crystal | `--permission-prompt-tool` 走官方 MCP permission | ✅ | **不进 detector**；借鉴此 pattern 做 P3 |
| **4 整个绕过** | Claudia | `--dangerously-skip-permissions` | hook fire 但 PreToolUse / PermissionRequest 不触发 | PR-X process-scan 检测 |
| **非威胁** | ccr / claude-code-runner | settings 无 hooks 字段 / 容器隔离 | ✅ | 无需操作 |

**真正的 hook-bypass 向量是 `--setting-sources <,project,local>`（省略 user）和 `--bare` flag**（字面 "skip hooks"）—— 这两个 flag 在 ccr / Happy / ruflo 中 **0 命中**。

---

## 4. 状态数据源对照表（meee2 真护城河）

| 工具 | 数据源 | 状态分辨率 | 评价 |
|---|---|---|---|
| **meee2** | `~/.claude/projects/<sid>.jsonl` 结构化 + 15 个 hook 事件 | thinking / tooling / idle / waitingForUser + currentTool + interrupt detect | **生态唯一** |
| ruflo | 同 jsonl | 仅 token 用量百分比 | 不分类状态 |
| claude-squad | tmux pane scrape + 硬编码字符串 | running + has-prompt（marketing-grade）| Anthropic 改一个字就坏 |
| claudecodeui | SDK 推流 | session_created / result / 工具事件 | 进程内可见，看不见外部 |
| Crystal | spawn 内部状态机 | 6 态 spawn-driven | 自闭环 |
| Claudia | 类似 Crystal | spawn 内部 | 自闭环 |
| multica | daemon emit | running/completed/failed/timeout/aborted（kanban 列）| 任务级不是 session 级 |

→ **README hero line 直出**：「meee2 is the only tool that infers semantic Claude session state from real `.jsonl` transcripts of sessions you started yourself.」

---

## 5. 方法论翻车 + 修正：CC `--settings` 是 layer/merge 不是 replace

**起因**：3 个分析师独立看到 `args.push('--settings', <self-path>)` 都**推断**「夺权 → meee2 hooks 失明」。整个 PR #0 detector + R3-C P0 watcher 优先级建立在这个推论上。**没人查 CC docs**。

**76f485 challenge → 4 方独立验证**：
- CC docs 原话："Keys you omit keep their file-based values"，array settings "merge across scopes"
- 3a2bc1 在 Claude Code 2.1.133 binary 里挖到诊断字符串：`"This comes from the --settings flag; .claude/settings.local.json won't override it."` ← **铁证 layer 不是 replace**
- 真正的 hook-bypass flag 是 `--setting-sources` (omit user) 和 `--bare`，3 个产品全部 0 命中

**级联修正**：
- ccr：原 verdict THREAT → **撤回**，全 fire
- Happy：原 verdict 整替换 → **修正**，14/15 events fire，仅 SessionStart 可能竞争
- ruflo silent-fail：**不变**（独立铁证 `executor.ts:735` 跟 `--settings` 语义无关）
- PR #0 范围从 3-dir 检测收窄到 ruflo-only
- R3-C P0 watcher 从 P0 降级到 P1（仍有独立价值：SDK / ESC / 未来工具 / hook 丢失 fallback）

**协议升级（采纳）**：「跨产品 claim 必须验外部产品行为，不能从本产品代码推断」→ design-2c99e1 输入清单第 N+1 条。

**evidence-first 协议跑赢 inference-first 的第二次**——第一次是 76f485 拒绝 ruflo 的 "89% / 12500x" 营销数字。

---

## 6. 寄生 add-on 可行性矩阵

| 工具 | add-on 可行 | 原因 |
|---|---|---|
| claude-squad | **是（最强）** | spawn vanilla `claude`，meee2 hook 零改动接入；squad 自己 lifecycle 还落后 meee2 |
| ruflo | **是** | spawn vanilla `claude`，需 detector + 一次性 toast 提示安装顺序；可读 `.claude-flow/autopilot-state.json` 显示 ctx 用量 |
| Crystal | 否 | 走 MCP permission 自闭环，不出事件给外部 |
| claudecodeui | 否 | SDK 进程内跑，`HookSocketServer` 不被触发；要接需 inbound MCP `report_session_status` 或 `@meee2/sdk-bridge` npm |
| Happy Coder | 部分 | 14/15 hook events fire，可被动观测；SessionStart 字段竞争视情况而定 |
| claude-code-runner | 否 | Docker 容器隔离，host `/tmp/meee2.sock` 不可达 |

**两种集成形态**：
- **P1 — CLI-spawn 派（自动兼容）**：ruflo / squad / Crystal 走 vanilla `claude` 子进程 → meee2 既有 15 个 hook 自动激活。零工作量。
- **P2 — SDK-in-process 派（需开口子）**：claudecodeui / Conductor SDK / Cline 在进程内 import `@anthropic-ai/claude-code` → 默认对 meee2 不可见。两条选项：
  - (a) 发布 `@meee2/sdk-bridge` npm package
  - (b) 扩 meee2 MCP（`MCPConfigManager.swift:128` 已注册 7 个 tool）加一个 inbound `report_session_status`

```
            meee2 中枢
           /          \
      hook bridge    inbound MCP
       (P1 自动)      (P2 主动)
       /                \
  ruflo/squad      claudecodeui/Cline
```

---

## 7. 战略建议

### 选 B 主 + 轻 C，排除 A

| 项 | 决定 | 原因 |
|---|---|---|
| **A** 追编排（仿 ruflo / wshobson）| ❌ | ruv.io 是 personal brand 漏斗（$149-$50k 咨询），数字也虚（89% / 12500x 都 broken），meee2 没 GTM 配套 |
| **B** 把观测做绝 | ✅ 主线 | ruflo / claudecodeui / squad 状态分类全 0；`TranscriptStatusResolver` + state-trace fixture 是独占 |
| **轻 C** 寄生兼容 | ✅ 副线 | 检测 `.claude/helpers/hook-handler.cjs` → Island 多展示「ruflo: ctx 73% / agent: coder」一行；46k stars 反向变 meee2 漏斗 |
| 抄 plugin marketplace | ❌ | 偏离定位，wshobson 已经证明会失控 |
| 抄联邦 / 跨机 | ❌ 大版 / ✅ 小版 | 不做企业 federation；做"我家里和公司两台 Mac 在同一个 Island 看到"是差异化 |
| 抄 ccusage token 估算 UI | ⏸️ P5 | 同源 jsonl 零摩擦，<1d 可嫁接，但等用户刚需信号 |
| 抄 Crystal `--permission-prompt-tool` | ✅ P3 | mcp permission tool = 同等防御能力 + macOS 原生体验 |

### 设计原则（落入 design-2c99e1 输入清单）

1. **「meee2 不背书外部数字」**：任何非 meee2 自测的指标在 UI 上必须可视化区隔（dim foreground + ⓔ icon + tooltip "Reported by ruflo · meee2 does not measure this"）且不参与 `TranscriptStatusResolver`。ruflo 哪天又出 broken claim，meee2 不 amplify。
2. **「跨产品 claim 必须验外部产品行为」**：不能从本产品代码推断（详见 §5 `--settings` 翻车）。
3. **「evidence 引文区分代码 vs doc」**：doc 引文标 `[doc]`，避免把 ASCII 流程图当代码引（来自 634603 误读 `startHookServer.ts:14-22`）。
4. **「chain-of-custody」**：每条 deliverable 附 grep 命令 + git SHA + clone 时间戳；verify dispatch 自己也要 pin 源 message-id 防转录漂移。

---

## 8. meee2 自身暴露的 bug / gap（本轮副产品）

调研顺手挖出 3 条真问题，比竞品分析本身更值钱：

### P0 — `SessionMonitor.swift:33-37` 监听路径错

监听 `~/.claude/sessions/`（meee2 自己的 JSON 存储），**不监听** `~/.claude/projects/`（CC transcript 目录）。`getTranscriptPath` 只能 by-sessionId 查找，**不主动发现新 session**。

含义：meee2 当前**完全不能主动发现**外部起的 Claude session（必须 hook 触发后才知道）。Happy / Claudia / claudecodeui 起的 session 全部 invisible。

**建议**：新建 `ClaudeTranscriptDiscoverer.swift` + FSEvent watch `~/.claude/projects/<*>/`，1-1.5d 工程，risk 低。一锅端：
- 主动发现外部 session
- SDK-host visibility（claudecodeui）
- ESC interrupt 兜底
- hook 丢失 fallback
- 未来未知工具 fallback

### P0 — `Sources/Services/ChannelRegistry` race condition

本轮调研最大瓶颈：sessions `add_member` 后立即从 member list 蒸发。3 个分析师独立目击。3a2bc1 诊断："every time the channel membership mutates (any join/leave), my session's row gets dropped from the member list, and only freshly-joining-right-now members survive"——疑似 copy-then-stomp，in-memory snapshot 丢并发 add。

**建议**：定位 `ChannelRegistry` 写路径，改成 atomic compare-and-swap 或加锁。

### P1 — claude-squad ctrl-c → SIGHUP → 无 Stop hook → resolver 卡 tooling

claude-squad 关 session 走 `tmux kill-session`，cascade 杀 claude 进程（SIGHUP），**不发 Stop hook**。`TranscriptStatusResolver` 卡 `tooling` —— 是已有 stuck-session bug 的真实复现路径。

**建议**：`meee2 test capture` 抓一条 fixture（`fixture name: stuck-tooling-after-sighup-kill`），进 `Tests/Fixtures/StateTraces/`。

### P1 — encoding drift（f6613a 顺手挖出，未细说）

可塞 ruflo PR #1 一并修。

---

## 9. 提案 PR 排期（待用户拍板）

> **重要**：以下 PR 是 supervisor 流程下 simulation 中讨论出的方案，**未经用户授权前不要动 codebase**。

| PR | 工作量 | 依赖 | 内容 |
|---|---|---|---|
| **#0** ruflo install warning | 35min | 独立 | `SettingsConfigManager.ensureHooksConfigured()` 入口前扫 `<home>/.claude-flow/`，命中弹一次性 toast「检测到 ruflo，先 `npx ruflo init` 再启动 meee2」+ 写 `~/.meee2/state/ruflo-warned.flag` |
| **#1** RufloDetector + confidence + orphaned | 3-4h | #0 | 新建 `Sources/SystemServices/RufloDetector.swift` + `RufloPresence { confidence: high/medium/low, claudeFlowDir, hookHandlerInSettings, version, orphanedHooks }` + `SessionStore.upsert` 接线 + `SessionData` schema bump (`rufloDetected/rufloVersion`) |
| **#2** RufloPlugin schema-tolerant | 4.5-5.5h | #1 | 新建 `Sources/Plugins/RufloPlugin.swift` (subclass `SessionPlugin`)，watch `.claude-flow/autopilot-state.json`；全字段 optional + default；parse 错误静默降级到 detector-only |
| **#3** attribution-explicit UI | 3.5-4.5h | #2 | dim foreground + ⓔ 图标 + tooltip "Reported by ruflo · meee2 does not measure this"；写进 design-2c99e1 设计原则 |
| **P0** ClaudeTranscriptDiscoverer | 1-1.5d | 独立 | 新建 + FSEvent watch `~/.claude/projects/<*>/` + `discoveredOnly` schema 字段 + `TranscriptStatusResolver` 不动（自然降级）|
| **P3** `mcp__meee2__approve_permission` | 6-8h | 独立 | 抄 Crystal pattern；macOS 原生 permission UI；MCP server 已有 7 tool 注册位 |
| **P5** ccusage 嫁接 | <1d | 独立 | 同源 jsonl 读 `entry.message.usage`，Island / Card 多一行 token / cost |

---

## 10. 此次多 session 协作的方法论沉淀

（这部分不是竞品发现，是过程教训）

**做对的**：
- chain-of-custody 协议（grep 命令 + git SHA + clone 时间戳）跑通了两次自我纠正
- dual-verifier pattern（3a2bc1 + 634603 各自跑同一个 grep）锁实 Crystal evidence
- evidence-first 跑赢 inference-first 两次（ruflo 数字 / `--settings` 语义）

**做错的**：
- inference-first 默认值——3 人独立从代码推断跨产品行为，没查 docs
- supervisor 一度把 7 个 sub-task 串行 dispatch，丢失了"竞品分析"这个原始 deliverable
- 频道 flap 期间频繁 hard-stop / META-CORRECTION 制造了大量 ack 噪声
- supervisor dispatch 自己有转录漂移（Crystal → Claudia / `Sources/main/...` 前缀错），后被采纳「verify dispatch 也要 pin 源 message-id」

**协议条款（沉淀给以后多 session 调研）**：
1. 每个分析师 round-1 完成必须 commit 到 `docs/competitors/<name>.md`，git 是锁，不要全活在 channel 消息里
2. dispatch 必须带原 message-id 引用 + 任务完成定义（DoD）
3. evidence-vs-inference 标签强制：[evidence-direct] / [inference-from-X-code] / [doc]；推断跨产品行为时**自动**触发外部 docs 验证
4. supervisor 改 codebase 边界（PR）必须升级到人工授权（76f485 这次的"等用户 A/B/C/D"应是协议默认）
5. 不要让 supervisor 同时承担"协调 + 产物输出"——加一个 reporter session 唯一任务是 sediment to markdown

---

**沉淀 by**：当前 main session（805480fa）on 2026-05-08
**调研 sessions**：b06a094e (supervisor) / 76f48572 (ruflo) / 3a2bc1c7 (claude-squad + multica) / 7ff1b3f2 (claudecodeui pivot) / 6346030c (闭源 + Claudia + ccusage + ccr) / f6613a10 (worktree 派 + Crystal + Happy)
**channel**: channel-bf07 (auto mode)

# meee2-workflow-bridge

把 Claude Code 原生 `Workflow` 工具的调用拦截下来，自动复制到 meee2 里执行。

## 工作原理

```
任意 Claude Code 会话调用 Workflow 工具
        │
        ▼  PreToolUse hook (matcher: Workflow)
bin/intercept-workflow.mjs
        │  1. 把内联 script / scriptPath / name + args 物化到
        │     ~/.meee2/workflow-bridge/runs/<runId>/
        │     （有 args 时生成 wrapper：workflow.mjs 内用
        │      workflow({scriptPath: payload.mjs}, args) 把 args 以真实
        │      JSON 值注入，不依赖 relay 在工具调用里传 args——实测那条
        │      路径会把 args 降级成字符串）
        │  2. POST {meee2}/api/workflow-bridge/runs 注册可恢复的 Canvas run，
        │     由 meee2 在原 cwd 拉起 relay 会话；旧版 meee2 自动降级为
        │     /api/sessions/spawn
        │     （MEEE2_WORKFLOW_RELAY=1 claude --dangerously-skip-permissions '<bootstrap>'）
        │  3. deny 本地执行，把 Canvas / relay 会话 / runDir 回告调用方模型
        ▼
meee2 relay 会话（meee2 board 可见）
        │  按 runs/<runId>/instructions.md 执行：
        │  Workflow({scriptPath: runs/<runId>/workflow.mjs, args})
        │  → 写 runs/<runId>/result.md
        │  → POST /api/sessions/<origin>/inject 通知来源会话
        ▼
来源会话收到完成通知，读 result.md 继续工作
```

同一 `runId` 的注册是幂等的；meee2 重启后会从 `handle.json` 恢复，避免创建重复 Canvas 或 relay 会话。只有明确进入 `done`/`failed` 的 7 天旧 run 才会被清理。

## 防循环

三重保险，relay 会话里的 Workflow 调用不会被再次拦截：

1. relay 会话带 `MEEE2_WORKFLOW_RELAY=1` 环境变量 → hook 放行
2. `scriptPath` 位于 `~/.meee2/workflow-bridge/` 下 → hook 放行
3. meee2 planner 派发的会话（`MEEE2_ASSISTANT_SESSION`）→ hook 放行

## 降级行为（fail-open）

以下情况 hook 静默放行，Workflow 在本地正常执行，绝不阻断用户：

- meee2 app 没在跑 / BoardServer 不可达
- `tool_input` 里没有可搬运的脚本（如 `resumeFromRunId` 续跑）
- hook 自身出现任何未预期错误（错误记录在 `~/.meee2/workflow-bridge/bridge.log`）

## 开关

- 临时关闭：`export MEEE2_WORKFLOW_BRIDGE=off`
- 持久关闭：`touch ~/.meee2/workflow-bridge/disabled`
- 恢复：`rm ~/.meee2/workflow-bridge/disabled`

## 安装

```bash
claude plugin install meee2-workflow-bridge@meee2-official
```

已打开的 Claude Code 会话需要重启才会加载新 hook。

## 调试

```bash
tail -f ~/.meee2/workflow-bridge/bridge.log     # hook 决策日志
ls ~/.meee2/workflow-bridge/runs/               # 每次转交的 run 目录
curl -s http://127.0.0.1:9876/api/state | jq '.sessions[] | {id, title, status}'
```

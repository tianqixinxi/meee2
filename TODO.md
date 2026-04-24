# meee2 TODO

项目级 backlog，挑当前 sprint 不做但必须记住的条目。PR 落地时从这里挪走。

## Waiting on upstream

### [ ] Claude Code: non-blocking context injection for `Stop` hook

**问题**: A2A / operator 消息投递给**正在工作中**的 session 时走 Stop hook drain 路径。现在唯一能把 drain 出来的消息喂回模型的姿势是返回 `{"decision": "block", "reason": "..."}`——Claude Code CLI 把这当成"阻止 Stop、把 reason 当下一轮 user content"，在 transcript 里用 `⎿ Stop hook error: ...` 前缀渲染。功能正确，但视觉像报错，容易让人误以为出了问题。

**需要 Claude Code 提供什么**:
`Stop` hook 支持类似 `UserPromptSubmit` 的 `hookSpecificOutput.additionalContext`——允许 hook 在不"block"的语义下把一段文本追加成下一轮上下文，UI 渲染也是中性的 system reminder 而不是 error。

**当前绕路**:
- resting session (idle / waitingForUser / completed + 有 ghosttyTerminalId) 完全跳过 Stop hook：`MessageRouter.pushToRestingSessionIfNeeded` 直接 Ghostty `input text` + `send key "enter"` 推文本，成功后从 inbox 删这条，Stop hook drain 就是空（见 `Sources/Services/MessageRouter.swift`、`Sources/Services/TerminalSpawner.swift`）。
- active / thinking / tooling 的 session 没别的办法——只能掉回 Stop hook + `decision:block`，吃那个 `⎿` 渲染。

**检查点**:
- `release notes` 里关注 `Stop` hook 的 `hookSpecificOutput` 字段扩展
- 或 `claude --help` 的 hook 章节
- 上了就把 `HookSocketServer.swift` 里 Stop 的 response 从 `PermissionResponse(decision:"block", reason:...)` 换到新的非阻塞 API

**相关代码**: `Sources/Services/HookSocketServer.swift:282-325`

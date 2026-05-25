# meee2 Release Plan

> 这是一份持续讨论 meee2 release 前能力缺口的 living doc。
> 后续讨论尽量沉淀到这里，保持判断清晰、可修改，并且贴着当前产品状态。

## Release 定位

meee2 v0.1 不应该试图成为一个泛 AI agent 平台。

第一版 release 应该是一个 **AI 会话工作区**：服务那些已经在用 Claude Code、Codex、Cursor 等本地 AI 工具的人，帮助他们看见、组织、控制、复盘那些原本散落在终端、app 窗口、transcript 和脑内记忆里的真实会话。

Release 承诺：

> 我开了很多 AI coding 会话。meee2 能告诉我它们正在做什么、谁卡住了、哪里需要我审批、产物证据在哪里，以及这些会话如何组成一个可管理的工作区。

## Release 标准

一个 release candidate 至少应该满足：

1. 新用户能在 3 分钟内接上 Claude Code。
2. 真实会话在 app 重启和 CLI 重启后仍能稳定出现。
3. 用户能跳回原始终端或原始 app。
4. 用户能看到进行中、受阻、待审批、失败、完成等状态。
5. 用户能把会话组织进 canvas。
6. Canvas 级 recap 可用，并且有缓存。
7. 已完成的工作有证据：diff、文件、命令、artifact、PR 或 transcript。
8. 高危会话操作必须二次确认。
9. 本地状态可恢复、可导出。
10. App 已完成打包、签名、公证和更新机制。

## P0：Release 必须完成

### 1. Onboarding 和健康检查

目标：用户要能明确知道 meee2 有没有真的接上。

需要：

- 检测 Claude Code、Codex、Cursor 和其他支持的本地工具。
- 一键配置 Claude hook。
- 检查 hook socket、BoardServer、planner sidecar、权限和存储路径。
- 出问题时给清晰的修复动作。
- 没有真实会话时提供 demo mode。

Release 风险：

- 没有这一层，即使核心 runtime 很强，用户也会感觉产品坏了。

### 2. 可靠的会话接入

目标：真实会话应该稳定出现、持久化、可恢复。

需要：

- 稳定的 Claude 会话映射。
- 对已有 Claude 会话使用正确的 resume 行为。
- 存储的 session id 失效时能自动恢复。
- Transcript tailing 能应对重启和 partial write。
- Hook event 和 transcript discovery 之间要去重。
- 有用户可见的“为什么这个会话没出现？”诊断路径。

Release 风险：

- 这是信任基础。会话丢失或重复，整个产品都会显得不可靠。

### 3. 会话工作区和 canvas 基础能力

目标：会话应该变成工作区，而不只是一张列表。

需要：

- 创建、重命名、删除、切换 canvas。
- 把会话添加、移除、绑定到 canvas 节点。
- 手动编辑节点：标题、owner、状态、描述、标签。
- 支持多种 canvas 形态，至少包括：
  - 收件箱 / 列表
  - owner 矩阵
  - 依赖图
  - 看板
- 持久化 canvas layout，并在重启后恢复。
- 保持 workflow graph 只是其中一种模式，而不是唯一模式。

Release 风险：

- 如果所有东西都只能是图，meee2 会显得比真实机会更窄。

### 4. 核心会话控制动作

目标：meee2 不只是观察会话，还要能控制会话。

需要：

- 跳回原始终端或 app。
- 给会话发送消息。
- 展示并处理权限请求。
- 停止、归档、隐藏、恢复会话。
- 替换会话等高危动作必须确认。
- 明确显示动作是成功、失败，还是当前 provider 不支持。

Release 风险：

- 只有观察没有控制，就只是 dashboard，不是 workbench。

### 5. Recap 和状态智能

目标：用户能快速理解一堆混乱会话发生了什么。

需要：

- 会话级 summary。
- Canvas 级 recap。
- 阻塞检测。
- 待审批检测。
- 输出和证据摘要。
- 每个 canvas 有 recap 缓存。
- 低噪音时间标记，例如“刚刚”、“12 分钟前”、“2 小时前”。
- 手动刷新。

Release 风险：

- Recap 决定用户看到的是“一堆卡片”，还是“我知道发生了什么”。

### 6. Artifacts 和证据

目标：每个状态都应该可检查、可追溯。

需要：

- 文件改动。
- Diff。
- 执行过的命令。
- Tool calls。
- 生成的文档或截图。
- 可用时显示 PR 链接。
- 节点输出附件。
- 每个节点 / 会话有紧凑的 evidence view。

Release 风险：

- 没有证据的 done 不可信。

### 7. 本地 planner runtime 稳定性

目标：planner AI 应该有帮助，但不能让 app 变脆。

需要：

- Sidecar 自动启动和重启。
- 桌面端、BoardServer、planner runtime 之间的连接状态可见。
- Contract drift 检查。
- 开发和 demo 用的 stub mode。
- AI runtime 不可用时，优雅 fallback 到手动编辑 canvas。
- Planner 提议的改动有 audit log。

Release 风险：

- 如果 AI 层失败得很吵，用户会把整个产品都判定为不稳定。

### 8. 打包、签名和更新

目标：用户真的能安装、保留、更新这个 app。

需要：

- DMG 构建。
- Developer ID 签名。
- Notarization 公证。
- Sparkle 更新流程。
- 稳定的 bundle id 和 entitlements。
- 首次启动权限引导。
- Debug export bundle。

Release 风险：

- local-first macOS 产品，安装和更新不无聊，就还没到 release。

## P1：强 beta 候选

### 搜索、筛选和 command palette

- 搜索会话、canvas、artifact 和 transcript。
- 按项目、状态、provider、owner、时间、标签筛选。
- 支持键盘快速操作。

### Templates

适合首屏、试用和宣传的模板：

- 隔夜 AI 工作复盘。
- 工程重构。
- Code review。
- Release checklist。
- 旅行规划。
- 求职战役。
- 游戏 NPC canvas。

### Planner proposal flow

- AI 提议修改图或 canvas。
- 人类 review 后 apply。
- 改动可解释、可回滚。
- Proposal history 和真实 canvas 状态绑定。

### 通知系统

- 权限请求。
- 会话受阻。
- 会话完成。
- 需要审批。
- Recap 更新。

### 隐私和数据控制

- 解释本地存储路径。
- 导出 canvas / 会话数据。
- 删除本地数据。
- 展示哪些内容会发送给 summarizer。
- 允许用户关闭 cloud / model 调用。

## P2：Release 后扩展

### Team sync

- 共享 canvas。
- 角色和权限。
- 团队会话可见性。
- 跨机器同步。

### Cloud / unattended agents

- 定时任务。
- 远程 runner。
- 云端 planner runtime。
- Desktop command queue。

### Agent swarm

- 自动拆解任务。
- 多 agent dispatch。
- Retry policy。
- 跨会话协作。

### Plugin marketplace

- 更多 provider。
- 更多 artifact source。
- 第三方 template。
- 插件分发和信任模型。

## 需要持续回访的产品决策

1. 第一版 release 是否只做单人、单机、local-first？
2. 最小 provider 集合是什么：只做 Claude Code，还是 Claude Code 加 Codex？
3. 默认 canvas 应该是收件箱 / 列表、图，还是 recent workspace？
4. AI planning 默认开启到什么程度？
5. 节点被认为 done 之前，必须具备哪些证据？
6. Templates 应该是一等产品对象，还是 demo data？
7. Dynamic Island 和 Board 各自应该承担什么信息？
8. 第一个付费点应该是什么：pro local app、team sync，还是 cloud automation？

## 当前工作假设

- v0.1 优先服务一台 Mac 上的单个 power user。
- Claude Code 是第一优先级集成。
- Codex 支持重要，但第一版深度可以低于 Claude Code。
- Canvas 是产品中心；Dynamic Island 是环境感知通知和轻控制面。
- Planner AI 应该有帮助，但手动使用不能依赖它。
- Evidence 比 agent 数量更重要。

## 讨论记录

### 2026-05-25

- 创建初版 release 能力清单。
- 将 v0.1 定位为 AI 会话工作区，而不是泛 agent 平台。
- 按 P0 release blocker、P1 beta 候选、P2 release 后扩展拆分。


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
4. 用户能在同一个顶层 monitor/canvas 里看到所有重要会话和子 canvas。
5. 用户能理解 canvas 的心智模型：它不是只画 workflow，而是组织 live sessions 的工作空间。
6. 用户能看到进行中、受阻、待审批、失败、完成等状态，并理解这些状态如何被节点聚合。
7. Canvas 级 recap 可用，并且有缓存。
8. 已完成的工作有证据：diff、文件、命令、artifact、PR 或 transcript。
9. 高危会话操作必须二次确认。
10. 本地状态可恢复、可导出。
11. App 已完成打包、签名、公证和更新机制。

## Release 时间点

- 内部可用 release：2026-05-31。目标是团队可以开始 dogfood，真实会话接入、monitor canvas、session control、状态聚合、artifact/evidence 和基础 recap 跑通。
- 正式 release：2026-06-04。目标是对外可安装、可更新、可解释、可排障，并具备官方模板、打包签名、隐私说明和基础团队语义。

## 核心抽象

Release 前需要先把几个核心概念定稳：

### Monitor 是顶层 canvas

meee2 不应该同时让用户理解一个 monitor 系统和一个 canvas 系统。

顶层入口应该就是一个特殊 canvas：它聚合所有用户关心的 live sessions、子 canvas、recap、blocked 状态和 approval gate。用户不需要先理解“监控页”和“画布页”的差别；他们只需要理解：

> meee2 的首页是一个 monitor canvas，它把正在发生的 AI 工作组织起来。

### Canvas 是组织 live sessions 的容器

Canvas 不等于 workflow graph。Canvas 是一种组织 live sessions、子 canvas、节点、证据和 recap 的容器。

不同 template 可以给 canvas 不同形态：

- monitor canvas
- workflow canvas
- inbox canvas
- owner matrix
- kanban
- dependency graph
- game NPC canvas

### Template 定义的不只是 UI

Template 不应该只是“预设一组节点”。它应该定义：

- canvas 的默认视图形态
- 节点类型
- 节点状态模型
- 节点聚合方式
- gate 规则
- recap 方式
- evidence 要求
- 默认动作和约束

例如：

- workflow template 的节点需要 done，因为 done 才能进入 auto/human gate，并流转到下一个节点。
- live session monitor template 不一定以 done 为核心，可能更关注 active、idle、blocked、needs attention、recap。
- 首页 monitor canvas 的节点可能是 subcanvas，状态来自 subcanvas 状态 + recap，而不是单个 session 状态。

### 节点状态来自聚合，而不只是手填

节点可以绑定：

- 单个 session
- 多个 sessions
- 一个 subcanvas
- 一个外部 artifact 或 PR

因此节点状态应该由 template 指定聚合方式：

- 单 session 节点：监听该 session 的状态。
- 多 session 节点：聚合所有 session 的状态。
- Subcanvas 节点：聚合子 canvas 的状态、recap、blocked/approval 信号。
- Workflow 节点：只有满足 done/evidence/gate 条件后才允许流转。
- Monitor 节点：显示健康度、风险、最近 recap 和是否需要人介入。

这意味着 done 不是所有 template 的通用必选概念，而是某些 template 的 gate 条件。

## Todo 总览

当前分工：

- Kai 已申领：Onboarding 和健康检查、可靠的会话接入、Monitor 和 canvas 融合、节点状态和聚合模型、核心会话控制动作、Session 内部管控、记忆和经验沉淀、Artifacts 和证据、本地 planner runtime 稳定性、Custom templates、Planner proposal flow。
- QC 先负责其余 P0/P1 项，后续可按实现细节继续拆分或调整。
- P0 DDL 按内部可用 release 和正式 release 倒排；P1 是正式 release 前的 stretch/补强项，不阻塞 release gate，但仍需要明确截止时间。

### P0 Todo

| 负责人 | 模块 | Todo | DDL | 验收信号 |
|---|---|---|---|---|
| Kai | Onboarding 和健康检查 | 新用户能一键接入 Claude Code，并看到 hook socket、BoardServer、planner sidecar、权限、存储路径是否正常 | 2026-05-27 | 首次启动 3 分钟内完成接入；异常时有明确修复动作 |
| Kai | 可靠的会话接入 | 真实 Claude/Codex 会话稳定出现、去重、持久化、可恢复 | 2026-05-28 | app/CLI 重启后会话不丢、不重复；失效 session id 可自动恢复 |
| QC | 会话工作区和 canvas 基础能力 | 支持创建/切换 canvas，绑定 live session 和 subcanvas，编辑节点基础字段 | 2026-05-29 | 用户能把多个 session 组织进一个 canvas，并在重启后恢复 layout |
| Kai | Monitor 和 canvas 融合 | 顶层 monitor 就是一个特殊 canvas，聚合 live sessions、subcanvas、recap、blocked 和 approval 信号 | 2026-05-30 | 首页能下钻到 session、节点、artifact、subcanvas；没有独立 monitor/canvas 双心智 |
| QC | 简化 canvas 使用心智 | 默认入口和 official templates 让用户不从空白画布开始 | 2026-05-31 | 用户能把 canvas 理解为工作空间/看板/监控台/流程图，而不必先学 graph editor |
| Kai | 节点状态和聚合模型 | 定义基础状态、workflow done/gate、live session 状态、subcanvas 聚合策略 | 2026-05-30 | 节点状态可解释；workflow 可 gate 流转；monitor/live template 不被 done 绑死 |
| Kai | 核心会话控制动作 | 支持 jump、send message、权限处理、停止、归档、隐藏、恢复和高危确认 | 2026-05-31 | 用户能从 meee2 控制 session，而不是只观察 |
| Kai | Session 内部管控 | 单个 session 内部可查看 prompt、工具调用、权限请求、输出、错误、artifact、时间线 | 2026-05-31 | 体验接近 cmux 式 session control；可注入消息、暂停/恢复/停止/迁移绑定 |
| QC | Recap 和状态智能 | 会话级 summary、canvas 级 recap、阻塞/审批/证据摘要、缓存和手动刷新 | 2026-05-31 | 用户能快速知道一组 session 发生了什么，recap 不在切换时重复生成 |
| Kai | Artifacts 和证据 | 展示 diff、文件改动、命令、tool calls、文档、截图、PR、节点输出附件 | 2026-05-31 | done/blocked/approval 等状态都有可追溯 evidence |
| Kai | 记忆和经验沉淀 | 沉淀 canvas/session/node 级记忆和经验，并可见、可编辑、可删除 | 2026-06-02 | 记忆有来源和证据，不是黑盒长期记忆 |
| QC | Official templates / Demo canvases | 提供官方模板和 demo canvas，并定义视图、节点、状态聚合、gate、recap、evidence | 2026-06-02 | 用户无真实 session 也能理解 meee2 的典型用法 |
| QC | Team-ready 语义模型 | 支持 member、AI member、owner、doer、reviewer、approver、assignment、handoff、approval、snapshot | 2026-06-03 | v0.1 不做实时多人同步，但能表达团队工作责任和审批 |
| Kai | 本地 planner runtime 稳定性 | Sidecar 自动启动/重启，连接状态可见，contract drift 检查，AI 不可用时 fallback | 2026-06-03 | AI 层故障不影响手动 canvas 使用 |
| QC | 打包、签名和更新 | 完成 DMG、Developer ID 签名、公证、Sparkle 更新、权限引导、debug export | 2026-06-04 | 用户可安装、更新、导出 debug 信息 |

### P1 Todo

| 负责人 | 模块 | Todo | DDL | 验收信号 |
|---|---|---|---|---|
| QC | 搜索、筛选和 command palette | 搜索会话、canvas、artifact、transcript，并按项目/状态/provider/owner/时间/标签筛选 | 2026-06-03 | 大量 session 下仍能快速找到目标并执行常用动作 |
| Kai | Custom templates | 从当前 canvas 保存为 template，编辑默认节点、视图、聚合方式和 gate 规则 | 2026-06-04 | 用户能复用自己的工作流/监控台形态 |
| Kai | Planner proposal flow | AI 提议 canvas/graph 修改，人类 review 后 apply，支持解释和回滚 | 2026-06-04 | 结构变更有 proposal history，并和真实 canvas 状态绑定 |
| QC | 通知系统 | 权限请求、会话受阻、会话完成、需要审批、recap 更新等通知 | 2026-06-04 | 用户能订阅重要事件，不需要一直盯着 Board |
| QC | 隐私和数据控制 | 展示本地存储路径，支持导出/删除数据，说明哪些内容会发给 summarizer，允许关闭 cloud/model 调用 | 2026-06-03 | 用户知道数据在哪里、发到哪里，并能控制 |

## P0：Release 必须完成

### 1. Onboarding 和健康检查

目标：用户要能明确知道 meee2 有没有真的接上。

需要：

- 检测 Claude Code、Codex、Cursor 和其他支持的本地工具。
- 一键配置 Claude hook。
- 检查 hook socket、BoardServer、planner sidecar、权限和存储路径。
- 出问题时给清晰的修复动作。
- 没有真实会话时显示空状态，引导用户启动第一个真实 Claude Code/Codex session，不用 demo session 代替真实接入。

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
- 顶层 monitor 也使用 canvas 模型，而不是独立心智。
- Canvas 可以包含 live session 节点和 subcanvas 节点。
- 用户能在 UI 上理解当前 canvas 的 template 类型和聚合规则。

Release 风险：

- 如果所有东西都只能是图，meee2 会显得比真实机会更窄。

### 4. Monitor 和 canvas 融合

目标：meee2 的首页就是顶层 monitor canvas。

需要：

- 顶层 monitor 展示所有重要 live sessions。
- 顶层 monitor 可以展示子 canvas 节点。
- 子 canvas 节点显示聚合状态和 recap。
- blocked、approval、failed、done 等信号能从子 canvas 向上冒泡。
- 用户可以从顶层 monitor 下钻到具体 session、节点、artifact 或子 canvas。
- 顶层 monitor 支持按状态、owner、项目、template 过滤。
- Monitor 不做成另一个独立产品面，避免和 canvas 心智冲突。

Release 风险：

- 如果 monitor 和 canvas 是两个系统，用户会不知道哪里才是工作真实状态。

### 5. 简化 canvas 使用心智

目标：用户不需要先学习“画布编辑器”，也能使用 canvas。

需要：

- 默认入口是可理解的 monitor canvas。
- 常见 template 有清晰默认视图，不要求用户从空白画布开始。
- 节点创建、绑定 session、查看 evidence、看 recap 都走同一套基础交互。
- Canvas 的 advanced 编辑能力可以隐藏在 inspector / settings 里。
- 避免把所有东西暴露成 graph editor 操作。
- 允许用户把 canvas 当成“工作空间”、“看板”、“监控台”或“流程图”，而不是强迫他们理解内部抽象。

Release 风险：

- 如果 canvas 心智太重，产品会只适合内部 power user，普通用户很难上手。

### 6. 节点状态和聚合模型

目标：不同 template 可以有不同状态语义，但状态必须能解释和聚合。

需要：

- 定义基础状态集合：active、idle、blocked、needs approval、failed、done、unknown。
- 定义 workflow template 的 done/gate 规则。
- 定义 live session template 可以不依赖 done。
- 定义 subcanvas 节点如何聚合子 canvas 状态。
- 定义多 session 节点如何聚合多个 session 状态。
- 状态聚合结果要可解释：为什么这个节点是 blocked / needs approval / done。
- Gate 可以是 auto gate 或 human gate，且必须记录 evidence 和 decision。

Release 风险：

- 如果 done 被当成所有节点的硬规则，meee2 会被 workflow 绑死；如果完全不定义 done，workflow 又无法可靠流转。

### 7. 核心会话控制动作

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

### 8. Session 内部管控

目标：单个 session 内部也要可控，接近 cmux 对多个进程/会话的管控感。

需要：

- 一个 session 内部能看到 prompt、工具调用、权限请求、输出、错误、artifact。
- 能区分当前 session 是否 running、idle、waiting input、waiting permission、failed。
- 支持暂停、恢复、停止、归档、隐藏。
- 支持向 session 注入消息或后续指令。
- 支持查看 session 的关键上下文和 recap。
- 支持 session 内部事件时间线。
- 支持将 session 绑定、解绑、迁移到不同节点或 canvas。
- 高危控制动作必须可解释、可撤销或二次确认。

Release 风险：

- 如果只在 canvas 层好看，但 session 内部不可控，meee2 还是无法替代用户手工管理终端。

### 9. Recap 和状态智能

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

### 10. Artifacts 和证据

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

### 11. 记忆和经验沉淀

目标：session 不只是临时记录，应该沉淀为可复用的上下文和经验。

需要：

- Canvas 级记忆：目标、约束、关键决策、当前状态。
- Session 级记忆：做过什么、产物是什么、遇到什么坑。
- 节点级经验：某类任务下次怎么做、哪些命令/文件/流程有效。
- 记忆可见、可编辑、可删除。
- 自动沉淀需要有来源和证据。
- 不做黑盒长期记忆，先做可解释的 project/canvas memory。

Release 风险：

- 没有记忆，meee2 只是实时 dashboard；有黑盒记忆，团队不敢信。

### 12. Official templates / Demo canvases

目标：用户打开产品时能立刻理解 meee2 可以怎么用。

需要：

- Official templates 至少覆盖：
  - 隔夜 AI 工作复盘
  - 工程重构
  - Code review
  - Release checklist
  - Team control tower
  - 游戏 NPC canvas
- 每个 template 定义 canvas 形态、节点类型、状态聚合方式、gate 规则和 evidence 要求。
- Demo canvas 可以无真实 session 运行，用于 onboarding 和官网演示。
- Custom template 可以后置，但 schema 要允许从 canvas 保存为 template。

Release 风险：

- 没有 template，canvas 会像空白编辑器；用户不知道从哪里开始。

### 13. Team-ready 语义模型

目标：v0.1 可以是单机 local-first，但数据和 UI 必须能表达团队工作。

需要：

- Team member / AI member 的基础数据模型。
- 节点包含 owner、doer、reviewer、approver。
- Assignment、handoff、approval request、approval decision。
- Team recap：谁卡住、谁完成、谁需要审批、证据在哪里。
- Shareable snapshot。
- 预留权限字段，但不做完整 RBAC。
- 不做实时多人同步。

Release 风险：

- 如果没有 team 语义，后续 team sync 会推倒重来；如果 P0 做完整 team sync，release 会被拖爆。

### 14. 本地 planner runtime 稳定性

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

### 15. 打包、签名和更新

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

### Custom templates

Official templates 属于 P0。这里讨论的是用户自定义模板：

- 从当前 canvas 保存为 template。
- 编辑 template 的默认节点、视图、聚合方式和 gate 规则。
- Template 版本管理。
- 个人 template 和团队 template 的边界。

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
9. Done 是所有节点的基础状态，还是 workflow template 的 gate 条件？
10. Subcanvas 节点的聚合策略应该由 template 定义，还是由用户逐节点配置？
11. 顶层 monitor canvas 是否应该允许用户深度自定义，还是保持强约束？

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

### 2026-05-26

- 将 monitor 和 canvas 合并为同一个顶层抽象：顶层 canvas 就是 monitor。
- 明确 canvas 不是 workflow graph，而是组织 live sessions、subcanvas、证据和 recap 的容器。
- 将 template 定义扩展为：视图形态、节点类型、状态模型、聚合方式、gate 规则、recap 方式和 evidence 要求。
- 讨论 done 状态：workflow template 需要 done 进入 gate 并流转，但通用 live session template 不一定以 done 为核心。
- 新增 P0：monitor/canvas 融合、简化 canvas 心智、节点状态和聚合模型、session 内部管控、记忆和经验沉淀、official templates、team-ready 语义模型。

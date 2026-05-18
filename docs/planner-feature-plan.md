# Planner Graph — Feature Plan

> 来源:同事在 commit `4f1fda5`（`codex/react-flow-planner-graph`）之后留下的 Feature Plan todo。
> 本文件把 todo 拆成可落地的分阶段实施计划。基线代码状态见每阶段「现状」。

## 0. 基线现状（commit 4f1fda5）

调研结论 —— 大部分脚手架已就位,todo 的核心是把「proposal / stub」推进到「真执行 / 真数据」:

| 能力 | 状态 | 位置 |
|---|---|---|
| Graph 模型 / proposal 创建·校验·审批·应用 | ✅ 完成 | `PlannerCore.swift`、`PlannerProposalValidator` |
| Layout 持久化、React Flow 交互 | ✅ 完成 | `PlannerStore`、`PlannerGraph.tsx` |
| Proposal 流程 UI（preview→approve→apply modal） | ✅ 完成 | `PlannerProposalPanel.tsx` |
| 权限模型（owner/doer/viewer/suggestion） | ✅ 模型已定义 | `PlannerCanvasRole`、`PlannerPermission` |
| Team 页面 / teamDirectory | ✅ 真数据（缺头像源） | `TeamView.tsx`、`teamDirectory.ts` |
| BYOA-local dispatch | ⚠️ 只记录 spawn intent,无回流 | `recordPlannerDispatchIntents` |
| CI-agent / Human dispatch | ❌ 无执行器 | — |
| 真 Planner adapter（BYOA→proposal） | ❌ 未接入 | `generatePlannerProposal` |
| Integrations（GitHub/Lark） | ⚠️ UI 壳,Configure 禁用 | `IntegrationsView.tsx` |

## 1. 实施阶段

### Phase 1 — meee2 AI 真 Planner（todo「meee2 AI 真 Planner」）
**目标**:`generatePlannerProposal` 接真实 BYOA/CLI planner adapter。
- 新增 `PlannerAdapter` 协议 + BYOA 实现:以 graph 全量上下文为 prompt,调用 `claude`/`codex` CLI。
- 上下文构建:序列化 `PlannerGraphState`(canvas/nodes/states/edges/artifacts/access)为 JSON prompt,复用 `AssistantContextBuilder` 模式。
- 输出契约:严格 proposal JSON `{canvasId, summary, changes:[...]}`。
- Validator 加固(`PlannerProposalValidator` ~662-735):已校验 canvas 匹配、非空 changes、节点存在;**补**:拒绝跨 canvas 节点引用、未知 node kind,补单测。
- 文件:新增 `Sources/Board/PlannerAdapter.swift`;改 `PlannerCore.swift`、`AssistantTools.swift`、`BoardAPI.swift`。

### Phase 2 — Dispatch 真执行（todo「Dispatch 真执行」）
**目标**:step node 派发 Claude/Codex/BYOA/Human,状态回流。
- **dispatch 后才建 session node**:当前 bind 是独立动作。改 dispatch apply 逻辑 —— apply 后才创建 session node + edge 并绑定 spawn 出的 session id。
- **runState 回流**:`SessionMonitor` 按 `purpose="planner:<nodeId>"` 标签把 session 状态映射到 `node.workflowRunState`。
- **Human runner**:节点停在 `gateWait`,owner/doer 在 inspector 标记完成。
- **CI-agent runner**:范围待定(见开放问题),短期可只保留 proposal。
- 文件:`PlannerCore.swift`(dispatch apply)、`BoardAPI.swift`(`recordPlannerDispatchIntents`)、`SessionMonitor.swift`。

### Phase 3 — 权限闭环（todo「权限闭环」)
**目标**:后端强制校验,而非仅 UI 禁用。
- 每个 mutating planner endpoint 校验 `PlannerAccess`:approve/apply/reject → 仅 owner;节点执行态更新 → 仅该节点 doer;viewer 只读。
- **public/private canvas**:`PlanningCanvas` 加 `visibility` 字段 + `PlannerStore` schema 迁移;`getPlannerGraphState`/canvas list 按可见性过滤。
- 文件:`PlannerCore.swift`、`BoardAPI.swift`(全部 planner handler)、`BoardDTO.swift`。

### Phase 4 — Team 页面（todo「Team 页面」)
基本已完成,剩余:
- **`ownerAvatarUrlByUserId` 真数据源**:从 meee2 Online team API 拉成员+头像(用户 `userProfile.teams` 已有);新增后端 `/api/team/members` 或扩展 userProfile。
- TeamView 增加 canvas access 列、owner/doer/suggestion 权限展示。
- 文件:`teamDirectory.ts`、`TeamView.tsx`、`api.ts`、后端 team endpoint。

### Phase 5 — Integrations 真接入（todo「Integrations 真接入」)
净新增最多。
- GitHub:repo/PR/issue picker → 经 `attach_artifact_to_node` 落为 `PlannerArtifact`(impl-pr/main-merge/check-result)。
- Lark:doc/minutes/PRD/verdict picker → artifact(idea-draft/prd/lark-doc/prerelease-verdict)。
- **artifact 只显式 attach**,不自动猜;picker 出现在 IntegrationsView + node inspector。
- 打通 Configure 按钮的鉴权流(GitHub token / Lark 授权,token 经 ccops)。
- 文件:`IntegrationsView.tsx`、新增 picker 组件、`api.ts`、后端 integration endpoints、对应插件。

### Phase 6 — Workflow 引导（todo「Workflow 引导」)
- 按 `node.workflowRunState`(gate-wait/failed/pending/running)给每个 step 不同 next action。
- 后端 `PlannerMonitorItem` / graph state 增加 per-node `nextAction`。
- 文件:`PlannerCore.swift`(monitor)、`WorkspaceMonitor.tsx`、`PlannerNodeCard.tsx`、`PlannerProposalPanel.tsx`。

### Phase 7 — Graph UI polish（todo「Graph UI polish」)
- 压缩 `PlannerNodeCard` 信息层级。
- **Inspector modal**:完整展示 owner/doer/session/artifact/gate(当前只有 Details 按钮,需新建 modal)。
- MiniMap 样式校准;Mobile/PC 截图 QA。
- 文件:`PlannerNodeCard.tsx`、新增 `NodeInspectorModal.tsx`、`planner.css`、`PlannerGraph.tsx`。

## 2. 建议顺序与依赖

```
Phase 1 (真 Planner) ──┬─> Phase 2 (Dispatch 真执行) ──> Phase 6 (Workflow 引导)
                       │
Phase 3 (权限闭环) ─────┘   横切,尽早做
Phase 4 (Team)         独立,可随时
Phase 5 (Integrations) 独立,工作量最大
Phase 7 (UI polish)    收尾,功能稳定后
```

推荐:**1 → 3 → 2 → 4/5 并行 → 6 → 7**。

## 3. 开放问题（需同事/产品确认）

1. CI-agent runner 这一期是否要真执行,还是只保留 proposal?
2. GitHub / Lark 鉴权机制 —— token 走 ccops?还是插件内 OAuth?
3. meee2 Online 是否已有 team members + 头像 API 可供 Phase 4 调用?
4. 被 `git clean` 删除的 `docs/TEAM_SUPPORT_SPEC.md`、`docs/planner-byoa-spec.md` 是否还有备份 —— 它们可能含本计划未覆盖的细节。

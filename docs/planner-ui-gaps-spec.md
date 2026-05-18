# Planner UI Gaps — Spec

> 背景:planner-graph 8 个阶段的后端已落地(见 `planner-feature-plan.md`)。
> 审计 `packages/board-app/src/api.ts` 的全部 planner 动作后发现 —— 有 5 个能力
> **HTTP 端点 + api.ts client 都在,但没有任何组件调用**,即用户在 UI 上无法触发。
> 本 spec 定义这些缺失入口该怎么补。

## 1. 审计结论

| 能力 | 后端端点 | api.ts client | UI 入口 |
|---|---|---|---|
| Dispatch node(派生新 session) | `POST …/nodes/:id/dispatch` | `dispatchPlannerNodeSession` | ❌ 无 |
| Bind session(挂已有 session) | `POST …/nodes/:id/bind-session` | `bindPlannerSessionToNode` | ❌ 无 |
| Create sub-canvas(从节点建子画板) | `POST …/nodes/:id/sub-canvas` | `createPlannerSubCanvasFromNode` | ❌ 无 |
| Refine node(定向细化某节点) | `POST …/proposals/refine` | `refinePlannerNode` | ❌ 无 |
| Canvas visibility(public/private) | `PATCH …/canvases/:id/visibility` | `setPlannerCanvasVisibility` | ❌ 无 |
| Assign doer(给节点指派执行人) | 无专用端点(经 proposal updateNode) | — | ❌ 无 |

已有 UI 的(对照):generate proposal、inspect drift、preview/approve/apply/reject、
update layout(拖拽)、attach artifact(`NodeInspectorModal`)、create delivery
pipeline(空画板次要链接)。

## 2. 共同交互约定

- Dispatch / Bind / Create-sub-canvas / Refine / Assign-doer **都返回一个 `PlanProposal`**,
  统一走既有的 `proposal → Preview → Approve → Apply` 闸门(`PlannerProposalPanel` 的 modal)。
  即:节点动作不直接改图,只产 proposal。
- 触发后把返回的 proposal 灌进 `PlannerGraph` 现有的 proposal 状态,复用现有审批 UI。
- 权限:动作按 Phase 3 的 `requireNodeUpdate` —— owner 任意节点;doer 仅自己 `doerId` 的节点;
  viewer 全禁用。UI 上无权限的按钮置灰,tooltip 说明原因。

## 3. 缺口逐项

### Gap 1 — Dispatch node
- **位置**:`NodeInspectorModal` 新增「Node actions」区。
- **交互**:「Dispatch」按钮 → 弹 runner 选择(`claude` / `codex` / `byoa-local` / `human`)
  → 调 `dispatchPlannerNodeSession(canvasId, nodeId, runner)`。
- **结果**:返回 dispatch proposal;apply 后(Phase 2)对 spawning runner 自动建 session 节点 +
  step→session 边;`human` → 节点停 `gateWait`。
- **约束**:仅 `step`-kind 节点可 dispatch;已绑定 session 的节点应提示「已派发」。

### Gap 2 — Bind existing session
- **位置**:同上「Node actions」区。
- **交互**:「Bind session」按钮 → 弹一个**本地 session 选择器**(列出 `boardState.sessions`,
  复用 `SessionsView` 的列表样式,可搜索)→ 选中一个 → 调
  `bindPlannerSessionToNode(canvasId, nodeId, sessionId)`。
- **结果**:返回 bind proposal;apply 后该节点 `sessionId` 指向已有 session。
- **与 Dispatch 区别**:Dispatch 起新 session;Bind 挂已存在的。两者并列,不互斥。
- **设计依据**:符合「新 canvas 不自动关联已有 sessions」—— 关联必须显式手动。

### Gap 3 — Create sub-canvas from node
- **位置**:`NodeInspectorModal`「Node actions」区。
- **交互**:「Break into sub-canvas」按钮 → 可选输入子画板标题 →
  `createPlannerSubCanvasFromNode(canvasId, nodeId, title?)`。
- **结果**:返回 proposal,apply 后节点获得 `subCanvasId`;节点卡片已有的「Open sub-canvas」
  按钮随之可用(该按钮已存在,只是一直没有「创建」入口配它)。

### Gap 4 — Refine node
- **位置**:`NodeInspectorModal`「Node actions」区。
- **交互**:「Refine with meee2 AI」按钮 → 输入细化诉求(reason)→
  `refinePlannerNode(canvasId, nodeId, reason)` → 让 planner adapter 针对**单个节点**产细化 proposal。
- **结果**:返回 proposal,走审批闸门。区别于整图 `generatePlannerProposal` —— 这是节点定向。

### Gap 5 — Canvas visibility
- **位置**:画板顶部 header(canvas 标题旁),不是节点级。
- **交互**:一个 public/private 切换控件 → `setPlannerCanvasVisibility(canvasId, visibility)`。
- **权限**:owner-only(后端已强制),非 owner 显示为只读状态标。
- **结果**:直接生效(非 proposal —— 这是 canvas 元数据,不是图变更)。

### Gap 6 — Assign doer
- **现状**:节点 `doerId` 目前只能通过 proposal 的 `updateNode` change 设置,无直接入口。
- **位置**:`NodeInspectorModal` 的 Ownership 区。
- **交互**:doer 字段旁加一个成员选择器(数据源 = Phase 4 的 `/api/team/members`)→
  选中成员 → 生成一个轻量 `updateNode`(仅 `doerId` 字段)proposal。
- **备注**:无专用端点,复用 `proposePlannerGraphChange`;走审批闸门。
- **依赖**:Phase 4 的 team members 数据源。

## 4. 落点汇总

- **`NodeInspectorModal`** 新增「Node actions」区,容纳 Gap 1/2/3/4 + Gap 6 的 doer 选择器。
  这是最自然的落点 —— 节点级动作集中在节点详情里。
- **画板 header** 容纳 Gap 5 的 visibility 切换。
- 新增一个可复用组件 `SessionPicker`(Gap 2 用)。
- 所有节点动作复用现有 proposal 审批 modal,不新建审批 UI。

## 5. 建议优先级

1. **Gap 1 + 2(Dispatch / Bind)** —— 最高。没有它们,Phase 2 的 dispatch 真执行在 UI 上根本走不通。
2. **Gap 5(visibility)** —— 小,Phase 3 的 public/private 才有 UI 出口。
3. **Gap 6(assign doer)** —— 中,让「在 team 里把节点分给具体人」闭环。
4. **Gap 3 + 4(sub-canvas / refine)** —— 补全,优先级最低。

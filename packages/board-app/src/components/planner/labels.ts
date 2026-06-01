// UI-simplification §1 — 统一中文文案。所有面向用户的状态/动作/模式标签
// 集中在这里,避免 PlannerNodeCard / ArtifactsView / Inspector / Rail 各自维护
// 一份英文文案再次分叉。
//
// 关键:primaryActionLabel 不再返回显示文案,而是返回结构化枚举 PrimaryAction。
// 调用方用 enum 做 switch 分发,用 PRIMARY_ACTION_TEXT[action] 显示。原先用
// 英文字符串字面量(如 'Open sub-flow')比较的代码块在改成中文文案时会全部
// 走 else 分支 → 用 enum 切开 dispatch 路径。

import type { PlannerWorkflowRunState, PlanningNode, PlanningNodeStatus, RunNextAction } from '../../types'

// === Display status (PR1 running-session-visual) ===
// 卡片 / inspector 顶端的状态徽章统一从这里派生。
// 优先看 workflowRunState(运行态最权威),退化到 design status。
// 返回 { label, tone };tone 用于 .planner-node__status--<tone> CSS 着色。
export type DisplayStatusTone =
  | 'ready'
  | 'running'
  | 'awaiting'
  | 'failed'
  | 'done'
  | 'blocked'

export interface DisplayStatus {
  label: string
  tone: DisplayStatusTone
}

export function deriveDisplayStatus(node: PlanningNode): DisplayStatus {
  // 3-态会话模型(2026-06-01): 用户面只看「未启动 / 运行中 / 需要人回应」三态 + 「完成」。
  // 「失败」已下线 —— 会话结束=回到未启动(后端 dead→pending+清绑定);唯一残留的
  // failed 来自显式 submit blocked,本质是 agent/人「需要人回应」,统一并入该桶。
  // 纯上游依赖未就绪的 blocked(无 runState)仍显示「卡住」(等上游),非会话态。
  const wfs = node.workflowRunState ?? null
  // canvas 是活动账本不是 PM(见 canvas-is-ledger-not-pm): step / session 这类
  // 「工作节点」没有「完成」态 —— 做完=会话结束=回到「未启动」,产物留在账本
  // (卡片产物区)。只有 subCanvas / artifact / external 等非工作节点保留「完成」。
  const isWorkNode = (node.nodeKind ?? 'step') === 'step' || node.nodeKind === 'session'
  if (wfs === 'running' || wfs === 'dispatched') {
    return { label: '运行中', tone: 'running' }
  }
  if (wfs === 'awaiting-input' || wfs === 'gate-wait' || wfs === 'failed') {
    return { label: '需要人回应', tone: 'awaiting' }
  }
  if (!isWorkNode && (wfs === 'done' || node.status === 'done')) {
    return { label: '完成', tone: 'done' }
  }
  if (node.status === 'blocked') {
    return { label: '卡住', tone: 'blocked' }
  }
  return { label: '未启动', tone: 'ready' }
}

// === 运行态徽章 (§1 五种统一) ===
export function workStatusLabel(
  status: PlannerWorkflowRunState,
  hasSelectedDelivery: boolean,
): string {
  if (!hasSelectedDelivery) return '选交付物'
  switch (status) {
    case 'pending':
    case 'ready_to_start':
      return '未启动'
    case 'dispatched':
    case 'running':
      return '运行中'
    case 'awaiting-input':
    case 'gate-wait':
    // 3-态会话模型: 显式 blocked-submit 仍内部记 failed,但用户面=「需要人回应」,不显示「失败」。
    case 'failed':
      return '需要人回应'
    case 'done':
      return '完成'
  }
}

// === 设计态徽章 (3-tai cut 2026-05-29 — 3 状态: ready / blocked / done) ===
// `draft` / `working` 是 legacy raw value,后端 normalizer 会翻译成 `ready`,
// 这里也兜底成「就绪」,避免老数据在前端渲染时露出已删词。
export function planStatusLabel(status: string): string {
  switch (status) {
    case 'ready':
      return '就绪'
    case 'blocked':
      return '卡住'
    case 'done':
      return '完成'
    default:
      // legacy 'draft' / 'working' 都走这里,兜底成「就绪」
      return '就绪'
  }
}

// === Mode 徽章 ===
export type NodeMode = 'auto' | 'gate' | 'human'
export const MODE_LABEL: Record<NodeMode, string> = {
  auto: '自动',
  gate: '需把关',
  human: '人工',
}

// 节点 mode 徽章的 tooltip 文案 —— 用「谁来做 / 按什么节奏跑」描述,
// 避免直接抛 execution / governance 这类内部术语。参见
// doc/prd/ui-simplification.md §1 隐藏词列表。
export const MODE_TOOLTIP: Record<NodeMode, string> = {
  auto: '这一步自动跑,做完就推进',
  gate: '这一步做完后需要把关人确认',
  human: '这一步由人来做',
}

// ui-simplification §2.11 — mode badge 显式渲染 schedule 信息,
// 不另起独立 schedule chip。给定 auto mode + interval(已格式化),
// 拼出 `自动 · 每 1h` 这种复合标签;tooltip 同步换成中文「定时」语义,
// 不暴露 'session tick' 这类 runtime 内部词(§0 隐藏词列表)。
export function modeBadgeLabel(mode: NodeMode, scheduleInterval: string | null): string {
  if (mode === 'auto' && scheduleInterval) {
    return `${MODE_LABEL.auto} · 每 ${scheduleInterval}`
  }
  return MODE_LABEL[mode]
}

export function modeBadgeTooltip(mode: NodeMode, scheduleInterval: string | null): string {
  if (mode === 'auto' && scheduleInterval) {
    return `定时触发:每 ${scheduleInterval} 跑一次`
  }
  return MODE_TOOLTIP[mode]
}

// === Primary action — 结构化枚举 + 显示文本 ===
//
// 'none' = 不显示按钮。其他值是分发到的具体行为。文案改中文后不能再用
// 字符串字面量比较,否则点击会走错分支。
export type PrimaryAction =
  | 'none'
  | 'open-sub-canvas'
  | 'create-session'
  | 'creating-session'
  | 'open-session'
  | 'spawn-session'
  | 'view-output'
  | 'resolve'
  | 'open'
  | 'select-delivery'
  | 'assign-person'

export const PRIMARY_ACTION_TEXT: Record<Exclude<PrimaryAction, 'none'>, string> = {
  'open-sub-canvas': '打开子画板',
  'create-session': '开新会话',
  'creating-session': '创建中…',
  'open-session': '打开会话',
  'spawn-session': '开干',
  'view-output': '查看成果',
  resolve: '去处理',
  open: '打开',
  'select-delivery': '选交付物',
  'assign-person': '分配负责人',
}

export function primaryActionLabel(input: {
  mode: 'design' | 'run'
  hasSelectedDelivery: boolean
  runStatus: PlannerWorkflowRunState
  workflowRunState: PlannerWorkflowRunState | null
  sessionId: string | null
  responsibleLabel?: string
  nodeKind: string
  status?: string
  blockers: string[]
  canChangeStatus?: boolean
  canCreateSession: boolean
  creatingSession: boolean
}): PrimaryAction {
  // UI-simplification — "Open session" 已从卡片主操作砍掉(user 反馈):
  // 平替在 inspector 进展段 hover 上。返回 'none' 等于不显示主操作按钮 →
  // 用户点节点开 inspector,在 进展 hover 出 session detail。
  if (input.mode === 'design') {
    if (input.nodeKind === 'subCanvas') return 'open-sub-canvas'
    // alpha (2026-05-29) — 「开干」按钮:design 态 ready 节点(step 或 session),
    // 没有 session 且具备创建权限时,直接 spawn session。这条路径合并了原
    // step 分支的 create-session 语义,并补上 session 节点的 spawn 入口
    // (之前 session nodeKind 走 fall-through 返回 'none',用户无从启动)。
    if (input.nodeKind === 'step' || input.nodeKind === 'session') {
      if (input.creatingSession) return 'creating-session'
      if (input.sessionId) return 'none'
      if (
        input.status === 'ready'
        && input.canChangeStatus
        && input.canCreateSession
      ) {
        return 'spawn-session'
      }
      if (input.nodeKind === 'step') {
        return input.canCreateSession ? 'create-session' : 'none'
      }
      return 'none'
    }
    return 'none'
  }
  if (!input.hasSelectedDelivery) return 'select-delivery'
  if (!input.responsibleLabel) return 'assign-person'
  if (input.runStatus === 'done') return 'view-output'
  if (input.runStatus === 'failed' || input.runStatus === 'gate-wait' || input.blockers.length > 0) {
    return 'resolve'
  }
  if (input.sessionId) return 'none'
  if (input.creatingSession) return 'creating-session'
  return 'open'
}

// === nextAction (inspector / 进展行用) ===
export function nextPlanAction(
  hasResponsible: boolean,
  hasSubCanvas: boolean,
  nextAction: string | null | undefined,
): string {
  if (!hasResponsible) return '请先分配负责人'
  if (hasSubCanvas) return '已有子画板'
  return nextAction?.trim() || '复盘这一步'
}

export function nextWorkAction(
  hasSelectedDelivery: boolean,
  rawNextAction: RunNextAction | null | undefined,
): string {
  if (!hasSelectedDelivery) return '选交付物后查看运行态'
  if (!rawNextAction) return '等下一步'
  return runNextActionLabel(rawNextAction)
}

export function runNextActionLabel(action: RunNextAction): string {
  switch (action) {
    case 'waiting-on-upstream':
      return '等上游'
    case 'ready-to-dispatch':
      return '可以开干'
    case 'in-progress':
      return '运行中'
    case 'gate-review':
      return '等审核'
    case 'confirm-artifacts':
      return '完成 — 查看成果'
    case 'needs-attention':
      return '卡住'
  }
}

// === Footer action 文案 ===
export const FOOTER_LABELS = {
  rerun: '重跑',
  markDown: '标记卡住',
  cancel: '取消',
  delete: '删除',
  confirmDelete: '确认删除',
} as const

// === Card hover / aria 文案 (§1 隐藏 session / artifact 原名 / runtime 等内部术语) ===
// PlannerNodeCard 的 title / aria-label 之前是英文,会在 hover 时把
// 'session tick' / 'artifact preview' 这些隐藏词暴露给用户;同时屏幕阅读器
// 用户得到全英文体验。统一中文化,内部术语换成「预览 / 状态 / 定时刷新」。
export const CARD_TOOLTIPS = {
  collapseArtifact: '收起预览',
  expandArtifact: '展开预览',
  changeStatus: '改变状态',
  statusFor: (title: string) => `${title} · 状态`,
  // schedule 信息已折入 mode badge(modeBadgeLabel / modeBadgeTooltip),
  // 不再用独立 chip 暴露 'session tick' 这类内部词。参见 ui-simplification §2.11。
  cancelSessionCreation: (title: string) => `${title} · 取消创建`,
  deleteNode: '删除节点',
  deleteConfirm: '再点一次确认删除',
  deleteAria: (title: string) => `删除 ${title}`,
  deleteConfirmAria: (title: string) => `确认删除 ${title}`,
} as const

// === Artifact 区文案 ===
export const ARTIFACT_LABELS = {
  empty: '等成果',
  // ui-simplification §1 — artifact 加载失败时不能把 axios 原文(e.g.
  // `Request failed with status code 500`)直接抛给用户。state 里只放面向
  // 用户的中文,debug 信号通过 console.warn → JSConsoleBridge 落到
  // ~/Library/Logs/meee2.log,不丢。
  loadError: '成果暂时读不到，稍后再试',
  // ui-simplification §1 把 'HTML artifact / File artifact / Text artifact'
  // 这类内部 kind 词列为隐藏词,fallback metadata 头改成中文「文件 / 网页 / 文本」。
  fileLabel: '文件',
  htmlLabel: '网页',
  textLabel: '文本',
  saveInput: '保存输入',
  pastePlaceholder: '粘贴文档链接或剪贴板引用',
  input: '入',
  output: '出',
  artifact: '成果',
  removeFromCanvas: '从画板移除',
} as const

// === OwnerChip 文案 (§1 隐藏 owner-doer-viewer 词,§2.6 footer = @assignee) ===
export const OWNER_CHIP = {
  unassigned: '未分配',
  prefixAssigned: '@',         // 显示成 @张三
  tooltipAssignedRevoke: '暂不支持改派',
  tooltipAssign: (nodeTitle: string) => `分配「${nodeTitle}」给负责人`,
  tooltipReadonly: (label: string) => `负责人:${label}`,
} as const

// === SubCanvasRefCard ===
export const SUBCANVAS_REF_LABELS = {
  assigned: '已分配',
  subCanvas: '子画板',
  in: '入参',
  out: '出参',
  openSubCanvas: '打开子画板',
  ownedByTooltip: (label: string) => `已分配给 ${label},父画板里不能改`,
  openTooltip: (label: string) => `打开 ${label} 的子画板`,
  // cardinality 枚举翻译;null = 该 chip 不渲染
  cardinality: {
    '1': '一份',
    'many': '多份',
    'unspecified': null,
  } as Record<string, string | null>,
} as const

// Re-export DESIGN_STATUS_OPTIONS-related typing helper if needed by consumers
export type { PlanningNodeStatus }

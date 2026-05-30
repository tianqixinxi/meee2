import {
  AlertTriangle,
  CalendarClock,
  ExternalLink,
  Eye,
  FileText,
  Flag,
  Layers,
  RefreshCw,
  Route,
  Settings2,
  Signpost,
  Sparkles,
  Undo2,
  UserRound,
  X,
} from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import {
  proposePlannerGraphChange,
  updatePlannerNodeSchedule,
} from '../../api'
import { loadSpawnProvider } from '../../preferences'
import type { TeamMember } from '../../api'
import type {
  NodeAssignment,
  NodeContractExternalInput,
  NodeStateSnapshot,
  PlanProposal,
  PlannerAccess,
  PlannerArtifact,
  PlannerDispatchRunner,
  PlannerGraphState,
  PlanningNode,
  PlanningNodeStatus,
  Widget,
  WidgetKind,
  WidgetSourceKind,
} from '../../types'
import { InputCardSections } from './InputCardSections'
import { InspectorArtifactBody } from './InspectorArtifactBody'
import { deriveDisplayStatus } from './labels'
import { visibleOutputReferences, type IOArtifactVisibility } from './plannerGraphAdapter'

interface Props {
  node: PlanningNode
  canvasId: string
  variant?: 'board' | 'template'
  state: NodeStateSnapshot | null
  artifacts?: PlannerArtifact[]
  /** PR #91 codex P2: artifact id to preselect when opening at a non-latest version. */
  initialSelectedArtifactId?: string | null
  doerLabel?: string
  access?: PlannerAccess | null
  teamMembers?: TeamMember[]
  onClose: () => void
  onOpenSubCanvas?: (canvasId: string) => void
  onProposalCreated?: (proposal: PlanProposal) => void
  onGraphStateChanged?: (state: PlannerGraphState) => void
  onSendToAI?: (message: string, display?: { visibleText?: string; contextLabel?: string }) => void
  onReplaceSession?: (nodeId: string, runner: PlannerDispatchRunner) => void
  /** UI-simplification — open the bound session(replaces the「Open session」 button
   *  that used to live on the node card). Surfaced as a hover-revealed link on
   *  the 进展 group label so it's reachable without cluttering canvas. */
  onOpenSession?: (sessionId: string, nodeId: string) => void
  showOwnerInfo?: boolean
  visibleIOArtifacts?: IOArtifactVisibility
  onToggleIOArtifact?: (
    nodeId: string,
    direction: keyof IOArtifactVisibility,
    item: string,
    visible: boolean,
  ) => void
  /** UI-4: open the Attach Data Source popover for this node. */
  onAttachDataSource?: (nodeId: string) => void
  /** UI-4: refresh-now per external row. */
  onRefreshExternalInput?: (nodeId: string, external: NodeContractExternalInput) => void
  /** UI-4: configure dialogue retention. */
  onConfigureDialogue?: (nodeId: string) => void
  /** UI-simplification §2.6 — re-run / mark-down moved here from card footer.
   *  Inspector renders them as secondary actions inside「进展」 instead of
   *  competing with primary action on the card. */
  onRerunNode?: (nodeId: string, reference?: string) => void
  onChangeStatus?: (nodeId: string, status: PlanningNodeStatus) => void
  canChangeStatus?: boolean
  /**
   * AS-3 (team-canvas-sharing) — the active assignment handed out for this
   * node, if any. When present the inspector shows a "撤回指派" control instead
   * of treating the node as locally editable; revoking returns the node to the
   * parent owner. `null`/absent ⇒ the node is not assigned.
   */
  assignment?: NodeAssignment | null
  /**
   * AS-3 — execute the reverse-assign (DELETE assignment). Resolves once the
   * server has revoked + re-bound sessions; the caller reloads the graph so the
   * node stops rendering as a sub-canvas reference chip. Absent ⇒ revoke is not
   * available (e.g. template variant or non-owner).
   */
  onRevokeAssignment?: (nodeId: string) => Promise<unknown>
}

export function NodeInspectorModal({
  node,
  canvasId,
  variant = 'board',
  state,
  artifacts = [],
  initialSelectedArtifactId = null,
  doerLabel,
  access = null,
  teamMembers = [],
  onClose,
  onOpenSubCanvas,
  onProposalCreated,
  onGraphStateChanged,
  onSendToAI,
  onReplaceSession,
  onOpenSession,
  showOwnerInfo = true,
  visibleIOArtifacts = { inputs: [], outputs: [] },
  onToggleIOArtifact,
  onAttachDataSource,
  onRefreshExternalInput,
  onConfigureDialogue,
  onRerunNode,
  onChangeStatus,
  canChangeStatus = false,
  assignment = null,
  onRevokeAssignment,
}: Props) {
  const [assignOpen, setAssignOpen] = useState(false)
  const [scheduleOpen, setScheduleOpen] = useState(false)
  const [replaceConfirmOpen, setReplaceConfirmOpen] = useState(false)
  // AS-3 — reverse-assign confirm + in-flight state, scoped to this node.
  const [revokeConfirmOpen, setRevokeConfirmOpen] = useState(false)
  const [revokeBusy, setRevokeBusy] = useState(false)
  // UI-simplification chunk G — Schedule / Replace session / Assign owner
  // 都属于 advanced action,默认折叠;首次打开 inspector 只显示「Expand sub-canvas」。
  const [advancedOpen, setAdvancedOpen] = useState(false)
  const [scheduleInterval, setScheduleInterval] = useState(() => String(Math.max(1, Math.round((node.schedule?.intervalSeconds ?? 900) / 60))))
  const [schedulePrompt, setSchedulePrompt] = useState(() => node.schedule?.prompt ?? defaultSchedulePrompt(node))
  const [actionBusy, setActionBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)
  // P2.6 v2 — 节点视图选择(chip 行,auto-save)。
  // 简化前的 source/mapping/advanced state 已全删,只剩 draft + saving + error。
  const [widgetDraft, setWidgetDraft] = useState<Widget | null>(node.widget ?? null)
  const [widgetSaving, setWidgetSaving] = useState(false)
  const [widgetError, setWidgetError] = useState<string | null>(null)
  // UI-simplification §2.9 — 视图选择从 inspector 主线降级为 成果·剪贴板
  // group-label 旁的 ⚙ inline popover,默认收起。跟 node-widget-concepts.md
  // 的 v0.1 minimal surface(智能默认 + hint + 不暴露 source/mapping)对齐。
  const [widgetPopoverOpen, setWidgetPopoverOpen] = useState(false)
  const widgetPopoverRef = useRef<HTMLDivElement | null>(null)
  useEffect(() => {
    if (!widgetPopoverOpen) return
    const onMouseDown = (event: MouseEvent) => {
      const node = widgetPopoverRef.current
      if (!node) return
      if (event.target instanceof Node && node.contains(event.target)) return
      setWidgetPopoverOpen(false)
    }
    document.addEventListener('mousedown', onMouseDown)
    return () => document.removeEventListener('mousedown', onMouseDown)
  }, [widgetPopoverOpen])
  const isTemplate = variant === 'template'
  const nodeKind = node.nodeKind ?? (node.source === 'session' ? 'session' : node.subCanvasId ? 'subCanvas' : 'step')
  // PR1 (running-session-visual) — inspector 头部 / 进展段徽章统一从 deriveDisplayStatus 派生,
  // 让 workflowRunState (running / awaiting / failed) 在 inspector 里也显式可见。
  // 不再走 state.runState → runStateToBadge,这条路径只能反映 design status,
  // running / awaiting 都会被吃成「待办」。
  const displayStatus = deriveDisplayStatus(node)
  const blockers = isTemplate
    ? []
    : state?.blockers?.length
      ? state.blockers
      : node.status === 'blocked' && node.blockedReason?.trim()
        ? [node.blockedReason.trim()]
        : []
  // UI-4: the legacy `schema.inputs` slot list + per-input binding editor
  // were removed. Inputs are now rendered through the three-section card
  // (Upstream / External / Dialogue). Outputs continue to use SchemaList.
  // Output slots reconciled with produced artifacts: a concrete artifact
  // fills its templated slot (the `<slug>` template stops showing alongside
  // it), superseded artifacts and the synthetic `…/output` handle are dropped.
  // `state.artifactRefs` carries state-time outputs (e.g. `subcanvas:<id>`)
  // that are not persisted on the node — pass them as runtime refs.
  const outputItems = dedupeStrings(
    visibleOutputReferences(node, artifacts, state?.artifactRefs ?? []),
  )
  const nextAction = node.nextAction?.trim() || null
  const responsibleId = node.doerId?.trim() ?? ''
  const responsibleMember = teamMembers.find((member) => member.userId === responsibleId)
  const responsibleFallback = (doerLabel ?? node.doerId).trim()
  const responsibleLabel = (responsibleMember?.displayName ?? responsibleFallback) || 'Unassigned'
  const role = access?.role ?? 'owner'
  const canAssignOwner = role === 'owner'
  const canShowIOArtifactSwitches = nodeKind === 'step'
  const canUseStepActions = nodeKind === 'step'
  const permissionTooltip = canAssignOwner ? undefined : '只有画板负责人可以指派这个节点。'
  const scheduleEnabled = node.schedule?.enabled === true
  const scheduleNextRun = formatScheduleDate(node.schedule?.nextRunAt)

  // UI-simplification §2.6 — 进展 段次级动作。
  // Re-run / mark-down 从节点卡片 footer 搬过来,不再跟 primary action 抢注意力。
  // 用最新 artifact 的 reference 喂 /rerun。eligibility 镜像原卡片逻辑。
  const latestArtifactForVersionSlot = artifacts.length === 0
    ? undefined
    : [...artifacts].sort((a, b) => {
        const ta = Date.parse(String(a.createdAt))
        const tb = Date.parse(String(b.createdAt))
        return (Number.isFinite(tb) ? tb : 0) - (Number.isFinite(ta) ? ta : 0)
      })[0]
  const reRunEligible = nodeKind === 'step'
    && !isTemplate
    && Boolean(onRerunNode)
    && node.status === 'done'
  const markDownEligible = nodeKind === 'step'
    && !isTemplate
    && Boolean(onChangeStatus)
    && node.status !== 'blocked'
    && canChangeStatus

  const runProposalAction = (work: () => Promise<PlanProposal | null>) => {
    setActionBusy(true)
    setActionError(null)
    work()
      .then((proposal) => {
        setActionBusy(false)
        if (!proposal) {
          setActionError('这次操作没生成提议,稍后再试')
          return
        }
        onProposalCreated?.(proposal)
        onClose()
      })
      .catch((err) => {
        setActionBusy(false)
        setActionError((err as Error).message || '操作失败')
      })
  }

  // AS-3 — revoke the active assignment on this node (reverse-assign). On
  // success we close the inspector; PlannerGraph reloads the graph so the node
  // stops rendering as a sub-canvas ref chip and becomes owner-editable again.
  const canRevokeAssignment = canAssignOwner && !!assignment && !!onRevokeAssignment && !isTemplate
  const runRevokeAssignment = () => {
    if (!onRevokeAssignment) return
    setRevokeBusy(true)
    setActionError(null)
    onRevokeAssignment(node.id)
      .then(() => {
        setRevokeBusy(false)
        setRevokeConfirmOpen(false)
        onClose()
      })
      .catch((err) => {
        setRevokeBusy(false)
        setActionError((err as Error).message || '撤回指派失败')
      })
  }

  const sendNodeActionToAI = (operation: 'expand-sub-canvas') => {
    onSendToAI?.(buildNodeActionPrompt(node, operation), {
      visibleText: 'Expand this node into a sub-canvas with me.',
      contextLabel: `Node: ${node.title}`,
    })
    onClose()
  }

  // P2.6 v2 — 用户面板的 chip 标签全用中文。standard = 无 widget 标准节点。
  const widgetKindOptions: ReadonlyArray<{ kind: WidgetKind | 'standard'; label: string }> = [
    { kind: 'standard', label: '标准' },
    { kind: 'kanban', label: '看板' },
    { kind: 'inbox', label: '收件箱' },
    { kind: 'matrix', label: '矩阵' },
    { kind: 'badge', label: '徽章' },
    { kind: 'artifact-preview', label: '产物预览' },
  ]
  const WIDGET_CHIP_TOOLTIPS: Record<WidgetKind | 'standard', string> = {
    standard: '不渲染 widget,显示节点本身(标题 / 负责人 / 状态)',
    kanban: '把上游数据 / 子画板 / integration 列表按 status 分成 5 列',
    inbox: '把数据扁平展开,按最近活动倒序',
    matrix: '二维网格(默认 owner × status),适合团队总览',
    badge: '紧凑徽章,一行显示单一状态(适合 gate / health-check 节点)',
    'artifact-preview': '内嵌预览(markdown / diff / 文件),适合 PRD / PR / 报告',
  }
  // P2.12 — chip 可用性判断:节点要有「可聚合的数据前提」才允许选对应 widget。
  //   standard / badge:永远可用
  //   kanban / inbox / matrix:需要 subCanvas / upstream / artifact-kind 三者之一
  //   artifact-preview:需要 upstream / artifact-kind 之一
  // disabled chip 鼠标移上去会显示「怎么解锁」的提示。
  const hasSubcanvas = Boolean(node.subCanvasId)
  const hasUpstream = (node.dependsOnNodeIds?.length ?? 0) > 0
  const isArtifactKind = node.nodeKind === 'artifact'
  const collectionUnlockHint = '这个节点还没有可聚合的数据 — 先挂一个子画板,或给它加一个上游节点,看板/收件箱/矩阵就能用了'
  const previewUnlockHint = '这个节点还没有可预览的内容 — 给它加一个上游节点(产物会被预览出来)'
  const widgetChipAvailable = (kind: WidgetKind | 'standard'): { ok: boolean; reason?: string } => {
    if (kind === 'standard' || kind === 'badge') return { ok: true }
    if (kind === 'artifact-preview') {
      if (hasUpstream || isArtifactKind) return { ok: true }
      return { ok: false, reason: previewUnlockHint }
    }
    // kanban / inbox / matrix
    if (hasSubcanvas || hasUpstream || isArtifactKind) return { ok: true }
    return { ok: false, reason: collectionUnlockHint }
  }
  const handlePickWidgetKind = (kind: WidgetKind | 'standard') => {
    setWidgetError(null)
    const avail = widgetChipAvailable(kind)
    if (!avail.ok) {
      // Defensive — UI 也会 disable 这个 chip,这里再兜一层。
      setWidgetError(avail.reason ?? '该 widget 不可用')
      return
    }
    let next: Widget | null
    if (kind === 'standard') {
      next = null
    } else {
      next = {
        kind,
        // 智能默认 source:按 (nodeKind, widget.kind) + 节点上下文(subCanvasId /
        // dependsOnNodeIds)选最有用的来源。用户已有 source 时保留(切 widget
        // 类型时不重置),否则按 inferDefaultWidgetSource 推。
        source: widgetDraft?.source ?? inferDefaultWidgetSource(kind, node),
        mapping: widgetDraft?.mapping,
      }
    }
    setWidgetDraft(next)
    // Auto-save: 用户点 chip 就立即 commit,不需要 save 按钮。
    saveWidgetWith(next)
  }
  const saveWidgetWith = (target: Widget | null) => {
    setWidgetSaving(true)
    setWidgetError(null)
    proposePlannerGraphChange(canvasId, {
      summary: target
        ? `Set widget to ${target.kind} on ${node.title}`
        : `Clear widget on ${node.title}`,
      changes: [{ kind: 'updateNode', nodeId: node.id, widget: target }],
    })
      .then((proposal) => {
        setWidgetSaving(false)
        if (!proposal) {
          setWidgetError('服务端没返回提议')
          return
        }
        // Auto-save 不关 modal —— 用户继续 inspector 内别的操作。
        onProposalCreated?.(proposal)
      })
      .catch((err) => {
        setWidgetSaving(false)
        setWidgetError((err as Error).message || '保存失败')
      })
  }

  const saveSchedule = (enabled: boolean) => {
    const minutes = Math.max(1, Number.parseInt(scheduleInterval, 10) || 15)
    setActionBusy(true)
    setActionError(null)
    updatePlannerNodeSchedule(canvasId, node.id, {
      enabled,
      intervalSeconds: minutes * 60,
      prompt: schedulePrompt.trim(),
    })
      .then((state) => {
        setActionBusy(false)
        onGraphStateChanged?.(state)
        if (!enabled) setScheduleOpen(false)
      })
      .catch((err) => {
        setActionBusy(false)
        setActionError((err as Error).message || '定时没保存成功')
      })
  }

  // UI-simplification — artifact-mode Inspector 早分支:
  //   nodeKind === 'artifact' 时,body 走 InspectorArtifactBody,与 step / session /
  //   subCanvas 路径完全隔离。Modal shell(backdrop / close 按钮)继续复用。
  //   step 路径零改动 — 回归风险锁在 artifact 分支内。
  if (nodeKind === 'artifact') {
    return (
      <div
        className="planner-node-modal-backdrop"
        onMouseDown={(event) => {
          if (event.target === event.currentTarget) onClose()
        }}
      >
        <div className="planner-node-modal planner-node-modal--info" role="dialog" aria-modal="true" aria-label="Node info">
          <button type="button" className="planner-node-modal__close" onClick={onClose} aria-label="Close node details">
            <X size={15} aria-hidden />
          </button>
          <InspectorArtifactBody
            node={node}
            canvasId={canvasId}
            variant={variant}
            state={state}
            artifacts={artifacts}
            initialSelectedArtifactId={initialSelectedArtifactId}
            onClose={onClose}
            onProposalCreated={onProposalCreated}
            onOpenSession={onOpenSession}
            onRerunNode={onRerunNode}
            onAttachDataSource={onAttachDataSource}
            onRefreshExternalInput={onRefreshExternalInput}
          />
        </div>
      </div>
    )
  }

  return (
    <div
      className="planner-node-modal-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <div className="planner-node-modal planner-node-modal--info" role="dialog" aria-modal="true" aria-label="Node info">
        <button type="button" className="planner-node-modal__close" onClick={onClose} aria-label="Close node details">
          <X size={15} aria-hidden />
        </button>

        <div className="planner-node-modal__header">
          <div className="planner-node-modal__header-tags">
            {!isTemplate && <span className={`planner-node-modal__state planner-node-modal__state--${displayStatus.tone}`}>{displayStatus.label}</span>}
          </div>
          <h2>{node.title}</h2>
          {/* PR1 (running-session-visual): the「legacy session」 UI nag was removed.
           *  Deprecation is still enforced inside PlannerCore.addNode validator,
           *  so the canvas can't seed new session-kind nodes; existing nodes
           *  remain editable without a permanent banner cluttering the header. */}
        </div>

        {/* UI-simplification §2.9 — three-section reorg: 进展 / 成果 / 足迹.
         *  Each section gets a semantic group label so the inspector reads as
         *  one progressive story (where am I / what came out / how did I get
         *  here).
         *
         *  Group 1 · 进展(progress): blockers + status + next-action +
         *    secondary 重跑/标记 actions.
         *  Group 2 · 成果·剪贴板(output): inputs + output schema. 视图选择
         *    降级为 group-label 右侧 ⚙ inline popover(默认收起,跟
         *    node-widget-concepts.md「v0.1 minimal surface」对齐)。
         *  Group 3 · 足迹(footprint): version timeline + activity log
         *    placeholder + 子画板入口(phase B 灌真实数据)。 */}

        <div className="planner-node-modal__group-label planner-node-modal__group-label--progress">
          <span>进展</span>
          {/* UI-simplification — 「Open session」 hover-revealed shortcut here,
           *  replaces the canvas card button per user spec. Only shown when a
           *  session is bound;按钮在 group label hover 时淡入。 */}
          {node.sessionId && onOpenSession && (
            <button
              type="button"
              className="planner-node-modal__open-session"
              onClick={(e) => {
                e.stopPropagation()
                onOpenSession(node.sessionId!, node.id)
              }}
            >
              → 打开进展
            </button>
          )}
        </div>

        {/* UI-simplification — 进展 段精简:
         *  - blockers 保留(stuck 提醒优先级最高)
         *  - 原 5-tile info grid(Status/Owner/Gate/Schedule/Type)→ 单 Status tile,
         *    其他维度都在节点卡片 header / mode badge / owner chip 已展示
         *  - next-action 从下面独立块移上来,跟 status 一起在 进展 段
         *  - AI callout 保留(是个核心动作,但 padding 收紧)*/}
        {blockers.length > 0 && (
          <div className="planner-node-modal__blockers">
            {blockers.map((blocker) => (
              <span key={blocker}><AlertTriangle size={12} aria-hidden />{blocker}</span>
            ))}
          </div>
        )}

        {!isTemplate && (
          <div className="planner-node-modal__progress-line">
            <span className={`planner-node-modal__state planner-node-modal__state--${displayStatus.tone}`}>
              {displayStatus.label}
            </span>
            {nextAction && (
              <span className="planner-node-modal__progress-next">
                <Signpost size={11} aria-hidden /> {nextAction}
              </span>
            )}
          </div>
        )}

        {/* 2026-05-29: Inspector 进展段补 runtime 信息 — workflowRunState 中文 +
            spawn / 请回复 / 打开会话 入口。用户反馈:卡片 Attention 显示但
            Inspector 进展段完全空,看不出节点为什么 attention。 */}
        {!isTemplate && (nodeKind === 'step' || nodeKind === 'session') && (
          <div className="planner-node-modal__progress-runtime">
            {(() => {
              const wfs = node.workflowRunState
              const hasSession = Boolean(node.sessionId?.trim())
              const isAwaiting = wfs === 'awaiting-input' || wfs === 'gate-wait'
              const isRunning = wfs === 'running' || wfs === 'dispatched'
              const isFailed = wfs === 'failed'
              const isDone = wfs === 'done'
              const wfsLabel =
                wfs === 'awaiting-input' ? '等反馈'
                : wfs === 'gate-wait' ? '等审核'
                : wfs === 'running' ? '运行中'
                : wfs === 'dispatched' ? '排队中'
                : wfs === 'ready_to_start' ? '已就绪 · 待启动'
                : wfs === 'pending' ? '等待开始'
                : wfs === 'done' ? '已完成'
                : wfs === 'failed' ? '失败,需改方案'
                : null
              return (
                <>
                  {wfsLabel && (
                    <div
                      className={
                        'planner-node-modal__progress-runtime-state '
                        + (isAwaiting ? 'is-awaiting' : isRunning ? 'is-running' : isFailed ? 'is-failed' : isDone ? 'is-done' : '')
                      }
                    >
                      <span className="planner-node-modal__progress-runtime-dot" aria-hidden />
                      <strong>{wfsLabel}</strong>
                      {hasSession && (
                        <span className="planner-node-modal__progress-runtime-session">
                          已绑定会话 <code>{node.sessionId!.slice(0, 8)}…</code>
                        </span>
                      )}
                    </div>
                  )}
                  {/* 动作按钮 */}
                  {hasSession && isAwaiting && onOpenSession && (
                    <button
                      type="button"
                      className="planner-node-modal__progress-runtime-action is-primary is-attention"
                      onClick={() => onOpenSession(node.sessionId!, node.id)}
                      title="会话在等你的回复 — 点击跳到会话窗口"
                    >
                      <AlertTriangle size={12} aria-hidden /> 请回复会话
                    </button>
                  )}
                  {hasSession && isRunning && onOpenSession && (
                    <button
                      type="button"
                      className="planner-node-modal__progress-runtime-action"
                      onClick={() => onOpenSession(node.sessionId!, node.id)}
                    >
                      → 打开会话查看进展
                    </button>
                  )}
                  {!hasSession && node.status === 'ready' && canChangeStatus && onReplaceSession && (
                    <button
                      type="button"
                      className="planner-node-modal__progress-runtime-action is-primary"
                      // codex review fix: dispatch via dispatchRunnerForNode
                      // (honors executorType + loadSpawnProvider fallback for
                      // human/mock/cursor/openClaw), matches the card "开干"
                      // path. Hard-coding claude/codex broke users who picked
                      // a non-Anthropic default spawn provider.
                      onClick={() => onReplaceSession?.(node.id, dispatchRunnerForNode(node.executorType))}
                      title="给这个节点起一个 AI 会话"
                    >
                      <Sparkles size={12} aria-hidden /> 开干 · 起会话
                    </button>
                  )}
                  {isFailed && (
                    <p className="planner-node-modal__progress-runtime-hint">
                      上一次跑出错了。可以从「换一次进展」重启,或先看一眼会话日志再决定。
                    </p>
                  )}
                </>
              )
            })()}
          </div>
        )}

        {/* UI-simplification §2.6 — 进展 段次级动作:重跑 / 标记需要关注。
         *  从节点卡片 footer 搬过来,inspector 才是这些动作的归宿。 */}
        {(reRunEligible || markDownEligible) && (
          <div className="planner-node-modal__progress-actions">
            {reRunEligible && (
              <button
                type="button"
                className="planner-node-modal__progress-action"
                title="为该节点新建一个版本(走 desktop /rerun)"
                onClick={() => {
                  onRerunNode?.(node.id, latestArtifactForVersionSlot?.reference)
                }}
              >
                <RefreshCw size={12} aria-hidden /> 重跑此节点
              </button>
            )}
            {markDownEligible && (
              <button
                type="button"
                className="planner-node-modal__progress-action"
                title="把节点状态置为 blocked,等人来处理"
                onClick={() => {
                  onChangeStatus?.(node.id, 'blocked')
                }}
              >
                <Flag size={12} aria-hidden /> 标记需要关注
              </button>
            )}
          </div>
        )}

        <div className="planner-node-modal__group-label" ref={widgetPopoverRef}>
          <span>成果 · 剪贴板</span>
          <small>成果 · 入参 / 出参 / 版本</small>
          {/* UI-simplification §2.9 — 视图当前摘要(read-only,无需展开 popover
           *  就能看到当前视图是什么)+ ⚙ 展开 inline popover 调视图。 */}
          <span className="planner-node-modal__widget-summary">
            {describeWidget(widgetDraft, node)}
          </span>
          <button
            type="button"
            className={`planner-node-modal__widget-toggle${widgetPopoverOpen ? ' is-open' : ''}`}
            onClick={(event) => {
              event.stopPropagation()
              setWidgetPopoverOpen((open) => !open)
            }}
            aria-expanded={widgetPopoverOpen}
            aria-label="调整视图"
            title="调整视图"
          >
            <Settings2 size={12} aria-hidden />
          </button>
          {widgetPopoverOpen && (
            <div className="planner-node-modal__widget-popover" role="dialog" aria-label="视图设置">
              <div className="planner-node-modal__widget-popover-header">
                <Eye size={12} aria-hidden /> 视图
                {widgetSaving && <em className="planner-node-modal__view-saving">保存中…</em>}
                {widgetError && <em className="planner-node-modal__view-error" title={widgetError}>!</em>}
              </div>
              <div className="planner-node-modal__widget-kind-chips">
                {widgetKindOptions.map((option) => {
                  const selected = option.kind === 'standard'
                    ? widgetDraft == null
                    : widgetDraft?.kind === option.kind
                  const avail = widgetChipAvailable(option.kind)
                  const tooltip = avail.ok
                    ? WIDGET_CHIP_TOOLTIPS[option.kind]
                    : `${WIDGET_CHIP_TOOLTIPS[option.kind]}\n\n— 当前不可用 —\n${avail.reason ?? ''}`
                  return (
                    <button
                      key={option.kind}
                      type="button"
                      className={`planner-node-modal__widget-kind-chip${selected ? ' is-selected' : ''}${avail.ok ? '' : ' is-disabled'}`}
                      disabled={widgetSaving || !avail.ok}
                      onClick={() => handlePickWidgetKind(option.kind)}
                      title={tooltip}
                    >
                      {option.label}
                    </button>
                  )
                })}
              </div>
              <div className="planner-node-modal__view-hint">
                {describeWidget(widgetDraft, node)}
              </div>
            </div>
          )}
        </div>

        {/* PR3 — step / session 节点的 入参 / 出参 段从 inspector 移除。
         *  这些节点的「产出」由卡片上 [查看输出] 按钮 + 足迹段处理;
         *  入参声明属于 schema 内部,不该作为用户主编辑面。
         *  其他 nodeKind(subCanvas / external)继续渲染,artifact 走早分支不到这里。*/}
        {nodeKind !== 'step' && nodeKind !== 'session' && (
          <>
            <div className="planner-node-modal__section">
              <h3><Route size={13} aria-hidden /> 入参</h3>
              <InputCardSections
                node={node}
                variant="modal"
                onAttachDataSource={onAttachDataSource}
                onRefreshExternal={onRefreshExternalInput}
              />
            </div>

            <div className="planner-node-modal__section">
              <h3><Route size={13} aria-hidden /> 出参</h3>
              <div className="planner-node-modal__schema">
                <SchemaList
                  title="出参"
                  items={outputItems}
                  empty="这个节点暂时没有产出"
                  visibleItems={visibleIOArtifacts.outputs}
                  switchesEnabled={canShowIOArtifactSwitches}
                  onToggle={(item, visible) => onToggleIOArtifact?.(node.id, 'outputs', item, visible)}
                />
                {/* UI-simplification — 「Do what」 wide row 移除,信息已在节点 title/desc 体现;
                 *  next-action 也不再独立块,已并入 进展 段(.planner-node-modal__progress-line)。 */}
              </div>
            </div>
          </>
        )}

        {/* P2.6 v3 (2026-05-28 P2.11) — 节点视图选择 已降级为 成果·剪贴板
         *  group-label 旁的 ⚙ inline popover(见上方),默认收起,跟
         *  node-widget-concepts.md 的「v0.1 minimal surface」对齐。 */}

        {canUseStepActions && (
          <div className="planner-node-modal__section">
            <h3><Sparkles size={13} aria-hidden /> 动作</h3>
            {/* UI-simplification inspector-actions-4-buttons — 4 个平铺动作:
             *  展开为子画板 / 指派 / 定时 / 重新发起。advancedOpen 状态保留给
             *  「换一次进展」(replace-session,语义不同 — 会断开当前进展,留高级折叠区)。 */}
            <div className="planner-node-actions__buttons">
              <button
                type="button"
                disabled={actionBusy}
                onClick={() => sendNodeActionToAI('expand-sub-canvas')}
              >
                <Layers size={12} aria-hidden /> 展开为子画板
              </button>
              {showOwnerInfo && (
                <button
                  type="button"
                  disabled={actionBusy || !canAssignOwner}
                  title={permissionTooltip}
                  onClick={() => {
                    setActionError(null)
                    setAssignOpen((value) => !value)
                  }}
                >
                  <UserRound size={12} aria-hidden /> 指派
                </button>
              )}
              {canRevokeAssignment && (
                <button
                  type="button"
                  className="planner-node-actions__danger"
                  disabled={actionBusy || revokeBusy}
                  title="撤回指派,把这个子画板收回到本画板(对方将失去编辑权)"
                  onClick={() => {
                    setActionError(null)
                    setRevokeConfirmOpen((value) => !value)
                  }}
                >
                  <Undo2 size={12} aria-hidden /> 撤回指派
                </button>
              )}
              <button
                type="button"
                disabled={actionBusy || !node.sessionId}
                title={node.sessionId ? undefined : '要先给节点接一个进展,才能设定定时'}
                onClick={() => {
                  setActionError(null)
                  setScheduleOpen((value) => !value)
                }}
              >
                <CalendarClock size={12} aria-hidden /> 定时
              </button>
              <button
                type="button"
                disabled={actionBusy || !onRerunNode}
                title="为该节点新建一个版本(走 desktop /rerun)"
                onClick={() => {
                  onRerunNode?.(node.id, latestArtifactForVersionSlot?.reference)
                }}
              >
                <RefreshCw size={12} aria-hidden /> 重新发起
              </button>
              {/* 「换一次进展」 留在高级折叠区(replace-session 会断开当前进展)。 */}
              {node.sessionId && onReplaceSession && (
                <>
                  <button
                    type="button"
                    className="planner-node-actions__advanced-toggle"
                    onClick={() => setAdvancedOpen((v) => !v)}
                    aria-expanded={advancedOpen}
                  >
                    高级 {advancedOpen ? '▴' : '▾'}
                  </button>
                  {advancedOpen && (
                    <button
                      type="button"
                      className="planner-node-actions__danger"
                      disabled={actionBusy}
                      onClick={() => {
                        setActionError(null)
                        setReplaceConfirmOpen((value) => !value)
                      }}
                    >
                      <RefreshCw size={12} aria-hidden /> 换一次进展
                    </button>
                  )}
                </>
              )}
            </div>
            {advancedOpen && replaceConfirmOpen && node.sessionId && (
              <div className="planner-node-actions__panel planner-node-actions__panel--danger">
                <div className="planner-node-actions__warning">
                  <AlertTriangle size={14} aria-hidden />
                  <div>
                    <strong>换一次进展?</strong>
                    <p>换了之后当前的进展会断开,节点会重新开一次。如果还要回看旧进展,先别换。</p>
                  </div>
                </div>
                <div className="planner-node-modal__input-editor-actions">
                  <button type="button" disabled={actionBusy} onClick={() => setReplaceConfirmOpen(false)}>
                    取消
                  </button>
                  <button
                    type="button"
                    className="primary danger"
                    disabled={actionBusy}
                    onClick={() => {
                      onReplaceSession?.(node.id, dispatchRunnerForNode(node.executorType))
                      onClose()
                    }}
                  >
                    换一次进展
                  </button>
                </div>
              </div>
            )}
            {scheduleOpen && (
              <div className="planner-node-actions__panel planner-node-actions__panel--schedule">
                <label>
                  <span>每</span>
                  <input
                    type="number"
                    min={1}
                    max={1440}
                    value={scheduleInterval}
                    disabled={actionBusy}
                    onChange={(event) => setScheduleInterval(event.target.value)}
                  />
                  <em>分钟</em>
                </label>
                <textarea
                  value={schedulePrompt}
                  disabled={actionBusy}
                  rows={5}
                  onChange={(event) => setSchedulePrompt(event.target.value)}
                />
                {scheduleEnabled && scheduleNextRun && (
                  <p className="planner-node-actions__schedule-note">下次触发:{scheduleNextRun}</p>
                )}
                <div className="planner-node-modal__input-editor-actions">
                  {scheduleEnabled && (
                    <button type="button" disabled={actionBusy} onClick={() => saveSchedule(false)}>
                      关掉定时
                    </button>
                  )}
                  <button
                    type="button"
                    className="primary"
                    disabled={actionBusy || schedulePrompt.trim().length === 0}
                    onClick={() => saveSchedule(true)}
                  >
                    {scheduleEnabled ? '保存定时' : '打开定时'}
                  </button>
                </div>
              </div>
            )}
            {canRevokeAssignment && revokeConfirmOpen && assignment && (
              <div className="planner-node-actions__panel planner-node-actions__panel--danger">
                <div className="planner-node-actions__warning">
                  <AlertTriangle size={14} aria-hidden />
                  <div>
                    <strong>撤回指派?</strong>
                    <p>
                      子画板「{assignment.subCanvasName}」会收回到本画板,
                      {assignment.assigneeUserId ? '对方' : '受指派人'}将失去对它的编辑权,
                      迁过去的进展会重新绑回这个节点。这一步可逆 — 之后还能再指派。
                    </p>
                  </div>
                </div>
                <div className="planner-node-modal__input-editor-actions">
                  <button type="button" disabled={revokeBusy} onClick={() => setRevokeConfirmOpen(false)}>
                    取消
                  </button>
                  <button
                    type="button"
                    className="primary danger"
                    disabled={revokeBusy}
                    onClick={runRevokeAssignment}
                  >
                    {revokeBusy ? '撤回中…' : '撤回指派'}
                  </button>
                </div>
              </div>
            )}
            {showOwnerInfo && assignOpen && (
              <div className="planner-node-actions__panel">
                {teamMembers.length === 0 ? (
                  <p className="planner-node-modal__empty">团队里还没人可以指派</p>
                ) : (
                  <div className="planner-node-actions__members">
                    {teamMembers.map((member) => {
                      const current = member.userId === responsibleId
                      return (
                        <button
                          key={member.userId}
                          type="button"
                          className={`planner-node-actions__member${current ? ' is-current' : ''}`}
                          disabled={actionBusy || current}
                          onClick={() => {
                            runProposalAction(() =>
                              proposePlannerGraphChange(canvasId, {
                                summary: `Assign ${member.displayName} as owner of ${node.title}`,
                                changes: [{ kind: 'updateNode', nodeId: node.id, doerId: member.userId }],
                              }),
                            )
                          }}
                        >
                          <span className="planner-node-modal__avatar" aria-hidden>
                            {member.avatarUrl ? <img src={member.avatarUrl} alt="" /> : <UserRound size={12} />}
                          </span>
                          <span>{member.displayName}</span>
                          {current && <em>当前</em>}
                        </button>
                      )
                    })}
                  </div>
                )}
              </div>
            )}
            {actionError && <p className="planner-node-actions__error">{actionError}</p>}
          </div>
        )}

        {/* UI-simplification §2.9 — 足迹段:三段心智(进展/成果/足迹)落地,
         *  即便先放占位。phase B 灌 artifact version chain + session activity。 */}
        <div className="planner-node-modal__group-label planner-node-modal__group-label--footprint">
          <span>足迹</span>
          <small>footprint · 怎么过来的</small>
        </div>
        <div className="planner-node-modal__section planner-node-modal__footprint">
          {/* TODO §2.9 phase B — version timeline + activity log.
           *  Placeholder so the three-section mental model lands now,
           *  proper timeline ships next iteration. */}
          <p className="planner-node-modal__empty">(暂无足迹 — 版本与活动时间线规划中)</p>
          {node.subCanvasId && (
            <button
              type="button"
              className="planner-node-modal__subcanvas"
              onClick={() => {
                onOpenSubCanvas?.(node.subCanvasId as string)
                onClose()
              }}
            >
              <ExternalLink size={13} aria-hidden /> 打开子画板
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

function InfoTile({ label, value }: { label: string; value: string }) {
  return (
    <div className="planner-node-modal__info-tile">
      <em>{label}</em>
      <strong>{value}</strong>
    </div>
  )
}

// UI-4: SchemaList is now Output-only. The Input axis is rendered via
// `InputCardSections` (Upstream / External / Dialogue). All field-level
// binding props (`inputBindings`, `editingItem`, `onSaveInput`, etc.) were
// removed; ENG-1's contract validator rejects field-level mapping anyway.
function SchemaList({
  title,
  items,
  empty,
  visibleItems = [],
  switchesEnabled = false,
  onToggle,
}: {
  title: string
  items: string[]
  empty: string
  visibleItems?: string[]
  switchesEnabled?: boolean
  onToggle?: (item: string, visible: boolean) => void
}) {
  const normalized = dedupeStrings(items)
  const visibleSet = new Set(visibleItems.map((item) => item.trim()).filter(Boolean))
  return (
    <div className="planner-node-modal__schema-row">
      <span>{title}</span>
      {normalized.length > 0 ? (
        <div className="planner-node-modal__schema-chips">
          {normalized.map((item) => {
            const checked = visibleSet.has(item)
            return (
              <div key={item} className="planner-node-modal__schema-item">
                <div className="planner-node-modal__schema-item-main">
                  <strong title={item}><FileText size={11} aria-hidden />{compactLabel(item)}</strong>
                </div>
                {switchesEnabled && (
                  <button
                    type="button"
                    className={`planner-node-modal__switch${checked ? ' is-on' : ''}`}
                    aria-pressed={checked}
                    aria-label={`${checked ? 'Hide' : 'Show'} ${item} as artifact node`}
                    onClick={() => onToggle?.(item, !checked)}
                  >
                    <span />
                  </button>
                )}
              </div>
            )
          })}
        </div>
      ) : (
        <strong>{empty}</strong>
      )}
    </div>
  )
}

function dedupeStrings(values: Array<string | null | undefined>): string[] {
  const seen = new Set<string>()
  const result: string[] = []
  for (const value of values) {
    const normalized = value?.trim()
    if (!normalized || seen.has(normalized)) continue
    seen.add(normalized)
    result.push(normalized)
  }
  return result
}

function buildNodeActionPrompt(node: PlanningNode, operation: 'expand-sub-canvas'): string {
  const tag = `@node:${node.id}`
  const opTag = `#${operation}`
  const input = (node.schema?.inputs ?? []).join(', ') || 'none'
  const output = (node.schema?.outputs ?? []).join(', ') || 'none'
  const doWhat = node.schema?.goal || node.nextAction || node.title
  return [
    `${tag} ${opTag}`,
    `Node: ${node.title}`,
    `Inputs: ${input}`,
    `Outputs: ${output}`,
    `Do what: ${doWhat}`,
    '',
    'Expand this node into a sub-canvas with me.',
  ].join('\n')
}

function dispatchRunnerForNode(executorType: PlanningNode['executorType']): PlannerDispatchRunner {
  if (executorType === 'codex') return 'codex'
  if (executorType === 'claude') return 'claude'
  return loadSpawnProvider()
}

function defaultSchedulePrompt(node: PlanningNode): string {
  return [
    'Scheduled meee2 planner tick.',
    `Node ID: ${node.id}`,
    `Node: ${node.title}`,
    `Goal: ${node.schema?.goal || node.title}`,
    'Call read_node_contract first. If this tick produces new output, call submit_node_output; if there is nothing to update, reply with a brief status summary.',
  ].join('\n')
}

function formatScheduleDate(value: string | number | null | undefined): string | null {
  if (value == null) return null
  const date = typeof value === 'number' ? new Date(value * 1000) : new Date(value)
  if (Number.isNaN(date.getTime())) return null
  return date.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
}

function compactLabel(value: string): string {
  const withoutQuery = value.trim().split('?')[0]
  const parts = withoutQuery.split(/[/:#]/).filter(Boolean)
  return parts[parts.length - 1]?.trim() || value
}

function gateModeLabel(node: PlanningNode): 'Human' | 'Auto' {
  if (node.executionMode === 'human') return 'Human'
  if ((node.gate?.approvers ?? []).length > 0) return 'Human'
  return 'Auto'
}

/**
 * 智能默认 source(P2.11 设计文档 doc/goals/node-widget-concepts.md 中的「组合默认表」)。
 *
 * 推理规则:
 *   - subCanvas 节点 → 优先 subcanvas-aggregate(把子画板拉成 kanban / inbox / matrix)
 *   - step / session 节点带 subCanvasId → 同上,自然把「子流程展开成 kanban」
 *   - artifact 节点 → 优先 upstream(payload 即数据;artifact-preview 时也是 upstream)
 *   - badge / artifact-preview → 优先 upstream(单状态 / 单文档)
 *   - 都没有 → external,留 integration entity 接入位
 */
function inferDefaultWidgetSource(
  kind: WidgetKind,
  node: PlanningNode,
): { inputKind: 'external' | 'upstream' | 'subcanvas-aggregate'; inputIndex: number; subcanvasIds?: string[] } {
  const hasSubcanvas = Boolean(node.subCanvasId)
  const hasUpstream = (node.dependsOnNodeIds?.length ?? 0) > 0
  const isArtifactKind = node.nodeKind === 'artifact'
  const isCollectionWidget = kind === 'kanban' || kind === 'inbox' || kind === 'matrix'

  if (isCollectionWidget) {
    // 收集型 widget:优先聚合子画板,其次 upstream artifact payload,最后 external
    if (hasSubcanvas) {
      return { inputKind: 'subcanvas-aggregate', inputIndex: 0, subcanvasIds: [node.subCanvasId!] }
    }
    if (isArtifactKind && hasUpstream) {
      return { inputKind: 'upstream', inputIndex: 0 }
    }
    if (isArtifactKind) {
      // artifact 节点本身的 payload 算「upstream」(它产了自己的 artifact)
      return { inputKind: 'upstream', inputIndex: 0 }
    }
    if (hasUpstream) {
      return { inputKind: 'upstream', inputIndex: 0 }
    }
    return { inputKind: 'external', inputIndex: 0 }
  }

  // badge / artifact-preview 是单一目标
  if (hasUpstream) {
    return { inputKind: 'upstream', inputIndex: 0 }
  }
  if (isArtifactKind) {
    return { inputKind: 'upstream', inputIndex: 0 }
  }
  return { inputKind: 'external', inputIndex: 0 }
}

/**
 * 一行中文描述「当前 widget 在呈现什么」(P2.11 hint line)。
 */
function describeWidget(widget: Widget | null, node: PlanningNode): string {
  if (!widget) return '标准 · 显示节点本身(标题 / 负责人 / 状态)'
  const kindLabel: Record<WidgetKind, string> = {
    kanban: '看板',
    inbox: '收件箱',
    matrix: '矩阵',
    badge: '徽章',
    'artifact-preview': '产物预览',
  }
  const label = kindLabel[widget.kind] ?? widget.kind
  const source = widget.source
  if (!source) return `${label} · 还没绑数据源`
  switch (source.inputKind) {
    case 'subcanvas-aggregate': {
      const ids = source.subcanvasIds ?? []
      if (ids.length === 0) return `${label} ← 子画板聚合(子画板待配置)`
      return `${label} ← 聚合 ${ids.length} 个子画板`
    }
    case 'upstream': {
      const upstreamId = node.dependsOnNodeIds?.[source.inputIndex ?? 0]
      if (!upstreamId) {
        return `${label} ← 上游节点 #${source.inputIndex ?? 0}(还没声明依赖)`
      }
      return `${label} ← 上游节点 ${upstreamId.slice(0, 8)} 的 artifact`
    }
    case 'external':
      return `${label} ← 外部数据源 #${source.inputIndex ?? 0}`
    default:
      return label
  }
}

// PR1 (running-session-visual): runStateToBadge moved to deriveDisplayStatus
// in ./labels.ts so card + inspector share a single source of truth. Kept the
// removal here so future readers don't reach for a stale local helper.

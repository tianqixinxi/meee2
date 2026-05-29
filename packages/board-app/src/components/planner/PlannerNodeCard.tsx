import { Handle, Position, type NodeProps } from '@xyflow/react'
import { useEffect, useMemo, useState } from 'react'
import {
  AlertTriangle,
  ArrowUpRight,
  Bot,
  ChevronDown,
  CheckCircle2,
  Clock3,
  Code2,
  FileText,
  History,
  Layers,
  Link2,
  Lock,
  MessageCircle,
  PlayCircle,
  Plug,
  Route,
  Signpost,
  SquareCheckBig,
  Trash2,
  UserPlus,
  UserRound,
} from 'lucide-react'
import type {
  NodeAssignment,
  PlannerArtifactContent,
  PlannerArtifactVersion,
  KanbanArtifactPayload,
  PlannerArtifact,
  PlannerDispatchRunner,
  PlannerWorkflowRunState,
  PlanningNode,
  PlanningNodeKind,
  PlanningNodeStatus,
  RunNextAction,
} from '../../types'
import { loadSpawnProvider, spawnProviderLabel } from '../../preferences'
import { getPlannerArtifactContent, listArtifactVersions } from '../../api'
import type { PlannerGraphNode } from './plannerGraphAdapter'
import { getWidgetComponent } from './widgets'
import { resolveWidgetData } from './widgetDataResolver'
import {
  ARTIFACT_LABELS,
  CARD_TOOLTIPS,
  FOOTER_LABELS,
  modeBadgeLabel,
  modeBadgeTooltip,
  OWNER_CHIP,
  PRIMARY_ACTION_TEXT,
  SUBCANVAS_REF_LABELS,
  nextPlanAction as nextPlanActionCN,
  nextWorkAction as nextWorkActionCN,
  planStatusLabel as planStatusLabelCN,
  primaryActionLabel as primaryActionLabelCN,
  workStatusLabel as workStatusLabelCN,
  type NodeMode,
  type PrimaryAction,
} from './labels'

type CanvasArtifactKind = 'text' | 'integration' | 'html' | 'kanban' | 'json' | 'file'
// 3-tai cut (2026-05-29): collapsed to 3 lifecycle states. `draft` removed —
// `ready` is now the initial state. Legacy `draft` data is mapped to `ready`
// at render time below.
const DESIGN_STATUS_OPTIONS: PlanningNodeStatus[] = ['ready', 'blocked', 'done']

// UI-1 · "auto / gate / human" mode badge — derived from execution mode +
// gate approver count. `human` wins when the node is an explicit human step;
// `gate` when downstream review is required (approvers present or gate mode
// human); otherwise `auto`. Colors mirror the existing border palette.
// 文案在 labels.ts MODE_LABEL,这里只保留 icon 映射。
const MODE_ICON: Record<NodeMode, typeof Bot> = { auto: Bot, gate: Signpost, human: UserRound }

interface CanvasIOItem {
  key: string
  label: string
  reference?: string | null
  artifactKind: CanvasArtifactKind
  pending?: boolean
}

const runStateIcons: Record<PlannerWorkflowRunState, typeof Clock3> = {
  pending: Clock3,
  ready_to_start: PlayCircle,
  dispatched: PlayCircle,
  running: PlayCircle,
  'awaiting-input': MessageCircle,
  'gate-wait': Signpost,
  done: CheckCircle2,
  failed: AlertTriangle,
}

function runStateClass(runState: PlannerWorkflowRunState): string {
  switch (runState) {
    case 'pending':
      return 'ready'
    case 'ready_to_start':
      return 'ready'
    case 'dispatched':
    case 'running':
      return 'working'
    case 'awaiting-input':
    case 'gate-wait':
    case 'failed':
      return 'blocked'
    case 'done':
      return 'done'
  }
}

export function PlannerNodeCard({ data, selected }: NodeProps<PlannerGraphNode>) {
  const [artifactInputDraft, setArtifactInputDraft] = useState(data.inputReference ?? '')
  useEffect(() => {
    setArtifactInputDraft(data.inputReference ?? '')
  }, [data.inputReference])
  const node = data.node
  const [deleteArmed, setDeleteArmed] = useState(false)
  useEffect(() => {
    setDeleteArmed(false)
  }, [node.id])
  useEffect(() => {
    if (!deleteArmed) return undefined
    const timer = window.setTimeout(() => setDeleteArmed(false), 2500)
    return () => window.clearTimeout(timer)
  }, [deleteArmed])
  const virtualArtifact = data.virtual && designKind(data.node) === 'artifact'
  const primaryArtifact = virtualArtifact ? selectPrimaryArtifact(data.artifacts) : undefined
  const renderKind = artifactRenderKind(primaryArtifact, data.artifactKind ?? 'text')
  const [artifactContent, setArtifactContent] = useState<PlannerArtifactContent | null>(null)
  const [artifactContentError, setArtifactContentError] = useState<string | null>(null)
  useEffect(() => {
    setArtifactContent(null)
    setArtifactContentError(null)
    if (!virtualArtifact || !primaryArtifact) return undefined
    let cancelled = false
    getPlannerArtifactContent(primaryArtifact.canvasId, primaryArtifact.id)
      .then((content) => {
        if (!cancelled) setArtifactContent(content)
      })
      .catch((error) => {
        if (cancelled) return
        // ui-simplification §1 — axios 原文(e.g. status code 500)是技术 hint,
        // 不能直接吐给用户。降级到 console.warn → JSConsoleBridge 落到
        // ~/Library/Logs/meee2.log,state 里只放中文文案。
        console.warn('[planner-node] artifact load failed:', error?.message)
        setArtifactContentError(ARTIFACT_LABELS.loadError)
      })
    return () => {
      cancelled = true
    }
  }, [virtualArtifact, primaryArtifact?.canvasId, primaryArtifact?.id])
  const isRunMode = data.mode === 'run'
  const runNodeState = data.runNodeState
  const nodeKind = designKind(node)
  // 3-tai cut (2026-05-29): legacy `draft` data still lives in old canvases —
  // map it to `ready` at render so the UI never surfaces the removed state.
  // Backend normalizer takes care of the wire-level translation; this is the
  // belt-and-braces step for any in-memory state that hasn't been re-saved.
  const rawDesignStatus = data.state?.runState ?? node.status
  const designStatus: PlanningNodeStatus = (rawDesignStatus === 'draft' ? 'ready' : rawDesignStatus) as PlanningNodeStatus
  const runStatus: PlannerWorkflowRunState = runNodeState?.runState ?? 'pending'
  const Icon = isRunMode ? runStateIcons[runStatus] : Route
  // UI-simplification — artifact node 默认收起,仅显示 title + kind + 展开按钮。
  // 强制展开条件:1) 有 subCanvasId(有下钻子画板)2) 用户点了展开按钮。
  const hasSubCanvas = Boolean(node.subCanvasId)
  const [artifactExpanded, setArtifactExpanded] = useState(hasSubCanvas)
  if (data.virtual && nodeKind === 'artifact') {
    const artifact = primaryArtifact
    const inlineKanban = renderKind === 'kanban'
      ? parseKanbanPayload(artifact?.payload) ?? parseKanbanPayload(artifactContent?.payload)
      : null
    const contentKanban = renderKind === 'kanban'
      ? parseMarkdownKanbanPayload(artifactContent?.content)
      : null
    const kanban = renderKind === 'kanban'
      ? (contentKanban && (inlineKanban?.items.length ?? 0) === 0 ? contentKanban : inlineKanban ?? contentKanban ?? (artifact ? emptyKanbanPayload(node.title) : null))
      : null
    return (
      <div
        className={[
          'planner-node',
          'planner-node--artifact-node',
          `planner-node--artifact-${renderKind}`,
          `planner-node--artifact-${data.artifactDirection ?? 'output'}`,
          selected ? 'is-selected' : '',
        ].filter(Boolean).join(' ')}
      >
        <Handle type="target" position={Position.Left} className="planner-node__handle" />
        <div className="planner-node__header">
          <span className="planner-node__status planner-node__status--design">
            <ArtifactIcon kind={renderKind} size={13} />
            {ARTIFACT_LABELS.artifact}
          </span>
          <div className="planner-node__header-actions">
            <span className="planner-node__badge kind kind-artifact">
              {data.artifactDirection === 'input' ? ARTIFACT_LABELS.input : ARTIFACT_LABELS.output}
            </span>
            {data.sourceNodeId && data.ioItem && data.artifactDirection && (
              <button
                type="button"
                className="planner-node__delete nodrag"
                title={ARTIFACT_LABELS.removeFromCanvas}
                aria-label={`${ARTIFACT_LABELS.removeFromCanvas} ${node.title}`}
                onClick={(event) => {
                  event.stopPropagation()
                  data.onHideIOArtifact?.(
                    data.sourceNodeId as string,
                    data.artifactDirection as 'input' | 'output',
                    data.ioItem as string,
                  )
                }}
                onPointerDown={(event) => event.stopPropagation()}
              >
                <Trash2 size={13} aria-hidden />
              </button>
            )}
          </div>
        </div>
        <div className="planner-node__title">{node.title}</div>
        {node.desc && <div className="planner-node__desc">{node.desc}</div>}
        {data.artifactDirection !== 'input' && (
          <div className="planner-node__artifact-ref" title={node.schema?.goal || node.title}>
            {node.schema?.goal || node.title}
          </div>
        )}
        {data.artifactDirection === 'input' && data.sourceNodeId && data.ioItem && (
          <div
            className="planner-node__artifact-input nodrag"
            onClick={(event) => event.stopPropagation()}
            onPointerDown={(event) => event.stopPropagation()}
          >
            <textarea
              value={artifactInputDraft}
              onChange={(event) => setArtifactInputDraft(event.target.value)}
              placeholder={ARTIFACT_LABELS.pastePlaceholder}
              rows={3}
            />
            <button
              type="button"
              className="planner-node__artifact-save"
              disabled={artifactInputDraft.trim().length === 0 || artifactInputDraft.trim() === (data.inputReference ?? '').trim()}
              onClick={() => data.onBindInput?.(data.sourceNodeId as string, data.ioItem as string, artifactInputDraft)}
            >
              {ARTIFACT_LABELS.saveInput}
            </button>
          </div>
        )}
        {/* UI-simplification — artifact 默认收起,只显示 title。
         *  展开条件:(a) 有 subCanvasId(下钻成子画板),自动展开
         *  (b) 用户点 展开 按钮手动展开。
         *  收起态只露一个 [展开 ▼] 按钮,canvas 上视觉占用极小 → 不挤占节点交互区域。 */}
        {artifactExpanded ? (
          <>
            <ArtifactPreview
              artifact={artifact}
              kind={renderKind}
              kanban={kanban}
              content={artifactContent}
              error={artifactContentError}
              onOpenKanbanItem={data.onOpenKanbanItem}
            />
            {!hasSubCanvas && (
              <button
                type="button"
                className="planner-node__artifact-collapse nodrag"
                onClick={(event) => {
                  event.stopPropagation()
                  setArtifactExpanded(false)
                }}
                onPointerDown={(event) => event.stopPropagation()}
                title={CARD_TOOLTIPS.collapseArtifact}
              >
                收起 ▴
              </button>
            )}
          </>
        ) : (
          <button
            type="button"
            className="planner-node__artifact-expand nodrag"
            onClick={(event) => {
              event.stopPropagation()
              setArtifactExpanded(true)
            }}
            onPointerDown={(event) => event.stopPropagation()}
            title={CARD_TOOLTIPS.expandArtifact}
          >
            展开 ▾
          </button>
        )}
        <Handle type="source" position={Position.Right} className="planner-node__handle" />
      </div>
    )
  }
  // UI-2: when this node has been assigned, collapse it to a sub-canvas
  // reference chip. The card stops showing the regular interior (status
  // dropdown, IO grid, primary action) because parent-side editing is no
  // longer authoritative — ENG-4 RLS blocks it server-side anyway.
  if (data.assignment && !data.virtual) {
    return (
      <SubCanvasRefCard
        node={node}
        assignment={data.assignment}
        assigneeLabel={assigneeLabelFromAssignment(data)}
        avatarUrl={data.responsibleAvatarUrl}
        onOpenAssignedSubCanvas={data.onOpenAssignedSubCanvas}
        selected={selected}
      />
    )
  }

  const statusLabel = isRunMode
    ? workStatusLabelCN(runStatus, data.hasSelectedDelivery)
    : planStatusLabelCN(designStatus)
  const borderClass = isRunMode ? runStateClass(runStatus) : designStatus
  const blockers = data.state?.blockers?.length
    ? data.state.blockers
    : node.status === 'blocked' && node.blockedReason?.trim()
      ? [node.blockedReason.trim()]
      : []
  const sessionId = isRunMode
    ? (runNodeState?.sessionId ?? node.sessionId ?? null)
    : node.sessionId?.trim() || null
  const nextAction = isRunMode
    ? nextWorkActionCN(data.hasSelectedDelivery, runNodeState?.nextAction)
    : nextPlanActionCN(Boolean(data.responsibleLabel), Boolean(node.subCanvasId), node.nextAction)
  const monitorItem = data.monitorItem ?? null
  const monitorBadge = monitorItem && monitorItem.reasonKind !== 'normal'
    ? {
      tone: monitorItem.needsHumanReply ? 'reply' : 'attention',
      label: monitorItem.needsHumanReply ? 'Needs reply' : 'Attention',
      title: monitorBadgeTitle(monitorItem),
    }
    : null
  const io = buildCanvasIOItems(data)
  // UI-simplification §1 — primaryAction 现在是结构化枚举(PrimaryAction),
  // dispatch 走 switch(primaryAction);显示文本走 PRIMARY_ACTION_TEXT[primaryAction]。
  // 不再用英文字符串字面量比较,文案改中文后点击不会全掉到 else 分支。
  const primaryAction: PrimaryAction = primaryActionLabelCN({
    mode: data.mode,
    hasSelectedDelivery: data.hasSelectedDelivery,
    runStatus,
    sessionId,
    workflowRunState: node.workflowRunState ?? null,
    responsibleLabel: data.responsibleLabel,
    nodeKind,
    blockers,
    canCreateSession: Boolean(data.canChangeStatus && data.onCreateSession),
    creatingSession: Boolean(data.creatingSession),
  })
  const primaryActionText = primaryAction === 'none' ? '' : PRIMARY_ACTION_TEXT[primaryAction]
  const primaryActionDisabled = primaryAction === 'creating-session'
  const showResponsibleInfo = data.showResponsibleInfo ?? true
  const gateLabel = gateModeLabel(node)
  const scheduleEnabled = node.schedule?.enabled === true
  const scheduleLabel = scheduleEnabled ? scheduleIntervalLabel(node.schedule?.intervalSeconds ?? 0) : null
  // UI-simplification §2.6 — mode badge stays. Re-run / mark-down eligibility
  // has moved to NodeInspectorModal「进展」 so the card footer no longer
  // competes for attention with secondary inspector actions.
  const nodeMode = resolveNodeMode(node)
  const latestArtifactForVersionSlot = pickLatestArtifactForVersions(data.artifacts)

  return (
    <div
      className={[
        'planner-node',
        scheduleEnabled ? 'planner-node--scheduled' : '',
        `planner-node--${borderClass}`,
        `planner-node--kind-${nodeKind}`,
        `planner-node--mode-${data.mode}`,
        `planner-node--perception-${data.perception}`,
        selected ? 'is-selected' : '',
        data.previewKind !== 'none' ? `planner-node--preview-${data.previewKind}` : '',
      ].filter(Boolean).join(' ')}
    >
      <Handle type="target" position={Position.Left} className="planner-node__handle" />

      <div className="planner-node__header">
        {/* nodeKind 视觉分辨 (2026-05-28) — 让用户一眼看出 artifact 是数据 /
            session 是 AI 会话 / step 是动作 / external 是外部引用 / subCanvas
            是子画板。配 CSS .planner-node--kind-* 的边色调一起做完整视觉。 */}
        {!data.virtual && (
          <span
            className="planner-node__kind-tag"
            title={NODE_KIND_LABEL[nodeKind]}
            aria-label={`节点类型 ${NODE_KIND_LABEL[nodeKind]}`}
          >
            <NodeKindIcon kind={nodeKind} size={11} />
            <em>{NODE_KIND_LABEL[nodeKind]}</em>
          </span>
        )}
        {!isRunMode && nodeKind === 'step' && data.canChangeStatus ? (
          <label
            className="planner-node__status-select nodrag"
            title={CARD_TOOLTIPS.changeStatus}
            onClick={(event) => event.stopPropagation()}
            onPointerDown={(event) => event.stopPropagation()}
          >
            <Icon size={13} aria-hidden />
            <span>{statusLabel}</span>
            <select
              value={designStatus}
              aria-label={CARD_TOOLTIPS.statusFor(node.title)}
              onChange={(event) => data.onChangeStatus?.(node.id, event.target.value as PlanningNodeStatus)}
            >
              {DESIGN_STATUS_OPTIONS.map((status) => (
                <option key={status} value={status}>{planStatusLabelCN(status)}</option>
              ))}
            </select>
            <ChevronDown size={12} aria-hidden />
          </label>
        ) : (
          // 3-tai cut (2026-05-29): the PR-A artifact+`draft` hide-badge branch
          // is dead code — `draft` no longer exists in the public enum and
          // legacy `draft` is mapped to `ready` above. Artifact nodes now
          // always render the status badge like other kinds (artifact 的初始
          // 「就绪」语义跟 step 一致:节点一存在就 ready,推进与否由 payload
          // / done 流程决定,没有独立的「草稿」状态需要藏)。
          <span className={`planner-node__status${isRunMode ? '' : ' planner-node__status--design'}`}>
            <Icon size={13} aria-hidden />
            {statusLabel}
          </span>
        )}
        {/* UI-1 · auto / gate / human badge — placed in the top-left cluster
            so it sits beside the status pill. Top-right is reserved for UI-2.
            ui-simplification §2.11 · schedule 信息折入这个 badge(auto · 每 1h),
            不再另起独立 schedule chip。*/}
        {nodeKind === 'step' && !data.virtual && (
          <NodeModeBadge mode={nodeMode} scheduleInterval={scheduleLabel} />
        )}
        {/* UI-1 · Version chain moved off the card per ui-simplification.md §2.9
            — it now lives in the inspector right-drawer 「足迹」 section. The
            old `<select>` exposed raw `submitted_by_kind` and axios errors to
            users; both are 隐藏词 / debug surface. If a quick-peek "v{N}" pill
            on the card is wanted later, render N (chain length) and route
            click → open inspector at 足迹 tab. Do NOT reintroduce a native
            <select> on the canvas. */}
        {data.previewKind !== 'none' && (
          <span className="planner-node__badge">
            {data.previewKind === 'added' ? 'new' : 'changed'}
          </span>
        )}
        <div className="planner-node__header-actions">
          {/* ui-simplification §2.11 · schedule chip 已合并进 mode badge,
              不再独立渲染。原 'Scheduled session tick' tooltip 泄露 'session'
              这个 §0 隐藏词,一并移除。*/}
          {showResponsibleInfo && (
            <OwnerChip
              nodeId={node.id}
              nodeTitle={node.title}
              isAssigned={Boolean(data.assignment)}
              assigneeLabel={data.assignment ? assigneeLabelFromAssignment(data) : null}
              responsibleLabel={data.responsibleLabel}
              responsibleAvatarUrl={data.responsibleAvatarUrl}
              canAssign={Boolean(data.onRequestAssign) && !data.virtual && nodeKind === 'step'}
              onRequestAssign={data.onRequestAssign}
            />
          )}
        </div>
      </div>

      <div className="planner-node__title">{node.title}</div>
      {node.desc && <div className="planner-node__desc">{node.desc}</div>}

      {monitorBadge && (
        <div
          className={`planner-node__monitor-badge planner-node__monitor-badge--${monitorBadge.tone}`}
          title={monitorBadge.title}
        >
          {monitorBadge.tone === 'reply' ? <MessageCircle size={11} aria-hidden /> : <AlertTriangle size={11} aria-hidden />}
          <span>{monitorBadge.label}</span>
        </div>
      )}

      {node.widget && (() => {
        // P2.4 widget dispatcher · P3.0 接通 integration entities
        // 数据源:data.integrationEntities(PlannerGraph → adapter → PlannerNodeData)
        // 由 P3.0 backend 在 PlannerGraphStateEnvelope 里 mock 5 个 GitHub PR。
        const WidgetComp = getWidgetComponent(node.widget.kind)
        const widgetData = resolveWidgetData({
          node,
          widget: node.widget,
          // P2 fix · upstream / subcanvas-aggregate widgets resolve
          // dependsOnNodeIds[inputIndex] against the full canvas node list,
          // so hand the resolver every node we know about. Fallback to
          // `[node]` keeps virtual / standalone callers safe.
          allNodes: data.allNodes ?? [node],
          artifacts: data.artifacts,
          integrationEntities: data.integrationEntities,
        })
        const widgetWidth = (data as { widgetWidth?: number }).widgetWidth ?? 360
        const widgetHeight = (data as { widgetHeight?: number }).widgetHeight ?? 220
        return (
          <div className="planner-node__widget-body nodrag" onPointerDown={(e) => e.stopPropagation()}>
            <WidgetComp data={widgetData} width={widgetWidth} height={widgetHeight} />
          </div>
        )
      })()}

      {/* UI-simplification §2.6 / §3.1 — 卡片只保留 status+mode header / title / desc / footer 四段。
       *  原 meta chips (Runtime / Schedule / Gate)、nextAction、InputCardSections、IO output、
       *  blockers 全部下沉到 inspector(进展/成果/足迹三段);schedule/gate 信息已折入 mode badge。
       *  详情、re-run、mark-down 通过点击节点打开 inspector 操作。 */}

      {/* UI-simplification §3.1 — 「成果」行:有 artifact 时显示主推 artifact + 展开按钮。
       *  点击 [展开] 暂时打开 inspector 的 成果·剪贴板 段(Wave 4 计划把它升级为
       *  在 canvas 上 spawn 一个数据节点 capsule,按 typedPayload 渲染) */}
      {nodeKind === 'step' && !data.virtual && data.artifacts && data.artifacts.length > 0 && (
        <div className="planner-node__output-row">
          <span className="planner-node__output-label">
            <ArrowUpRight size={11} aria-hidden /> 成果
          </span>
          <span className="planner-node__output-title">
            {data.artifacts[0]?.title ?? compactArtifactLabel(data.artifacts[0]?.reference ?? '')}
          </span>
          <button
            type="button"
            className="planner-node__output-expand nodrag"
            onClick={(event) => {
              event.stopPropagation()
              data.onOpenDetails?.(node.id)
            }}
            onPointerDown={(event) => event.stopPropagation()}
            title="展开 — 打开 inspector 看完整剪贴板"
          >
            展开 ⊞
          </button>
        </div>
      )}

      {(primaryAction || (!data.virtual && data.onDeleteNode)) && (
        <div className="planner-node__footer">
          {/* UI-simplification §2.6 — Re-run / Mark down 已下沉到 inspector「进展」段,
              卡片 footer 只保留 primary action + delete confirm,避免 4 个同权重
              动作 chip 抢注意力。 */}
          {primaryAction !== 'none' && (
            <button
              type="button"
              className="planner-node__primary-action nodrag"
              disabled={primaryActionDisabled}
              onClick={(event) => {
                event.stopPropagation()
                if (primaryActionDisabled) return
                // UI-simplification §1 — 用枚举分发,文案改中文不会让分支错位。
                if (primaryAction === 'open-sub-canvas' && node.subCanvasId) {
                  data.onOpenSubCanvas?.(node.subCanvasId)
                } else if (primaryAction === 'create-session') {
                  data.onCreateSession?.(node.id, dispatchRunnerForNode(node.executorType))
                } else if (primaryAction === 'open-session' && sessionId) {
                  data.onOpenSession?.(sessionId, node.id)
                } else {
                  data.onOpenDetails?.(node.id)
                }
              }}
              aria-label={`${primaryActionText} for ${node.title}`}
              title={primaryActionText}
            >
              {primaryActionText}
            </button>
          )}
          {primaryAction === 'creating-session' && data.onCancelSessionCreation && (
            <button
              type="button"
              className="planner-node__secondary-action nodrag"
              onClick={(event) => {
                event.stopPropagation()
                data.onCancelSessionCreation?.(node.id)
              }}
              aria-label={CARD_TOOLTIPS.cancelSessionCreation(node.title)}
              title={FOOTER_LABELS.cancel}
            >
              {FOOTER_LABELS.cancel}
            </button>
          )}
          {!data.virtual && data.onDeleteNode && (
            <button
              type="button"
              className={`planner-node__delete planner-node__delete--footer nodrag nopan${deleteArmed ? ' is-confirming' : ''}`}
              title={deleteArmed ? CARD_TOOLTIPS.deleteConfirm : CARD_TOOLTIPS.deleteNode}
              aria-label={deleteArmed ? CARD_TOOLTIPS.deleteConfirmAria(node.title) : CARD_TOOLTIPS.deleteAria(node.title)}
              onClick={(event) => {
                event.stopPropagation()
                event.preventDefault()
                if (!deleteArmed) {
                  setDeleteArmed(true)
                  return
                }
                setDeleteArmed(false)
                data.onDeleteNode?.(node.id, node.title)
              }}
              onPointerDown={(event) => {
                event.stopPropagation()
              }}
              onMouseDown={(event) => {
                event.stopPropagation()
              }}
            >
              <Trash2 size={13} aria-hidden />
              <span>{deleteArmed ? FOOTER_LABELS.confirmDelete : FOOTER_LABELS.delete}</span>
            </button>
          )}
        </div>
      )}
      <Handle type="source" position={Position.Right} className="planner-node__handle" />
    </div>
  )
}

function IOColumn({
  title,
  items,
  emptyLabel,
}: {
  title: string
  items: CanvasIOItem[]
  emptyLabel: string
}) {
  return (
    <div className="planner-node__io-column">
      <span className="planner-node__io-title">{title}</span>
      <div className="planner-node__io-list">
        {items.length > 0 ? items.map((item) => {
          return (
            <span
              key={item.key}
              className={[
                'planner-node__io-item',
                `is-${item.artifactKind}`,
                item.pending ? 'is-pending' : '',
              ].filter(Boolean).join(' ')}
              title={item.reference || item.label}
            >
              <ArtifactIcon kind={item.artifactKind} size={11} />
              <span>{item.label}</span>
              <em>{item.artifactKind}</em>
            </span>
          )
        }) : (
          <span className="planner-node__io-empty">{emptyLabel}</span>
        )}
      </div>
    </div>
  )
}

function ArtifactIcon({ kind, size }: { kind: CanvasArtifactKind; size: number }) {
  if (kind === 'integration') return <Plug size={size} aria-hidden />
  if (kind === 'html') return <Code2 size={size} aria-hidden />
  if (kind === 'kanban') return <Route size={size} aria-hidden />
  if (kind === 'json' || kind === 'file') return <Code2 size={size} aria-hidden />
  return <FileText size={size} aria-hidden />
}

/**
 * nodeKind 视觉分辨 icon (2026-05-28) —— 卡片左上角小 icon,让 artifact /
 * session / step / external / subCanvas 在画板上一眼区分。
 *
 * Map:
 *   step       → SquareCheckBig (动作 / 流程)
 *   session    → MessageCircle  (AI session / 对话)
 *   artifact   → FileText       (数据 / 产物)
 *   subCanvas  → Layers         (下钻 / 嵌套)
 *   external   → Link2          (外部引用)
 */
function NodeKindIcon({ kind, size = 12 }: { kind: PlanningNodeKind; size?: number }) {
  const props = { size, 'aria-hidden': true } as const
  switch (kind) {
    case 'session':
      return <MessageCircle {...props} />
    case 'artifact':
      return <FileText {...props} />
    case 'subCanvas':
      return <Layers {...props} />
    case 'external':
      return <Link2 {...props} />
    case 'step':
    default:
      return <SquareCheckBig {...props} />
  }
}

const NODE_KIND_LABEL: Record<PlanningNodeKind, string> = {
  step: '流程',
  session: '会话',
  artifact: '产物',
  subCanvas: '子画板',
  external: '外部引用',
}

function ArtifactPreview({
  artifact,
  kind,
  kanban,
  content,
  error,
  onOpenKanbanItem,
}: {
  artifact?: PlannerArtifact
  kind: CanvasArtifactKind
  kanban: KanbanArtifactPayload | null
  content: PlannerArtifactContent | null
  error: string | null
  onOpenKanbanItem?: (artifact: PlannerArtifact, itemId: string, title: string, subCanvasId?: string | null) => void
}) {
  if (!artifact) {
    return <div className="planner-node__artifact-empty">{ARTIFACT_LABELS.empty}</div>
  }
  if (error) {
    return <div className="planner-node__artifact-empty">{error}</div>
  }
  if (kind === 'kanban' && kanban) {
    return <KanbanArtifactPreview artifact={artifact} payload={kanban} onOpenItem={onOpenKanbanItem} />
  }
  if (kind === 'html') {
    const html = content?.content ?? inlineString(artifact.payload, 'html')
    return html ? (
      <iframe
        className="planner-node__html-preview"
        title={artifact.title}
        sandbox=""
        srcDoc={html}
      />
    ) : (
      <ArtifactMetadata artifact={artifact} content={content} label={ARTIFACT_LABELS.htmlLabel} />
    )
  }
  if (kind === 'json') {
    const value = content?.content ?? inlineString(artifact.payload, 'json') ?? JSON.stringify(content?.payload ?? artifact.payload ?? {}, null, 2)
    return <pre className="planner-node__artifact-pre">{value}</pre>
  }
  if (kind === 'integration') {
    return <IntegrationArtifactPreview artifact={artifact} content={content} />
  }
  if (kind === 'file') {
    return <ArtifactMetadata artifact={artifact} content={content} label={ARTIFACT_LABELS.fileLabel} />
  }
  const text = content?.content ?? inlineString(artifact.payload, 'text')
  return text ? <pre className="planner-node__artifact-pre">{text}</pre> : <ArtifactMetadata artifact={artifact} content={content} label={ARTIFACT_LABELS.textLabel} />
}

function IntegrationArtifactPreview({ artifact, content }: { artifact: PlannerArtifact; content: PlannerArtifactContent | null }) {
  const payload = objectPayload(artifact.payload)
  const url = stringField(payload, 'url') ?? (artifact.reference.includes('://') ? artifact.reference : null)
  const provider = stringField(payload, 'provider') ?? artifact.kind
  const summary = stringField(payload, 'summary') ?? content?.content
  return (
    <div className="planner-node__integration-preview">
      <strong>{provider}</strong>
      {summary && <span>{summary}</span>}
      {url ? (
        <a href={url} target="_blank" rel="noreferrer" onClick={(event) => event.stopPropagation()}>
          {url}
        </a>
      ) : (
        <code>{artifact.reference}</code>
      )}
    </div>
  )
}

function ArtifactMetadata({
  artifact,
  content,
  label,
}: {
  artifact: PlannerArtifact
  content: PlannerArtifactContent | null
  label: string
}) {
  return (
    <div className="planner-node__artifact-meta">
      <strong>{label}</strong>
      <span>{content?.filename ?? artifact.reference}</span>
      {typeof content?.size === 'number' && <small>{formatBytes(content.size)}</small>}
    </div>
  )
}

function KanbanArtifactPreview({
  artifact,
  payload,
  onOpenItem,
}: {
  artifact?: PlannerArtifact
  payload: KanbanArtifactPayload
  onOpenItem?: (artifact: PlannerArtifact, itemId: string, title: string, subCanvasId?: string | null) => void
}) {
  return (
    <div className="planner-node__kanban">
      {payload.columns.map((column) => {
        const items = payload.items.filter((item) => item.columnId === column.id)
        return (
          <section key={column.id} className="planner-node__kanban-column">
            <div className="planner-node__kanban-column-title">
              <span>{column.title}</span>
              <em>{items.length}</em>
            </div>
            <div className="planner-node__kanban-items">
              {items.length > 0 ? items.map((item) => (
                <button
                  key={item.id}
                  type="button"
                  className="planner-node__kanban-item"
                  onClick={(event) => {
                    event.stopPropagation()
                    if (artifact) onOpenItem?.(artifact, item.id, item.title, item.subCanvasId)
                  }}
                >
                  <span>{item.title}</span>
                  {item.description && <small>{item.description}</small>}
                  <em>{item.subCanvasId ? 'Open sub canvas' : 'Create sub canvas'}</em>
                </button>
              )) : (
                <div className="planner-node__kanban-empty">No items</div>
              )}
            </div>
          </section>
        )
      })}
    </div>
  )
}

function artifactRenderKind(artifact: PlannerArtifact | undefined, fallback: CanvasArtifactKind): CanvasArtifactKind {
  const payload = objectPayload(artifact?.payload)
  const type = stringField(payload, 'type')
  if (artifact?.kind === 'kanban') return 'kanban'
  if (type === 'text' || type === 'html' || type === 'kanban' || type === 'integration' || type === 'json' || type === 'file') {
    return type
  }
  return fallback
}

function selectPrimaryArtifact(artifacts: PlannerArtifact[]): PlannerArtifact | undefined {
  return [...artifacts].sort((a, b) => artifactDisplayScore(b) - artifactDisplayScore(a))[0]
}

function artifactDisplayScore(artifact: PlannerArtifact): number {
  const payload = objectPayload(artifact.payload)
  const inlineKanban = parseKanbanPayload(artifact.payload)
  const hasBlob = typeof payload?.blobRef === 'string' && payload.blobRef.trim().length > 0
  const createdAt = Date.parse(String(artifact.createdAt))
  return ((inlineKanban?.items.length ?? 0) > 0 ? 10_000 + inlineKanban!.items.length : 0)
    + (hasBlob ? 5_000 : 0)
    + (payload?.type === 'kanban' ? 2_000 : 0)
    + (artifact.kind === 'kanban' ? 1_000 : 0)
    + ((inlineKanban?.columns.length ?? 0) > 0 ? 100 : 0)
    + (Number.isFinite(createdAt) ? createdAt / 1_000_000_000_000 : 0)
}

function inlineString(payload: unknown, field: 'text' | 'html' | 'json'): string | null {
  const object = objectPayload(payload)
  return stringField(object, field)
}

function objectPayload(payload: unknown): Record<string, unknown> | null {
  return payload && typeof payload === 'object' && !Array.isArray(payload)
    ? payload as Record<string, unknown>
    : null
}

function stringField(object: Record<string, unknown> | null, field: string): string | null {
  const value = object?.[field]
  return typeof value === 'string' && value.trim() ? value : null
}

function formatBytes(value: number): string {
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  return `${(value / (1024 * 1024)).toFixed(1)} MB`
}

function parseKanbanPayload(payload: unknown): KanbanArtifactPayload | null {
  if (!payload || typeof payload !== 'object') return null
  const candidate = payload as Partial<KanbanArtifactPayload>
  if (candidate.version !== 1 || !Array.isArray(candidate.columns) || !Array.isArray(candidate.items)) {
    return null
  }
  const columns = candidate.columns
    .filter((column): column is { id: string; title: string } =>
      Boolean(column)
      && typeof column.id === 'string'
      && typeof column.title === 'string',
    )
  const items = candidate.items
    .filter((item): item is KanbanArtifactPayload['items'][number] =>
      Boolean(item)
      && typeof item.id === 'string'
      && typeof item.columnId === 'string'
      && typeof item.title === 'string',
    )
    .map((item) => ({
      id: item.id,
      columnId: item.columnId,
      title: item.title,
      description: typeof item.description === 'string' ? item.description : undefined,
      subCanvasId: typeof item.subCanvasId === 'string' ? item.subCanvasId : null,
    }))
  if (columns.length === 0) return null
  return { version: 1, columns, items }
}

function parseMarkdownKanbanPayload(content: string | null | undefined): KanbanArtifactPayload | null {
  if (!content?.trim()) return null
  const tableRows = content
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.startsWith('|') && line.endsWith('|'))
    .map(splitMarkdownTableRow)
  if (tableRows.length < 2) return null

  const header = tableRows[0].map((cell) => cell.toLowerCase())
  const rows = tableRows.slice(1).filter((row) => !isMarkdownSeparatorRow(row))
  const titleIndex = header.findIndex((cell) => cell.includes('idea') || cell.includes('title') || cell.includes('name'))
  if (titleIndex < 0) return null
  const descriptionIndex = header.findIndex((cell) => cell.includes('description') || cell.includes('note') || cell.includes('summary'))
  const priorityIndex = header.findIndex((cell) => cell.includes('priority'))
  const statusIndex = header.findIndex((cell) => cell.includes('status') || cell.includes('column'))

  const columns = new Map<string, { id: string; title: string }>()
  const items: KanbanArtifactPayload['items'] = []
  rows.forEach((row, index) => {
    const title = row[titleIndex]?.trim()
    if (!title) return
    const rawStatus = statusIndex >= 0 ? cleanupMarkdownCell(row[statusIndex]) : ''
    const columnTitle = rawStatus || 'Backlog'
    const columnId = slugifyKanbanId(columnTitle, columns.size + 1)
    if (!columns.has(columnId)) columns.set(columnId, { id: columnId, title: columnTitle })
    const description = descriptionIndex >= 0 ? cleanupMarkdownCell(row[descriptionIndex]) : ''
    const priority = priorityIndex >= 0 ? cleanupMarkdownCell(row[priorityIndex]) : ''
    const details = [
      priority ? `Priority: ${priority}` : '',
      description,
    ].filter(Boolean).join('\n')
    items.push({
      id: `item-${index + 1}`,
      columnId,
      title: cleanupMarkdownCell(title),
      description: details || undefined,
      subCanvasId: null,
    })
  })

  if (items.length === 0 || columns.size === 0) return null
  return { version: 1, columns: Array.from(columns.values()), items }
}

function splitMarkdownTableRow(line: string): string[] {
  return line.slice(1, -1).split('|').map(cleanupMarkdownCell)
}

function isMarkdownSeparatorRow(row: string[]): boolean {
  return row.every((cell) => /^:?-{3,}:?$/.test(cell.trim()))
}

function cleanupMarkdownCell(value: string): string {
  return value
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/\*\*/g, '')
    .trim()
}

function slugifyKanbanId(value: string, fallbackIndex: number): string {
  const slug = value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
  return slug || `column-${fallbackIndex}`
}

function emptyKanbanPayload(title: string): KanbanArtifactPayload {
  return {
    version: 1,
    columns: [
      {
        id: 'idea-list',
        title: title.toLowerCase().includes('idea') ? 'Idea list' : 'List',
      },
    ],
    items: [],
  }
}

function monitorBadgeTitle(item: NonNullable<PlannerGraphNode['data']['monitorItem']>): string {
  return item.replyPrompt
    || item.nextAction
    || item.blockers[0]
    || monitorReasonLabel(item.reasonKind)
}

function monitorReasonLabel(reason: string): string {
  switch (reason) {
  case 'permission_required':
    return 'Permission required'
  case 'waiting_for_user':
    return 'Waiting for user response'
  case 'inbox_pending':
    return 'Pending message'
  case 'gate_wait':
    return 'Waiting for gate review'
  case 'awaiting_input':
    return 'Awaiting input'
  case 'blocked':
    return 'Blocked'
  case 'failed':
    return 'Failed'
  default:
    return 'Attention'
  }
}

function buildCanvasIOItems(data: PlannerGraphNode['data']): {
  inputs: CanvasIOItem[]
  outputs: CanvasIOItem[]
  hasIO: boolean
} {
  const node = data.node
  const schemaInputs = node.schema?.inputs ?? []
  const inputItems = dedupeIOItems([
    ...(schemaInputs.length > 0 ? [] : (node.contextSources ?? []).map((source, index): CanvasIOItem => ({
      key: `context:${source.reference || source.title || index}`,
      label: compactArtifactLabel(source.title || source.reference),
      reference: source.reference,
      artifactKind: classifyArtifactKind(source.reference || source.kind),
    }))),
    ...(schemaInputs.map((input, index): CanvasIOItem => ({
      key: `consume:${input}:${index}`,
      label: compactArtifactLabel(input),
      reference: input,
      artifactKind: classifyArtifactKind(input),
    }))),
  ])

  const actualRefs = dedupeStrings([
    ...(node.artifactRefs ?? []),
    ...(data.state?.artifactRefs ?? []),
    ...data.artifacts.map((artifact) => artifact.reference),
  ])
  const richArtifactsByRef = new Map(data.artifacts.map((artifact) => [artifact.reference, artifact]))
  const actualOutputItems = actualRefs.map((ref, index): CanvasIOItem => {
    const artifact = richArtifactsByRef.get(ref)
    return {
      key: `output:${ref || index}`,
      label: compactArtifactLabel(artifactTitle(artifact, ref)),
      reference: artifact?.reference ?? ref,
      artifactKind: artifactRenderKind(artifact, classifyArtifactKind(artifact?.reference ?? ref)),
    }
  })
  const pendingOutputItems = (node.schema?.outputs ?? [])
    .filter((output) => !actualRefs.some((ref) => artifactMatchesExpectation(ref, output)))
    .map((output, index): CanvasIOItem => ({
      key: `pending:${output}:${index}`,
      label: compactArtifactLabel(output),
      reference: output,
      artifactKind: classifyArtifactKind(output),
      pending: true,
    }))
  const outputItems = dedupeIOItems([...actualOutputItems, ...pendingOutputItems])
  return {
    inputs: inputItems,
    outputs: outputItems,
    hasIO: inputItems.length > 0 || outputItems.length > 0 || (node.schema?.outputs?.length ?? 0) > 0,
  }
}

function artifactTitle(artifact: PlannerArtifact | undefined, fallback: string): string {
  return artifact?.title?.trim() || fallback
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

function dedupeIOItems(items: CanvasIOItem[]): CanvasIOItem[] {
  const seen = new Set<string>()
  const result: CanvasIOItem[] = []
  for (const item of items) {
    const key = `${item.reference || item.label}`.toLowerCase()
    if (seen.has(key)) continue
    seen.add(key)
    result.push(item)
  }
  return result
}

function compactArtifactLabel(value: string): string {
  const trimmed = value.trim()
  if (!trimmed) return 'Untitled'
  const withoutQuery = trimmed.split('?')[0]
  const parts = withoutQuery.split(/[/:#]/).filter(Boolean)
  return parts[parts.length - 1]?.trim() || trimmed
}

function classifyArtifactKind(reference: string): CanvasArtifactKind {
  const normalized = reference.toLowerCase()
  if (normalized.includes('kanban') || normalized.includes('看板')) {
    return 'kanban'
  }
  if (normalized.includes('json') || normalized.endsWith('.json')) {
    return 'json'
  }
  if (normalized.includes('html') || normalized.includes('webpage') || normalized.includes('web-page')) {
    return 'html'
  }
  if (normalized.includes('file') || normalized.includes('attachment')) {
    return 'file'
  }
  if (
    normalized.includes('://')
    || normalized.startsWith('github:')
    || normalized.startsWith('git:')
    || normalized.startsWith('lark:')
    || normalized.startsWith('http:')
    || normalized.startsWith('https:')
  ) {
    return 'integration'
  }
  return 'text'
}

function artifactMatchesExpectation(reference: string, expected: string): boolean {
  const normalize = (value: string) => value
    .toLowerCase()
    .replace(/^[a-z][a-z0-9+.-]*:\/\//, '')
    .replace(/[^a-z0-9]+/g, '')
  const ref = normalize(reference)
  const target = normalize(expected)
  return Boolean(target) && (ref === target || ref.endsWith(target) || ref.includes(target))
}

// UI-simplification §1 — 文案/枚举集中到 labels.ts:
//   - planStatusLabel / workStatusLabel — 状态徽章(已迁移到 labels.ts)
//   - primaryActionLabel — 返回 PrimaryAction 枚举,显示文本走
//     PRIMARY_ACTION_TEXT[action];switch 分发用枚举,不再字符串比较。
//   - nextPlanAction / nextWorkAction / runNextActionLabel — inspector 行文案。

function designKind(node: PlannerGraphNode['data']['node']): PlanningNodeKind {
  return node.nodeKind ?? (node.source === 'session' ? 'session' : node.subCanvasId ? 'subCanvas' : 'step')
}

function dispatchRunnerForNode(executorType: PlannerGraphNode['data']['node']['executorType']): PlannerDispatchRunner {
  if (executorType === 'codex') return 'codex'
  if (executorType === 'claude') return 'claude'
  return loadSpawnProvider()
}

function runtimeLabelForNode(executorType: PlannerGraphNode['data']['node']['executorType']): string {
  if (executorType === 'codex') return 'Codex'
  if (executorType === 'claude') return 'Claude'
  if (executorType === 'human') return `Default: ${spawnProviderLabel(loadSpawnProvider())}`
  if (executorType === 'mock') return `Default: ${spawnProviderLabel(loadSpawnProvider())}`
  return `${executorType} / fallback ${spawnProviderLabel(loadSpawnProvider())}`
}

function scheduleIntervalLabel(intervalSeconds: number): string {
  const seconds = Math.max(60, Math.round(intervalSeconds || 60))
  if (seconds % 3600 === 0) return `${seconds / 3600}h`
  if (seconds % 60 === 0) return `${seconds / 60}m`
  return `${seconds}s`
}

function gateModeLabel(node: PlannerGraphNode['data']['node']): 'Human' | 'Auto' {
  if (node.executionMode === 'human') return 'Human'
  if ((node.gate?.approvers ?? []).length > 0) return 'Human'
  return 'Auto'
}

// UI-1 · Derive the auto/gate/human badge value. Explicit human execution
// always wins; gate review requirements promote auto → gate; everything else
// is auto.
function resolveNodeMode(node: PlannerGraphNode['data']['node']): NodeMode {
  if (node.executionMode === 'human') return 'human'
  const approvers = node.gate?.approvers ?? []
  if (approvers.length > 0) return 'gate'
  return 'auto'
}

// UI-1 · Pick the artifact slot the version dropdown should anchor to. Latest
// artifact (by createdAt) wins — matches the runtime's "latest" display
// strategy default and keeps the dropdown deterministic when the node has
// multiple slots (the user can drill into NodeInspector for per-slot history).
function pickLatestArtifactForVersions(artifacts: PlannerArtifact[]): PlannerArtifact | undefined {
  if (artifacts.length === 0) return undefined
  return [...artifacts].sort((a, b) => {
    const ta = Date.parse(String(a.createdAt))
    const tb = Date.parse(String(b.createdAt))
    return (Number.isFinite(tb) ? tb : 0) - (Number.isFinite(ta) ? ta : 0)
  })[0]
}

function NodeModeBadge({ mode, scheduleInterval }: { mode: NodeMode; scheduleInterval: string | null }) {
  const Icon = MODE_ICON[mode]
  return (
    <span
      className={`planner-node__mode-badge planner-node__mode-badge--${mode}`}
      title={modeBadgeTooltip(mode, scheduleInterval)}
    >
      <Icon size={11} aria-hidden />
      <span>{modeBadgeLabel(mode, scheduleInterval)}</span>
    </span>
  )
}

// UI-1 · Lazy-loading version dropdown. The chain is fetched on first open
// (so closed cards don't fan out N requests on first paint). "Latest" is the
// default visual state — selecting a non-latest entry stashes the chosen
// version-id in local state so callers (NodeInspector / future diff view) can
// pick it up; we deliberately do NOT mutate any server pointer here, matching
// acceptance criterion 2 in the spec.
function NodeVersionDropdown({
  canvasId,
  nodeId,
  reference,
}: {
  canvasId: string
  nodeId: string
  reference: string
}) {
  const [versions, setVersions] = useState<PlannerArtifactVersion[] | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [selectedVersionId, setSelectedVersionId] = useState<string>('latest')

  // Reset selection whenever the slot changes (e.g. user picks another node /
  // the node's primary artifact ref flips).
  useEffect(() => {
    setSelectedVersionId('latest')
    setVersions(null)
    setError(null)
  }, [canvasId, nodeId, reference])

  const ensureLoaded = () => {
    if (versions !== null || loading) return
    setLoading(true)
    listArtifactVersions(canvasId, nodeId, reference)
      .then((result) => setVersions(result.versions ?? []))
      .catch((err) => setError((err as Error).message || 'Failed to load versions'))
      .finally(() => setLoading(false))
  }

  const selectedLabel = useMemo(() => {
    if (selectedVersionId === 'latest') return 'Latest'
    const v = versions?.find((entry) => entry.version_id === selectedVersionId)
    return v ? formatVersionLabel(v) : 'Latest'
  }, [selectedVersionId, versions])

  // 注意:axios / network 报错文案不能进 <select> 的 <option>(那条信息会
  // 变成可"选中"的项,且原文是英文 stack 文案,违反 ui-simplification.md
  // 隐藏词约定)。改用一行 user-facing 中文文案放在 trigger 的 title +
  // 旁边的小字行里。
  const errorTitle = error ? '历史版本暂时读不到,稍后再试' : '查看历史版本'
  return (
    <span className="planner-node__version-select-wrap">
      <label
        className="planner-node__version-select nodrag"
        title={errorTitle}
        onClick={(event) => {
          event.stopPropagation()
          ensureLoaded()
        }}
        onPointerDown={(event) => event.stopPropagation()}
      >
        <History size={11} aria-hidden />
        <span>{selectedLabel}</span>
        <select
          value={selectedVersionId}
          aria-label="历史版本"
          onChange={(event) => setSelectedVersionId(event.target.value)}
          onFocus={ensureLoaded}
          onMouseDown={ensureLoaded}
        >
          <option value="latest">最新</option>
          {loading && <option disabled value="__loading">载入中…</option>}
          {(versions ?? []).map((v) => (
            <option key={v.version_id} value={v.version_id}>
              {formatVersionLabel(v)}
            </option>
          ))}
        </select>
        <ChevronDown size={11} aria-hidden />
      </label>
      {error && (
        <span className="planner-node__version-select-error">
          历史版本暂时读不到,稍后再试
        </span>
      )}
    </span>
  )
}

function formatVersionLabel(v: PlannerArtifactVersion): string {
  const ts = Date.parse(v.created_at)
  const stamp = Number.isFinite(ts)
    ? new Date(ts).toLocaleString(undefined, { month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' })
    : v.created_at
  // 不要 fallback 到 v.submitted_by_kind —— schema 字段名是 UI 的隐藏词
  // (ui-simplification.md §1)。team directory 没解出 submitted_by 时,
  // 用「未知提交者」兜底,绝不暴露 `kind`。
  const submitter = v.submitted_by || '未知提交者'
  return `${stamp} · ${submitter}`
}


// ---- UI-2 helpers -----------------------------------------------------------

/** Pick the best label we can show for the assignee — assignment carries the
 *  user id but not the display name. Falls back to the responsibleLabel
 *  computed in the adapter via the team directory. */
function assigneeLabelFromAssignment(data: PlannerGraphNode['data']): string {
  if (!data.assignment) return OWNER_CHIP.unassigned
  if (data.responsibleLabel) return data.responsibleLabel
  return data.assignment.assigneeUserId.slice(0, 8)
}

interface OwnerChipProps {
  nodeId: string
  nodeTitle: string
  isAssigned: boolean
  assigneeLabel: string | null
  responsibleLabel?: string
  responsibleAvatarUrl?: string
  canAssign: boolean
  onRequestAssign?: (nodeId: string) => void
}

/** UI-2 · F1.1 — 节点头部右上的负责人 chip。
 *  点击打开分配对话框。已经分配后,chip 变成只读徽章并停止响应点击 ——
 *  目前还不支持改派(超出当前范围),所以不暴露这条路径。所有面向用户的
 *  文案集中在 labels.ts 的 OWNER_CHIP,避免重新引入英文工程词
 *  (ui-simplification.md §1 隐藏 owner-doer-viewer 这类词,§2.6 footer
 *  用 @assignee / 未分配 表达)。按钮显式带 `nodrag nopan`,防止 React
 *  Flow 把点击当成节点拖拽。 */
function OwnerChip({
  nodeId,
  nodeTitle,
  isAssigned,
  assigneeLabel,
  responsibleLabel,
  responsibleAvatarUrl,
  canAssign,
  onRequestAssign,
}: OwnerChipProps) {
  const label = isAssigned
    ? (assigneeLabel ? `${OWNER_CHIP.prefixAssigned}${assigneeLabel}` : OWNER_CHIP.unassigned)
    : (responsibleLabel ? `${OWNER_CHIP.prefixAssigned}${responsibleLabel}` : OWNER_CHIP.unassigned)
  const title = isAssigned
    ? OWNER_CHIP.tooltipAssignedRevoke
    : canAssign
      ? OWNER_CHIP.tooltipAssign(nodeTitle)
      : OWNER_CHIP.tooltipReadonly(label)
  if (isAssigned || !canAssign || !onRequestAssign) {
    return (
      <span
        className={`planner-node__owner-pill${isAssigned ? ' planner-node__owner-pill--assigned' : ''}`}
        title={title}
      >
        <span className={`planner-node__mini-avatar${responsibleAvatarUrl ? ' has-image' : ''}`} aria-hidden>
          {responsibleAvatarUrl ? <img src={responsibleAvatarUrl} alt="" /> : <UserRound size={12} />}
        </span>
        <span>{label}</span>
      </span>
    )
  }
  return (
    <button
      type="button"
      className="planner-node__owner-pill planner-node__owner-pill--button nodrag nopan"
      title={title}
      aria-label={title}
      onClick={(event) => {
        event.stopPropagation()
        onRequestAssign(nodeId)
      }}
      onPointerDown={(event) => event.stopPropagation()}
      onMouseDown={(event) => event.stopPropagation()}
    >
      <span className={`planner-node__mini-avatar${responsibleAvatarUrl ? ' has-image' : ''}`} aria-hidden>
        {responsibleAvatarUrl ? <img src={responsibleAvatarUrl} alt="" /> : <UserRound size={12} />}
      </span>
      <span>{label}</span>
      <UserPlus size={11} aria-hidden className="planner-node__owner-pill-cta" />
    </button>
  )
}

interface SubCanvasRefCardProps {
  node: PlanningNode
  assignment: NodeAssignment
  assigneeLabel: string
  avatarUrl?: string
  onOpenAssignedSubCanvas?: (subCanvasId: string) => void
  selected: boolean
}

/** UI-2 · F1.1 — the node body collapsed to a sub-canvas reference chip.
 *  The whole card is read-only (parent owner has lost internal-edit rights
 *  per ENG-4 RLS). A single primary action takes the user into the assigned
 *  sub-canvas if a navigator is wired. The `frozen_io_contract` is shown
 *  in a compact summary so the parent owner can still verify the boundary. */
function SubCanvasRefCard({
  node,
  assignment,
  assigneeLabel,
  avatarUrl,
  onOpenAssignedSubCanvas,
  selected,
}: SubCanvasRefCardProps) {
  const inputCardinalityRaw = assignment.frozenIOContract?.input?.upstream?.mode ?? 'unspecified'
  const outputCardinalityRaw = assignment.frozenIOContract?.output?.cardinality ?? 'unspecified'
  const inputCardinalityLabel = SUBCANVAS_REF_LABELS.cardinality[inputCardinalityRaw]
  const outputCardinalityLabel = SUBCANVAS_REF_LABELS.cardinality[outputCardinalityRaw]
  return (
    <div
      className={[
        'planner-node',
        'planner-node--subcanvas-ref',
        selected ? 'is-selected' : '',
      ].filter(Boolean).join(' ')}
    >
      <Handle type="target" position={Position.Left} className="planner-node__handle" />
      <div className="planner-node__header">
        <span className="planner-node__status planner-node__status--design">
          <Lock size={12} aria-hidden />
          {SUBCANVAS_REF_LABELS.assigned}
        </span>
        <div className="planner-node__header-actions">
          <span
            className="planner-node__owner-pill planner-node__owner-pill--assigned"
            title={SUBCANVAS_REF_LABELS.ownedByTooltip(assigneeLabel)}
          >
            <span className={`planner-node__mini-avatar${avatarUrl ? ' has-image' : ''}`} aria-hidden>
              {avatarUrl ? <img src={avatarUrl} alt="" /> : <UserRound size={12} />}
            </span>
            <span>{assigneeLabel}</span>
          </span>
        </div>
      </div>
      <div className="planner-node__title">{node.title}</div>
      {node.desc && <div className="planner-node__desc">{node.desc}</div>}
      <div className="planner-node__subcanvas-ref-body">
        <div className="planner-node__subcanvas-ref-meta">
          <span className="planner-node__chip">
            <FileText size={10} aria-hidden />
            {SUBCANVAS_REF_LABELS.subCanvas}: {assignment.subCanvasName || assignment.subCanvasId.slice(0, 8)}
          </span>
          {inputCardinalityLabel && (
            <span className="planner-node__chip">
              {SUBCANVAS_REF_LABELS.in}: {inputCardinalityLabel}
            </span>
          )}
          {outputCardinalityLabel && (
            <span className="planner-node__chip">
              {SUBCANVAS_REF_LABELS.out}: {outputCardinalityLabel}
            </span>
          )}
        </div>
      </div>
      {onOpenAssignedSubCanvas && (
        <div className="planner-node__footer">
          <button
            type="button"
            className="planner-node__primary-action nodrag"
            onClick={(event) => {
              event.stopPropagation()
              onOpenAssignedSubCanvas(assignment.subCanvasId)
            }}
            title={SUBCANVAS_REF_LABELS.openTooltip(assigneeLabel)}
          >
            {SUBCANVAS_REF_LABELS.openSubCanvas}
            <ArrowUpRight size={12} aria-hidden style={{ marginLeft: 4 }} />
          </button>
        </div>
      )}
      <Handle type="source" position={Position.Right} className="planner-node__handle" />
    </div>
  )
}

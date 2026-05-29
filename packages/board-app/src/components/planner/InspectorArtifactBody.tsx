// UI-simplification — artifact-mode Inspector body.
//
// 当 nodeKind === 'artifact' 时,NodeInspectorModal 走这个分支:
//   - Header(state badge + title) — 由调用方渲染 modal shell
//   - 产物预览/编辑区 (PayloadBodySwitch,按 ArtifactPayload.type 分发)
//   - 状态行(state badge + blockers)
//   - 版本(VersionTimeline,横向 chip)
//   - 来源(SourceLineagePanel,只读 lineage)
//   - 卡片样式(widget chip popover,artifact 节点收窄 allowed chips)
//   - 操作(ArtifactActionsBar,artifact-only 动作)
//   - 版本与足迹(FootprintTimeline,version chain + 上游 session 链接)
//
// step / session / subCanvas 路径走 NodeInspectorModal 主体不变,这里彻底隔离。

import {
  AlertTriangle,
  Archive,
  ArrowUpRight,
  Database,
  Eye,
  FileText,
  GitCompare,
  Layers,
  Pencil,
  Plug,
  RefreshCw,
  Route,
  Settings2,
  Sparkles,
  Trash2,
} from 'lucide-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import { proposePlannerGraphChange } from '../../api'
import { useToast } from '../../App'
import type {
  ArtifactPayload,
  ContextSource,
  NodeContractExternalInput,
  NodeStateSnapshot,
  PlanProposal,
  PlannerArtifact,
  PlanningNode,
  Widget,
  WidgetKind,
} from '../../types'

interface Props {
  node: PlanningNode
  canvasId: string
  variant: 'board' | 'template'
  state: NodeStateSnapshot | null
  artifacts: PlannerArtifact[]
  onClose: () => void
  onProposalCreated?: (proposal: PlanProposal) => void
  onOpenSession?: (sessionId: string, nodeId: string) => void
  onRerunNode?: (nodeId: string, reference?: string) => void
  /** UI-4 — open the parent-managed AttachDataSourcePopover (same instance as
   *  step nodes use). The wire shape persisted server-side is the canonical
   *  `input.external[]` array (connector + ref + sync_session). */
  onAttachDataSource?: (nodeId: string) => void
  /** UI-4 — refresh-now per bound external row. */
  onRefreshExternalInput?: (nodeId: string, external: NodeContractExternalInput) => void
}

// artifact 节点上,卡片样式 popover 收窄到三个有意义的 widget(design 约定)。
const ARTIFACT_WIDGET_OPTIONS: ReadonlyArray<{
  kind: WidgetKind | 'standard'
  label: string
  tooltip: string
}> = [
  {
    kind: 'standard',
    label: '标准',
    tooltip: '不渲染 widget,显示节点本身(标题 / 状态)',
  },
  {
    kind: 'artifact-preview',
    label: '产物预览',
    tooltip: '内嵌预览(markdown / 文件),适合 PRD / PR / 报告',
  },
  {
    kind: 'kanban',
    label: '看板',
    tooltip: '把上游数据 / 子画板按 status 分成列',
  },
  {
    kind: 'inbox',
    label: '收件箱',
    tooltip: '把数据扁平展开,按最近活动倒序',
  },
]

// design spec ui_surface §dataSource — artifact 二模 enum (2026-05-28 简化).
// 与 widget.source 正交并行: artifact.dataSource 决定 payload 权威来源 (data 层),
// widget.source 决定渲染来源 (view 层)。
//
// 已删 'aggregated' (widget.source=upstream 已覆盖 view 层聚合)。
// 已删 mirrorPolicy / refreshSeconds (pull-on-consume snapshot 模型让两者无意义)。
type ArtifactDataSourceMode = 'authored' | 'mirrored'

const ARTIFACT_DATA_SOURCE_OPTIONS: ReadonlyArray<{
  mode: ArtifactDataSourceMode
  label: string
  tooltip: string
}> = [
  {
    mode: 'authored',
    label: '手填',
    tooltip: '这里直接写 — 节点自带 payload,可编辑',
  },
  {
    mode: 'mirrored',
    label: '接外部',
    tooltip: '绑一个 integration (Notion / Linear / GitHub 等),下游消费时拉最新数据 + 冻一份快照',
  },
]

// Inspector 读取当前模式 — 与 widgetDataResolver 共享 loose lookup 路径
// (PlanningNode.artifactConfig 尚未落到 types.ts,旧节点缺省 → 'authored')。
// 'aggregated' / 'upstream' 旧值 → fallback authored (兼容老数据,实际不再出现)。
//
// **读取优先级**(canonical → legacy):
//   1. node.artifactDataSource (top-level string) — Swift 后端写的字段
//   2. node.artifact.dataSource / node.artifactConfig.dataSource (loose) — 旧 wave-3 试探
function readArtifactDataSourceMode(node: PlanningNode): ArtifactDataSourceMode {
  const cfg = node as unknown as {
    artifactDataSource?: string
    artifact?: { dataSource?: string | { mode?: string } }
    artifactConfig?: { dataSource?: string | { mode?: string } }
  }
  const raw =
    cfg.artifactDataSource ??
    cfg.artifact?.dataSource ??
    cfg.artifactConfig?.dataSource
  const value = typeof raw === 'string' ? raw : raw?.mode
  switch (value) {
    case 'self':
    case 'authored':
      return 'authored'
    case 'external':
    case 'mirrored':
      return 'mirrored'
    case 'upstream':
    case 'aggregated':
      // 已删模式,fallback 到 authored
      return 'authored'
    default:
      return 'authored'
  }
}

export function InspectorArtifactBody({
  node,
  canvasId,
  variant,
  state,
  artifacts,
  onClose,
  onProposalCreated,
  onOpenSession,
  onRerunNode,
  onAttachDataSource,
  onRefreshExternalInput,
}: Props) {
  const toast = useToast()
  const isTemplate = variant === 'template'
  const runState = state?.runState ?? node.status
  const blockers = isTemplate
    ? []
    : state?.blockers?.length
      ? state.blockers
      : node.status === 'blocked' && node.blockedReason?.trim()
        ? [node.blockedReason.trim()]
        : []

  // 同节点 + reference 同槽的 artifacts,按时间倒序;最新的一条作为主预览。
  const nodeArtifacts = useMemo(
    () =>
      artifacts
        .filter((art) => art.nodeId === node.id)
        .sort((a, b) => {
          const ta = Date.parse(String(a.createdAt))
          const tb = Date.parse(String(b.createdAt))
          return (Number.isFinite(tb) ? tb : 0) - (Number.isFinite(ta) ? ta : 0)
        }),
    [artifacts, node.id],
  )
  const latestArtifact = nodeArtifacts[0] ?? null

  // 用户点版本 chip → 主预览切换到那个版本;默认显示 latest。
  const [selectedArtifactId, setSelectedArtifactId] = useState<string | null>(null)
  const activeArtifact =
    nodeArtifacts.find((a) => a.id === selectedArtifactId) ?? latestArtifact

  // 编辑切换(仅 markdown / prd / kanban 类型可编辑;v0.1 是占位 — 编辑器尚未上)。
  const [editMode, setEditMode] = useState(false)
  const activePayload: ArtifactPayload | null =
    activeArtifact?.typedPayload ?? null
  const canEditPayload =
    activePayload?.type === 'markdown' ||
    activePayload?.type === 'prd' ||
    activePayload?.type === 'kanban'

  // theta (2026-05-29) — review gate. Source of truth is the artifact-level
  // reviewStatus; typedPayload.reviewStatus mirrors it for callers that only
  // see the payload envelope. Absence ≡ 'approved'.
  const activeReviewStatus =
    activeArtifact?.reviewStatus ?? activePayload?.reviewStatus ?? 'approved'
  const isReviewPending = activeReviewStatus === 'pending'
  const [promoting, setPromoting] = useState(false)
  const handlePromoteArtifact = () => {
    if (!activeArtifact || promoting) return
    setPromoting(true)
    // theta-fix (2026-05-29): codex P1 — the previous fallback overwrote
    // payload with `{ type: 'markdown', preview: '' }` when typedPayload
    // was absent, which is the common case for normal markdown/prd/file
    // artifacts coming through PlannerGraphStateEnvelope (only `.payload`
    // is sent on the wire). That clobbered the original content during
    // Promote. Fix: carry `reviewStatus: 'approved'` on the draft itself
    // (PlanArtifactDraft.reviewStatus, added to Swift + Zod schema), and
    // preserve the original `payload` byte-for-byte. Apply-path stamps
    // PlannerArtifact.reviewStatus from the draft field directly.
    proposePlannerGraphChange(canvasId, {
      summary: `Promote ${activeArtifact.title} to approved`,
      changes: [
        {
          kind: 'attachArtifact',
          nodeId: node.id,
          artifact: {
            kind: activeArtifact.kind,
            title: activeArtifact.title,
            reference: activeArtifact.reference,
            status: activeArtifact.status,
            payload: activeArtifact.payload,
            reviewStatus: 'approved',
          },
        },
      ],
    })
      .then((proposal) => {
        setPromoting(false)
        if (!proposal) {
          toast.push('error', 'Promote 失败:服务端没返回提议')
          return
        }
        onProposalCreated?.(proposal)
        toast.push('success', `已提交 Promote 提议:${activeArtifact.title}`)
      })
      .catch((err) => {
        setPromoting(false)
        toast.push('error', `Promote 失败:${(err as Error).message || '未知错误'}`)
      })
  }

  // 卡片样式(widget chip)popover。
  const [widgetDraft, setWidgetDraft] = useState<Widget | null>(node.widget ?? null)
  const [widgetSaving, setWidgetSaving] = useState(false)
  const [widgetError, setWidgetError] = useState<string | null>(null)
  const [widgetPopoverOpen, setWidgetPopoverOpen] = useState(false)
  const widgetPopoverRef = useRef<HTMLDivElement | null>(null)
  useEffect(() => {
    if (!widgetPopoverOpen) return
    const onMouseDown = (event: MouseEvent) => {
      const ref = widgetPopoverRef.current
      if (!ref) return
      if (event.target instanceof Node && ref.contains(event.target)) return
      setWidgetPopoverOpen(false)
    }
    document.addEventListener('mousedown', onMouseDown)
    return () => document.removeEventListener('mousedown', onMouseDown)
  }, [widgetPopoverOpen])

  // dataSource picker — design spec ui_surface.inspector_picker (chip 3-option, auto-save).
  // 默认值: 旧节点缺省 → 'authored' (rollout 兼容)。
  const currentDataSource = useMemo(() => readArtifactDataSourceMode(node), [node])
  const [dataSourceDraft, setDataSourceDraft] = useState<ArtifactDataSourceMode>(currentDataSource)
  const [dataSourceSaving, setDataSourceSaving] = useState(false)
  const [dataSourceError, setDataSourceError] = useState<string | null>(null)
  useEffect(() => {
    setDataSourceDraft(currentDataSource)
  }, [currentDataSource])

  // 已绑定 external rows — 复用 step 节点的 derive 路径(input.external 形状):
  // 每行 = { connector, ref, sync_session }, 与 NodeContractExternalInput 严格一致。
  const externalBindings = useMemo(() => deriveExternalInputs(node), [node])

  const handlePickDataSource = (mode: ArtifactDataSourceMode) => {
    if (mode === dataSourceDraft) return
    setDataSourceError(null)
    setDataSourceDraft(mode)
    setDataSourceSaving(true)
    // PlanChange 暂无 setArtifactDataSource 独立 variant — 走 updateNode + loose
    // payload (后端 zod schema 兼容期), 等 wave-4 后端落 variant 再切。
    const change = {
      kind: 'updateNode' as const,
      nodeId: node.id,
      artifactConfig: { dataSource: { mode } },
    }
    proposePlannerGraphChange(canvasId, {
      summary: `Set dataSource to ${mode} on ${node.title}`,
      changes: [change as unknown as Parameters<typeof proposePlannerGraphChange>[1]['changes'][number]],
    })
      .then((proposal) => {
        setDataSourceSaving(false)
        if (!proposal) {
          setDataSourceError('服务端没返回提议')
          return
        }
        onProposalCreated?.(proposal)
      })
      .catch((err) => {
        setDataSourceSaving(false)
        setDataSourceError((err as Error).message || '保存失败')
      })
  }

  const handlePickWidgetKind = (kind: WidgetKind | 'standard') => {
    setWidgetError(null)
    const next: Widget | null =
      kind === 'standard'
        ? null
        : {
            kind,
            // artifact 节点的智能默认 source — 自己的 payload 就是数据,
            // upstream artifact 也是合理的(被聚合)。
            source: widgetDraft?.source ?? { inputKind: 'upstream', inputIndex: 0 },
            mapping: widgetDraft?.mapping,
          }
    setWidgetDraft(next)
    setWidgetSaving(true)
    proposePlannerGraphChange(canvasId, {
      summary: next
        ? `Set widget to ${next.kind} on ${node.title}`
        : `Clear widget on ${node.title}`,
      changes: [{ kind: 'updateNode', nodeId: node.id, widget: next }],
    })
      .then((proposal) => {
        setWidgetSaving(false)
        if (!proposal) {
          setWidgetError('服务端没返回提议')
          return
        }
        onProposalCreated?.(proposal)
      })
      .catch((err) => {
        setWidgetSaving(false)
        setWidgetError((err as Error).message || '保存失败')
      })
  }

  // ----- 操作 actions -----
  const [actionBusy, setActionBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)

  const runProposalAction = (
    work: () => Promise<PlanProposal | null>,
    closeAfter = false,
  ) => {
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
        if (closeAfter) onClose()
      })
      .catch((err) => {
        setActionBusy(false)
        setActionError((err as Error).message || '操作失败')
      })
  }

  // upstream artifact 浅链接(来自 input snapshot 是后端能力,目前 PlanningNode
  // 没直接挂 inputSnapshot 字段 → 用 dependsOnNodeIds 作为来源摘要)。
  const upstreamNodeIds = node.dependsOnNodeIds ?? []

  return (
    <>
      {/* Header 区 — state badge + title。复用现有 NodeInspectorModal CSS。 */}
      <div className="planner-node-modal__header">
        <div className="planner-node-modal__header-tags">
          {!isTemplate && (
            <span className={`planner-node-modal__state planner-node-modal__state--${runState}`}>
              {runStateToBadge(String(runState))}
            </span>
          )}
          {/* theta — pending review badge + Promote button. Only renders for
              the active artifact when its reviewStatus is 'pending'. */}
          {!isTemplate && isReviewPending && activeArtifact && (
            <>
              <span
                className="planner-node-modal__state planner-node-modal__state--blocked"
                title="此产物尚未被 owner 提升为正式版本,下游消费者会回退到上一份 approved 产物。"
              >
                待审核
              </span>
              <button
                type="button"
                className="planner-node-modal__attach-data-source-button"
                disabled={promoting}
                onClick={handlePromoteArtifact}
                title="把这份产物提升为 approved,下游 widget / resolver 会切到这一份"
              >
                <Sparkles size={12} aria-hidden />
                {promoting ? ' 提升中…' : ' Promote'}
              </button>
            </>
          )}
        </div>
        <h2>{node.title}</h2>
      </div>

      {/* 状态行:blockers chip(仅在有 blockers 时显示) */}
      {blockers.length > 0 && (
        <div className="planner-node-modal__blockers">
          {blockers.map((blocker) => (
            <span key={blocker}>
              <AlertTriangle size={12} aria-hidden />
              {blocker}
            </span>
          ))}
        </div>
      )}

      {/* 数据来源 picker — design spec ui_surface.inspector_picker.
          chip 3-option (authored / aggregated / mirrored), auto-save. */}
      <div className="planner-node-modal__section">
        <h3>
          <Database size={13} aria-hidden /> 数据来源
          {dataSourceSaving && <em className="planner-node-modal__view-saving">保存中…</em>}
          {dataSourceError && (
            <em className="planner-node-modal__view-error" title={dataSourceError}>
              !
            </em>
          )}
        </h3>
        <div className="planner-node-modal__widget-kind-chips">
          {ARTIFACT_DATA_SOURCE_OPTIONS.map((option) => {
            const selected = option.mode === dataSourceDraft
            return (
              <button
                key={option.mode}
                type="button"
                className={`planner-node-modal__widget-kind-chip${selected ? ' is-selected' : ''}`}
                disabled={dataSourceSaving}
                onClick={() => handlePickDataSource(option.mode)}
                title={option.tooltip}
              >
                {option.label}
              </button>
            )
          })}
        </div>
        <div className="planner-node-modal__view-hint">
          {describeDataSourceMode(dataSourceDraft)}
        </div>
        {dataSourceDraft === 'mirrored' && (
          <div className="planner-node-modal__attach-data-source">
            {/* 已绑定 — 列出每行 connector + ref + sync 状态,
                提供「刷新」+「替换 / 解绑」入口。完全复用 step 节点
                的 input.external[] 形状 (NodeContractExternalInput)。 */}
            {externalBindings.length > 0 ? (
              <ul className="planner-input-card__external-list">
                {externalBindings.map((row, index) => (
                  <li
                    key={`${row.connector}:${row.ref}:${index}`}
                    className="planner-input-card__external-row"
                  >
                    <span
                      className="planner-input-card__external-ref"
                      title={`${row.connector}:${row.ref}`}
                    >
                      <strong>{row.connector}</strong>
                      <em>{row.ref}</em>
                    </span>
                    {onRefreshExternalInput && (
                      <button
                        type="button"
                        className="planner-node-modal__attach-data-source-button"
                        title={`Refresh ${row.connector} ${row.ref}`}
                        aria-label={`Refresh ${row.connector} ${row.ref}`}
                        onClick={() => onRefreshExternalInput(node.id, row)}
                      >
                        <RefreshCw size={11} aria-hidden /> 刷新
                      </button>
                    )}
                    {onAttachDataSource && (
                      <button
                        type="button"
                        className="planner-node-modal__attach-data-source-button"
                        title="替换 / 重新绑定外部来源"
                        onClick={() => onAttachDataSource(node.id)}
                      >
                        <Plug size={11} aria-hidden /> 替换
                      </button>
                    )}
                  </li>
                ))}
              </ul>
            ) : null}
            {onAttachDataSource ? (
              <button
                type="button"
                className="planner-node-modal__attach-data-source-button"
                onClick={() => onAttachDataSource(node.id)}
                title="绑定外部 integration 作为镜像来源 — 复用 step 节点的 AttachDataSourcePopover"
              >
                <Plug size={12} aria-hidden />
                {externalBindings.length > 0 ? ' 追加来源' : ' Attach data source'}
              </button>
            ) : (
              <p className="planner-node-modal__empty">
                Attach data source 入口未挂载(parent 没传 onAttachDataSource)。
              </p>
            )}
            {/* 「立即同步」按钮已删 (2026-05-28):
                mirrored 改用 pull-on-consume snapshot 模型 — 下游 session/step
                消费此 artifact 时,server 即时拉 + 冻 version。无需手动 / 周期
                refresh。这跟 step/session 的 input.external[].sync_session
                snapshot pattern 是同一抽象。 */}
            <p className="planner-node-modal__view-hint">
              💡 也可以让 meee2 AI 帮你配 — 在节点对话里说"接 Notion 的 X 文档"之类,
              AI 会 propose <code>setArtifactDataSource</code> 把绑定写好。
            </p>
          </div>
        )}
      </div>

      {/* 产物预览 / 编辑区 — artifact 节点核心 */}
      <div className="planner-node-modal__section planner-node-modal__artifact-body">
        <h3>
          <FileText size={13} aria-hidden /> 产物
          {canEditPayload && (
            <button
              type="button"
              className="planner-node-modal__artifact-edit-toggle"
              onClick={() => setEditMode((v) => !v)}
              title={editMode ? '回到预览' : '编辑这份产物'}
            >
              <Pencil size={11} aria-hidden /> {editMode ? '预览' : '编辑'}
            </button>
          )}
        </h3>
        {activeArtifact ? (
          <PayloadBodySwitch
            artifact={activeArtifact}
            editMode={editMode && canEditPayload}
          />
        ) : dataSourceDraft === 'authored' ? (
          /* authored + no artifact: 真的可写的内嵌编辑器(2026-05-29 补)。
             保存后调 attachArtifact 创建第一份 markdown 产物;widget=inbox 时
             placeholder 提示"每行一条想法",将来加专用 inbox-items 编辑器。 */
          <AuthoredFirstArtifactEditor
            node={node}
            canvasId={canvasId}
            onCreated={onProposalCreated}
            toast={toast}
          />
        ) : (
          <div className="planner-node-modal__empty planner-node-modal__empty-state-hint">
            <p style={{ marginBottom: 6 }}>这是个镜像外部数据源的 artifact 节点,还没绑定来源。</p>
            <p style={{ opacity: 0.85 }}>
              下面 <strong>Attach data source</strong> 按钮选一个 integration(Notion / Linear / GitHub 等),
              下游节点消费时会自动拉最新数据 + 冻一份快照。
            </p>
          </div>
        )}
      </div>

      {/* 版本 (VersionTimeline) */}
      {nodeArtifacts.length >= 1 && (
        <div className="planner-node-modal__section">
          <h3>
            <GitCompare size={13} aria-hidden /> 版本
          </h3>
          <VersionTimeline
            artifacts={nodeArtifacts}
            activeId={activeArtifact?.id ?? null}
            onPick={(id) => setSelectedArtifactId(id)}
          />
        </div>
      )}

      {/* 来源 (SourceLineagePanel) */}
      {upstreamNodeIds.length > 0 && (
        <div className="planner-node-modal__section">
          <h3>
            <Route size={13} aria-hidden /> 来源
          </h3>
          <SourceLineagePanel upstreamNodeIds={upstreamNodeIds} />
        </div>
      )}

      {/* 卡片样式 — widget chip popover(收窄 allowed chips) */}
      <div className="planner-node-modal__group-label" ref={widgetPopoverRef}>
        <span>卡片样式</span>
        <small>artifact 节点的画板呈现</small>
        <span className="planner-node-modal__widget-summary">
          {describeArtifactWidget(widgetDraft)}
        </span>
        <button
          type="button"
          className={`planner-node-modal__widget-toggle${widgetPopoverOpen ? ' is-open' : ''}`}
          onClick={(event) => {
            event.stopPropagation()
            setWidgetPopoverOpen((open) => !open)
          }}
          aria-expanded={widgetPopoverOpen}
          aria-label="调整卡片样式"
          title="调整卡片样式"
        >
          <Settings2 size={12} aria-hidden />
        </button>
        {widgetPopoverOpen && (
          <div className="planner-node-modal__widget-popover" role="dialog" aria-label="卡片样式">
            <div className="planner-node-modal__widget-popover-header">
              <Eye size={12} aria-hidden /> 样式
              {widgetSaving && <em className="planner-node-modal__view-saving">保存中…</em>}
              {widgetError && (
                <em className="planner-node-modal__view-error" title={widgetError}>
                  !
                </em>
              )}
            </div>
            <div className="planner-node-modal__widget-kind-chips">
              {ARTIFACT_WIDGET_OPTIONS.map((option) => {
                const selected =
                  option.kind === 'standard'
                    ? widgetDraft == null
                    : widgetDraft?.kind === option.kind
                return (
                  <button
                    key={option.kind}
                    type="button"
                    className={`planner-node-modal__widget-kind-chip${selected ? ' is-selected' : ''}`}
                    disabled={widgetSaving}
                    onClick={() => handlePickWidgetKind(option.kind)}
                    title={option.tooltip}
                  >
                    {option.label}
                  </button>
                )
              })}
            </div>
            <div className="planner-node-modal__view-hint">
              {describeArtifactWidget(widgetDraft)}
            </div>
          </div>
        )}
      </div>

      {/* 操作 (ArtifactActionsBar) */}
      <div className="planner-node-modal__section">
        <h3>
          <Sparkles size={13} aria-hidden /> 操作
        </h3>
        <div className="planner-node-actions__buttons">
          {canEditPayload && (
            <button
              type="button"
              disabled={actionBusy}
              onClick={() => setEditMode((v) => !v)}
              title="切换预览 / 编辑"
            >
              <Pencil size={12} aria-hidden /> {editMode ? '回到预览' : '编辑产物'}
            </button>
          )}
          {latestArtifact && (
            <button
              type="button"
              disabled={actionBusy}
              title="把这份产物提升为独立子画板"
              onClick={() => {
                runProposalAction(
                  () =>
                    proposePlannerGraphChange(canvasId, {
                      summary: `Promote ${node.title} to sub-canvas`,
                      // positionTag 提升语义放到 attachArtifact 的 status / payload。
                      // 这里没有 attachArtifact 的全 payload 入口,先用 updateNode
                      // 把 widget 切到 artifact-preview 兜住「promoted」语义,
                      // 真正的 positionTag 写入由 agent / runtime 完成。
                      changes: [
                        {
                          kind: 'updateNode',
                          nodeId: node.id,
                          subCanvasId: node.subCanvasId ?? null,
                        },
                      ],
                    }),
                  true,
                )
              }}
            >
              <ArrowUpRight size={12} aria-hidden /> 提升为子画板
            </button>
          )}
          {nodeArtifacts.length > 1 && (
            <button
              type="button"
              disabled={actionBusy}
              title="从历史版本里挑一份晋升为最新"
              onClick={() => {
                // v0.1 — 切换主预览到下一份历史 artifact,真实的「latest 指针迁移」
                // 由 runtime 处理(submit_node_output force_new_version)。
                const idx = nodeArtifacts.findIndex((a) => a.id === activeArtifact?.id)
                const next = nodeArtifacts[(idx + 1) % nodeArtifacts.length]
                if (next) setSelectedArtifactId(next.id)
              }}
            >
              <RefreshCw size={12} aria-hidden /> 换一份
            </button>
          )}
          {latestArtifact && (
            <button
              type="button"
              className="planner-node-actions__danger"
              disabled={actionBusy}
              title="标记当前版本为 discarded,产物不会再被引用"
              onClick={() => {
                runProposalAction(
                  () =>
                    proposePlannerGraphChange(canvasId, {
                      summary: `Discard latest artifact on ${node.title}`,
                      // 真正的 positionTag 写入由 runtime / agent 完成。
                      // 这里用 updateNode + status 兜底,告知 agent「这份不要了」。
                      changes: [
                        {
                          kind: 'updateNode',
                          nodeId: node.id,
                          status: 'blocked',
                        },
                      ],
                    }),
                  false,
                )
              }}
            >
              <Trash2 size={12} aria-hidden /> 丢弃
            </button>
          )}
          {upstreamNodeIds.length > 0 && onRerunNode && (
            <button
              type="button"
              disabled={actionBusy}
              title="重新发起上游 step,为该产物新建一个版本"
              onClick={() => {
                onRerunNode(node.id, latestArtifact?.reference)
              }}
            >
              <RefreshCw size={12} aria-hidden /> 重新发起生产
            </button>
          )}
        </div>
        {actionError && <p className="planner-node-actions__error">{actionError}</p>}
      </div>

      {/* 版本与足迹 (FootprintTimeline) */}
      <div className="planner-node-modal__group-label planner-node-modal__group-label--footprint">
        <span>版本与足迹</span>
        <small>footprint · 版本链 + 上游会话</small>
      </div>
      <div className="planner-node-modal__section planner-node-modal__footprint">
        <FootprintTimeline
          artifacts={nodeArtifacts}
          node={node}
          onOpenSession={onOpenSession}
          onClose={onClose}
        />
      </div>
    </>
  )
}

// ---------------------------------------------------------------------------
// AuthoredFirstArtifactEditor (2026-05-29) — 内嵌"写第一份产物"编辑器。
//
// 触发条件:nodeKind=artifact + dataSource=authored + 还没产物。
// 用户在 textarea 写完点保存,走 attachArtifact PlanChange 创建 markdown 产物。
//
// widget=inbox 时 placeholder 改成"每行一条想法",但实际还是落 markdown payload
// (将来加专用 inbox-items 编辑器再 dispatch)。reviewStatus 默认 approved
// (用户手填的内容不需要再走 pending review)。
// ---------------------------------------------------------------------------
function AuthoredFirstArtifactEditor({
  node,
  canvasId,
  onCreated,
  toast,
}: {
  node: PlanningNode
  canvasId: string
  onCreated?: (proposal: PlanProposal) => void
  toast: { push: (kind: 'success' | 'error' | 'info', msg: string) => void }
}) {
  const widgetKind = node.widget?.kind
  const placeholder =
    widgetKind === 'inbox'
      ? '每行一条想法,保存后会成为收件箱的第一批'
      : widgetKind === 'kanban'
        ? '简单写一段内容,看板列结构后续在节点详情里调整'
        : '直接在这里写,保存后成为这个节点的第一份产物'
  const [content, setContent] = useState('')
  const [saving, setSaving] = useState(false)

  const handleSave = () => {
    const text = content.trim()
    if (!text || saving) return
    setSaving(true)
    const preview = text.length > 200 ? `${text.slice(0, 200)}…` : text
    const payload = {
      type: 'markdown' as const,
      preview,
      // legacy 兼容:也写一份 content,backend payload 是 BoardJSONValue,前端读
      // 回 payload 时可以从这里拿全文。
      content: text,
    }
    proposePlannerGraphChange(canvasId, {
      summary: `New content for ${node.title}`,
      changes: [
        {
          kind: 'attachArtifact',
          nodeId: node.id,
          artifact: {
            kind: 'generic',
            title: node.title,
            reference: `inline:${node.id}`,
            status: 'attached',
            payload,
            reviewStatus: 'approved',
          },
        },
      ],
    })
      .then((proposal) => {
        setSaving(false)
        if (!proposal) {
          toast.push('error', '保存失败:服务端没返回提议')
          return
        }
        onCreated?.(proposal)
        setContent('')
        toast.push('success', '产物已创建')
      })
      .catch((err) => {
        setSaving(false)
        toast.push('error', `保存失败:${(err as Error).message || '未知错误'}`)
      })
  }

  return (
    <div className="planner-node-modal__empty-editor">
      <textarea
        className="planner-node-modal__empty-editor-textarea"
        value={content}
        onChange={(e) => setContent(e.target.value)}
        placeholder={placeholder}
        rows={6}
        disabled={saving}
      />
      <div className="planner-node-modal__empty-editor-footer">
        <span className="planner-node-modal__empty-editor-hint">
          保存后会作为第一份 artifact 落到这个节点的版本链
        </span>
        <button
          type="button"
          className="planner-node-modal__attach-data-source-button"
          onClick={handleSave}
          disabled={!content.trim() || saving}
        >
          {saving ? '保存中…' : '保存'}
        </button>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// PayloadBodySwitch — 按 ArtifactPayload.type 分发到对应 viewer / editor。
// ---------------------------------------------------------------------------
function PayloadBodySwitch({
  artifact,
  editMode,
}: {
  artifact: PlannerArtifact | null
  editMode: boolean
}) {
  if (!artifact) {
    return <p className="planner-node-modal__empty">这个节点还没有产出</p>
  }
  const typed = artifact.typedPayload
  if (typed) {
    if (editMode) {
      switch (typed.type) {
        case 'markdown':
          return <MarkdownPayloadEditor payload={typed} />
        case 'prd':
          return <MarkdownPayloadEditor payload={{ type: 'markdown', preview: typed.tldr }} />
        case 'kanban':
          return <KanbanPayloadEditor payload={typed} />
      }
    }
    return <TypedPayloadPreview payload={typed} />
  }
  // 旧 PlannerArtifactPayloadType 兜底 — text / html / json / file。
  return <LegacyPayloadPreview artifact={artifact} />
}

// ---------------------------------------------------------------------------
// TypedPayloadPreview — 局部副本(与 ArtifactsView 同语义,避免再导出 internal)。
// ---------------------------------------------------------------------------
function TypedPayloadPreview({ payload }: { payload: ArtifactPayload }) {
  switch (payload.type) {
    case 'prd':
      return (
        <div className="artifacts-typed-payload artifacts-typed-payload--prd">
          <div className="artifacts-typed-payload__tldr">{payload.tldr}</div>
          <ul className="artifacts-typed-payload__sections">
            {payload.sections.map((s) => (
              <li key={s.heading}>
                <strong>{s.heading}</strong>
                <em>{s.lines} 行</em>
              </li>
            ))}
          </ul>
        </div>
      )
    case 'kanban':
      return (
        <div className="artifacts-typed-payload artifacts-typed-payload--kanban">
          {payload.columns.map((col) => (
            <div key={col.name} className="artifacts-typed-payload__kanban-col">
              <header>
                <span>{col.name}</span>
                <em>{col.items.length}</em>
              </header>
              {col.items.slice(0, 5).map((item) => (
                <div key={item} className="artifacts-typed-payload__kanban-item">
                  {item}
                </div>
              ))}
              {col.items.length > 5 && (
                <div className="artifacts-typed-payload__kanban-more">
                  +{col.items.length - 5}
                </div>
              )}
            </div>
          ))}
        </div>
      )
    case 'impl-pr':
      return (
        <div className="artifacts-typed-payload artifacts-typed-payload--pr">
          <div className="artifacts-typed-payload__pr-line">
            <strong>#{payload.number}</strong>
            <code>{payload.branch}</code>
            <span>← {payload.baseBranch}</span>
          </div>
          <div className="artifacts-typed-payload__pr-stats">
            <strong>{payload.filesChanged}</strong> files ·
            <span className="artifacts-typed-payload__pr-add"> +{payload.insertions}</span> ·
            <span className="artifacts-typed-payload__pr-del"> −{payload.deletions}</span>
          </div>
          <div className={`artifacts-typed-payload__ci is-${payload.ciStatus}`}>
            CI {payload.ciStatus}
          </div>
          <div className="artifacts-typed-payload__pr-reviewers">
            评审 · {payload.reviewers.join(', ') || '(无)'}
          </div>
        </div>
      )
    case 'check-result':
      return (
        <div className="artifacts-typed-payload artifacts-typed-payload--check">
          <div className="artifacts-typed-payload__check-pills">
            <span className="is-pass">{payload.pass} pass</span>
            <span className="is-fail">{payload.fail} fail</span>
            <span className="is-skip">{payload.skip} skip</span>
          </div>
          {payload.failing.length > 0 && (
            <ul className="artifacts-typed-payload__failing">
              {payload.failing.slice(0, 5).map((f) => (
                <li key={f}>✗ {f}</li>
              ))}
            </ul>
          )}
        </div>
      )
    case 'file':
      return (
        <dl className="artifacts-typed-payload artifacts-typed-payload--file">
          <div>
            <dt>filename</dt>
            <dd>{payload.filename}</dd>
          </div>
          <div>
            <dt>mime</dt>
            <dd>{payload.mime}</dd>
          </div>
          <div>
            <dt>size</dt>
            <dd>{formatBytesPlain(payload.sizeBytes)}</dd>
          </div>
          {payload.lines != null && (
            <div>
              <dt>lines</dt>
              <dd>{payload.lines}</dd>
            </div>
          )}
        </dl>
      )
    case 'markdown':
      return (
        <pre className="artifacts-typed-payload artifacts-typed-payload--markdown">
          {payload.preview}
        </pre>
      )
    case 'integration':
      return (
        <div className="artifacts-typed-payload artifacts-typed-payload--integration">
          <div className="artifacts-typed-payload__integration-line">
            <strong>{payload.connector}</strong>
            <code>{payload.externalId}</code>
          </div>
          {payload.externalUrl && (
            <a href={payload.externalUrl} target="_blank" rel="noopener noreferrer">
              {payload.externalUrl}
            </a>
          )}
          {payload.summary && (
            <div className="artifacts-typed-payload__integration-summary">
              {payload.summary}
            </div>
          )}
        </div>
      )
  }
}

// ---------------------------------------------------------------------------
// LegacyPayloadPreview — 旧 PlannerArtifactPayloadType(text / html / json / file)
// 走只读 fallback,不走编辑器。
// ---------------------------------------------------------------------------
function LegacyPayloadPreview({ artifact }: { artifact: PlannerArtifact }) {
  const payload = artifact.payload
  if (payload == null) {
    return <p className="planner-node-modal__empty">这份产物没附带可预览的内容</p>
  }
  if (typeof payload === 'string') {
    return <pre className="artifacts-preview">{payload}</pre>
  }
  try {
    return <pre className="artifacts-preview">{JSON.stringify(payload, null, 2)}</pre>
  } catch {
    return <pre className="artifacts-preview">{String(payload)}</pre>
  }
}

// ---------------------------------------------------------------------------
// MarkdownPayloadEditor — v0.1 朴素 textarea 编辑器。
//   - 不挂任何 ProseMirror / lexical 依赖(约束:不引入新依赖)
//   - onChange 暂时只更新本地 state;真实保存走 agent submit_node_output。
// ---------------------------------------------------------------------------
function MarkdownPayloadEditor({ payload }: { payload: { type: 'markdown'; preview: string } }) {
  const [value, setValue] = useState(payload.preview)
  return (
    <div className="planner-node-modal__payload-editor">
      <textarea
        className="planner-node-modal__payload-editor-textarea"
        value={value}
        onChange={(e) => setValue(e.target.value)}
        rows={12}
        placeholder="编辑 markdown 产物 — 保存请回到对话发指令"
      />
      <p className="planner-node-modal__empty">
        v0.1 — 编辑后请在对话里告诉 agent「写回这份产物」;后续版本会接 submit_node_output。
      </p>
    </div>
  )
}

// ---------------------------------------------------------------------------
// KanbanPayloadEditor — v0.1 列 / 卡片只读编辑面板(加列 / 加卡片占位)。
// 拖拽留 v0.2。
// ---------------------------------------------------------------------------
function KanbanPayloadEditor({
  payload,
}: {
  payload: { type: 'kanban'; columns: Array<{ name: string; items: string[] }> }
}) {
  const [columns, setColumns] = useState(payload.columns)
  return (
    <div className="planner-node-modal__payload-editor planner-node-modal__payload-editor--kanban">
      {columns.map((col, ci) => (
        <div key={col.name} className="artifacts-typed-payload__kanban-col">
          <header>
            <input
              type="text"
              value={col.name}
              onChange={(e) => {
                const next = [...columns]
                next[ci] = { ...col, name: e.target.value }
                setColumns(next)
              }}
            />
            <em>{col.items.length}</em>
          </header>
          {col.items.map((item, ii) => (
            <input
              key={`${col.name}-${ii}`}
              type="text"
              className="planner-node-modal__payload-editor-item"
              value={item}
              onChange={(e) => {
                const next = [...columns]
                const items = [...col.items]
                items[ii] = e.target.value
                next[ci] = { ...col, items }
                setColumns(next)
              }}
            />
          ))}
          <button
            type="button"
            className="planner-node-modal__payload-editor-add"
            onClick={() => {
              const next = [...columns]
              next[ci] = { ...col, items: [...col.items, '新卡片'] }
              setColumns(next)
            }}
          >
            + 加卡片
          </button>
        </div>
      ))}
      <button
        type="button"
        className="planner-node-modal__payload-editor-add"
        onClick={() => setColumns([...columns, { name: '新列', items: [] }])}
      >
        + 加列
      </button>
      <p className="planner-node-modal__empty">
        v0.1 — 编辑后请在对话里告诉 agent「写回这份看板」;拖拽排序留 v0.2。
      </p>
    </div>
  )
}

// ---------------------------------------------------------------------------
// VersionTimeline — 横向 chip 行,每个 chip 显示 positionTag + 时间。
// ---------------------------------------------------------------------------
function VersionTimeline({
  artifacts,
  activeId,
  onPick,
}: {
  artifacts: PlannerArtifact[]
  activeId: string | null
  onPick: (id: string) => void
}) {
  return (
    <div className="planner-node-modal__version-timeline">
      {artifacts.map((art, idx) => {
        const isActive = art.id === activeId
        const tagLabel = positionTagLabel(art.positionTag ?? (idx === 0 ? 'latest' : 'candidate'))
        return (
          <button
            key={art.id}
            type="button"
            className={`planner-node-modal__version-chip${isActive ? ' is-active' : ''}`}
            title={`${tagLabel} · ${formatDateShort(art.createdAt)}`}
            onClick={() => onPick(art.id)}
          >
            <strong>{tagLabel}</strong>
            <em>v{artifacts.length - idx}</em>
            <span>{formatDateShort(art.createdAt)}</span>
          </button>
        )
      })}
    </div>
  )
}

// ---------------------------------------------------------------------------
// SourceLineagePanel — 上游依赖浅链接 + dialogue snapshot 摘要(只读)。
// ---------------------------------------------------------------------------
function SourceLineagePanel({ upstreamNodeIds }: { upstreamNodeIds: string[] }) {
  return (
    <div className="planner-node-modal__lineage">
      {upstreamNodeIds.map((id) => (
        <span key={id} className="planner-node-modal__lineage-chip">
          <Layers size={11} aria-hidden /> 上游 · {id.slice(0, 8)}
        </span>
      ))}
    </div>
  )
}

// ---------------------------------------------------------------------------
// FootprintTimeline — 版本链 + 上游 session 链接占位。
// ---------------------------------------------------------------------------
function FootprintTimeline({
  artifacts,
  node,
  onOpenSession,
  onClose,
}: {
  artifacts: PlannerArtifact[]
  node: PlanningNode
  onOpenSession?: (sessionId: string, nodeId: string) => void
  onClose: () => void
}) {
  if (artifacts.length === 0) {
    return <p className="planner-node-modal__empty">(暂无足迹 — 版本链还没产生)</p>
  }
  return (
    <ul className="planner-node-modal__footprint-list">
      {artifacts.map((art, idx) => (
        <li key={art.id}>
          <Archive size={11} aria-hidden />
          <strong>{positionTagLabel(art.positionTag ?? (idx === 0 ? 'latest' : 'candidate'))}</strong>
          <em>v{artifacts.length - idx}</em>
          <span>{formatDateShort(art.createdAt)}</span>
        </li>
      ))}
      {node.sessionId && onOpenSession && (
        <li>
          <button
            type="button"
            className="planner-node-modal__open-session"
            onClick={() => {
              onOpenSession(node.sessionId!, node.id)
              onClose()
            }}
          >
            → 打开上游会话
          </button>
        </li>
      )}
    </ul>
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function describeDataSourceMode(mode: ArtifactDataSourceMode): string {
  switch (mode) {
    case 'authored':
      return '手填 · 这里直接写,节点自带 payload'
    case 'mirrored':
      return '接外部 · 绑 integration,下游消费时拉最新数据 + 冻一份快照'
  }
}

function describeArtifactWidget(widget: Widget | null): string {
  if (!widget) return '标准 · 显示节点本身(标题 / 状态)'
  switch (widget.kind) {
    case 'artifact-preview':
      return '产物预览 · 内嵌渲染产物正文'
    case 'kanban':
      return '看板 · 按列分组展示'
    case 'inbox':
      return '收件箱 · 按活动倒序'
    default:
      return widget.kind
  }
}

function positionTagLabel(tag: string): string {
  switch (tag) {
    case 'latest':
      return '最新'
    case 'candidate':
      return '候选'
    case 'discarded':
      return '已丢弃'
    case 'promoted':
      return '已提升'
    case 'proposed':
      return '提议中'
    default:
      return tag
  }
}

function formatDateShort(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function formatBytesPlain(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / (1024 * 1024)).toFixed(1)} MB`
}

// ---------------------------------------------------------------------------
// deriveExternalInputs — 复用 InputCardSections 的同名 helper 的语义,生成与
// step 节点 input.external[] 形状一致的行(NodeContractExternalInput)。在
// integration view-schema 落地前,bind 结果回显走 contextSources 的派生。
// 一旦 INT-2 把 NodeContractInput.external 直接写到 PlanningNode 上,这里就
// 直接 map node.input.external,无需 derive。
// ---------------------------------------------------------------------------
function deriveExternalInputs(node: PlanningNode): NodeContractExternalInput[] {
  // 1) 优先读已挂载的 input.external(后端真正存档的形状)
  const loose = node as unknown as {
    input?: { external?: Array<{ connector?: string; ref?: string; sync_session?: string | null }> }
  }
  const direct = loose.input?.external
  if (Array.isArray(direct) && direct.length > 0) {
    return direct
      .map((row): NodeContractExternalInput | null => {
        const connector = String(row?.connector ?? '').trim()
        const ref = String(row?.ref ?? '').trim()
        if (!connector || !ref) return null
        return { connector, ref, sync_session: row.sync_session ?? null }
      })
      .filter((row): row is NodeContractExternalInput => Boolean(row))
  }
  // 2) 兜底:与 InputCardSections.deriveExternalInputs 同语义 —— 从
  //    contextSources 取非 chatHistory 的项,scheme 推 connector slug。
  const sources = node.contextSources ?? []
  return sources
    .filter((source) => source.kind !== 'chatHistory')
    .map((source) => ({
      connector: connectorFromSource(source),
      ref: source.reference || source.title || 'unknown',
      sync_session: null,
    }))
}

function connectorFromSource(source: ContextSource): string {
  const ref = source.reference || ''
  const schemeMatch = ref.match(/^([a-z][a-z0-9+.-]*):/i)
  if (schemeMatch) return schemeMatch[1].toLowerCase()
  return source.kind
}

type BadgeState = '待办' | '运行中' | '等反馈' | '卡住' | '完成'
function runStateToBadge(runState: string): BadgeState {
  switch (runState) {
    case 'completed':
    case 'done':
      return '完成'
    case 'blocked':
    case 'failed':
    case 'error':
      return '卡住'
    case 'gate-wait':
    case 'awaiting-input':
    case 'awaiting-review':
      return '等反馈'
    case 'dispatched':
    case 'running':
    case 'in-progress':
    case 'thinking':
    case 'tooling':
      return '运行中'
    case 'ready_to_start':
    case 'todo':
    case 'pending':
    default:
      return '待办'
  }
}

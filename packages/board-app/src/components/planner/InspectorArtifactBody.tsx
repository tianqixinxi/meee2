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
  Eye,
  FileText,
  GitCompare,
  Layers,
  Pencil,
  RefreshCw,
  Route,
  Settings2,
  Sparkles,
  Trash2,
} from 'lucide-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import { proposePlannerGraphChange } from '../../api'
import type {
  ArtifactPayload,
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
}: Props) {
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
        <PayloadBodySwitch
          artifact={activeArtifact}
          editMode={editMode && canEditPayload}
        />
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

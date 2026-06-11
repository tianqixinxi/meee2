// UI-simplification — artifact-mode Inspector body.
//
// 当 nodeKind === 'artifact' 时,NodeInspectorModal 走这个分支,按
// 数据源 → 视图 → 预览 → 版本 → 来源 → 操作 的顺序渲染:
//   - 数据源(绑定事实,seed/mirrored 可配,执行产物只读)
//   - 视图(命名/派生 view 清单)
//   - 预览(ArtifactViewTabs / PayloadBodySwitch;版本行可把预览切到历史 snapshot)
//   - 版本(VersionChainList,真实 version 链 + snapshot 成因 + 上游会话链接)
//   - 来源(SourceLineagePanel,只读 lineage)
//   - 操作(ArtifactActionsBar,artifact-only 动作)
//
// step / session / subCanvas 路径走 NodeInspectorModal 主体不变,这里彻底隔离。

import {
  AlertTriangle,
  Archive,
  ArrowUpRight,
  Database,
  Eye,
  GitCompare,
  Layers,
  Pencil,
  Plug,
  RefreshCw,
  Route,
  Sparkles,
  Trash2,
} from 'lucide-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import { getPlannerArtifactContent, listArtifactVersions, proposePlannerGraphChange } from '../../api'
import { useToast } from '../../App'
import { resolvedArtifactPayload } from '../../lib/artifactPayload'
import { artifactToIntegrationEntity } from '../../integrations/artifactEntity'
import { getViewSchema } from '../../integrations/viewSchemas'
import { stableId } from './plannerGraphAdapter'
import { ArtifactViewTabs, resolveArtifactViews } from '../artifacts/ArtifactViewTabs'
import type {
  ArtifactPayload,
  ArtifactReviewStatus,
  ContextSource,
  NodeContractExternalInput,
  NodeStateSnapshot,
  PlanProposal,
  PlannerArtifact,
  PlannerArtifactContent,
  PlannerArtifactVersion,
  PlanningNode,
} from '../../types'

interface Props {
  node: PlanningNode
  canvasId: string
  variant: 'board' | 'template'
  /** PR #91 codex P2: artifact id to preselect when opening at a non-latest version. */
  initialSelectedArtifactId?: string | null
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
  // canvas-spec §7 unification: prefer the canonical unified `artifactSource`.
  //   - dataSource-kind        ⇒ 'mirrored'
  //   - slot / canvas-runtime  ⇒ 'authored'
  // Fall back to the legacy loose lookup for old data (one-release compat).
  if (node.artifactSource) {
    return node.artifactSource.kind === 'dataSource' ? 'mirrored' : 'authored'
  }
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

// canvas-spec §7.4 — authoring rule. An artifact is hand-fillable (authorable)
// ONLY when it is a source/seed: it has NO producing step (no upstream producer
// feeding the slot) and its role is to hold authored data (e.g. 想法收件箱,
// uploaded transcript, hand-written PRD). A step's OUTPUT artifact (execution
// product) must NOT be hand-fillable; inputs / canvas-runtime are read-only.
// 这是修「output 居然能手填」bug 的门。
//
// HEURISTIC (no explicit `Artifact.authorable` field exists yet — see TODO):
// treat a node as a seed-output (hand-fillable) only when it has NO upstream
// producer for its slot:
//   - dependsOnNodeIds 为空(edges 派生的上游依赖投影 —— 有上游 ⇒ 该 artifact
//     是执行产物,不能手填)
//   - schema.inputs 为空(声明了 input 槽 ⇒ 是 transform/execution 节点,消费
//     上游产物,不是种子)
//   - 没有绑定的外部 context source(chatHistory 除外 —— 那只是会话历史,不构成
//     上游 producer)
// 全满足才视为 source/seed。任何一条不满足 → 偏向「不显示手填编辑器」(spec
// §7.4 要求:对 step 节点带上游输入的明确 output,不该 authorable)。
//
// canvas-spec §7 unification (2026-05-29): the authoring gate now keys off the
// unified `Artifact.source` first. A `dataSource`-kind (mirrored / external)
// source is NEVER hand-fillable; a `canvas-runtime` source is read-only; only a
// seed/authored `slot` OUTPUT source is authorable. When the unified field is
// present we trust it directly (the backend already applied §7.4); otherwise we
// fall back to the legacy heuristic below for old data.
//
// TODO(spec §7.4): once the contract carries an explicit `Artifact.authorable`
// boolean we can drop both this `source`-derivation AND the heuristic and read
// the flag directly.
export function isSeedAuthorableNode(node: PlanningNode): boolean {
  if (node.artifactSource) {
    const src = node.artifactSource
    // dataSource mirror / canvas-runtime / input slot → not authorable.
    return src.kind === 'slot' && src.direction === 'output'
  }
  const hasUpstreamProducers = (node.dependsOnNodeIds ?? []).length > 0
  if (hasUpstreamProducers) return false
  const hasDeclaredInputs = (node.schema?.inputs ?? []).length > 0
  if (hasDeclaredInputs) return false
  const hasExternalContext = (node.contextSources ?? []).some(
    (source) => source.kind !== 'chatHistory',
  )
  if (hasExternalContext) return false
  return true
}

// canvas-spec §7 — an OUTPUT artifact is a step/session EXECUTION PRODUCT (or a
// canvas-runtime-derived Monitor): its payload is produced by an upstream
// producer, not chosen/bound here. The Inspector for such a node is a
// *visualization* surface (preview + versions + lineage), so the「数据来源」
// picker / Attach data source must NOT appear. By contrast a seed/source
// artifact (no upstream producer) legitimately offers「手填 vs 接外部」, and a
// mirrored `dataSource` artifact needs its binding managed — both stay bindable.
//
// 判定独立于 isSeedAuthorableNode:slot/output 这个 unified 信号分不开 seed-output
// 与 exec-output(两者都是 output 槽),真正的判别信号是「有没有上游 producer /
// 声明了 input 槽」—— 执行产物必然有,seed/mirrored 必然没有。
//   - canvas-runtime(Monitor 派生)           ⇒ output(不绑)
//   - dependsOnNodeIds 非空 / schema.inputs 非空 ⇒ 执行产物(不绑)
//   - 否则(seed / mirrored)                   ⇒ 可绑
export function isOutputArtifactNode(node: PlanningNode): boolean {
  if (node.artifactSource?.kind === 'canvas-runtime') return true
  const hasUpstreamProducers = (node.dependsOnNodeIds ?? []).length > 0
  const hasDeclaredInputs = (node.schema?.inputs ?? []).length > 0
  return hasUpstreamProducers || hasDeclaredInputs
}

/**
 * 从虚拟 io-artifact 节点 id 反推生产节点 id。
 * id 形如 `io-artifact-<producerId>-<direction>-<stableId(ref)>`,producerId
 * 与 ref slug 都含连字符,不能盲目正则切 — 用节点自己声明的 artifactRefs 逐个
 * 算出 slug 后从尾部精确剥离。非虚拟节点 / 剥离失败返回 null。
 */
export function virtualArtifactProducerId(node: PlanningNode): string | null {
  const prefix = 'io-artifact-'
  if (!node.id.startsWith(prefix)) return null
  const rest = node.id.slice(prefix.length)
  for (const ref of node.artifactRefs ?? []) {
    const slug = stableId(ref)
    for (const direction of ['output', 'input'] as const) {
      const suffix = `-${direction}-${slug}`
      if (rest.endsWith(suffix)) {
        const producerId = rest.slice(0, rest.length - suffix.length)
        if (producerId) return producerId
      }
    }
  }
  return null
}

export function InspectorArtifactBody({
  node,
  canvasId,
  variant,
  state,
  artifacts,
  initialSelectedArtifactId = null,
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
  //
  // 虚拟 io-artifact 节点(「查看输出」展开)的 id 是派生 id(io-artifact-…),
  // 而 artifact 挂在生产节点的 id 上 — 直接按 node.id 过滤永远是空,inspector
  // 退化成「手填空白编辑器 + 版本链还没产生」的假象。回退按 (生产节点 id +
  // reference) 匹配 — 槽位键本来就是二元组,只按 reference 全画布捞会让共享
  // 通用引用(report.md / output)的两个生产者互相串台。生产节点 id 从虚拟
  // id 精确剥离(用节点声明的 refs 反推 slug,见 virtualArtifactProducerId);
  // 剥不出来就不回退,宁可空也不串。
  const nodeArtifacts = useMemo(() => {
    const byNodeId = artifacts.filter((art) => art.nodeId === node.id)
    const refs = node.artifactRefs ?? []
    const producerId = virtualArtifactProducerId(node)
    const pool = byNodeId.length > 0
      ? byNodeId
      : producerId
        ? artifacts.filter((art) => art.nodeId === producerId && refs.includes(art.reference))
        : []
    return [...pool].sort((a, b) => {
      const ta = Date.parse(String(a.createdAt))
      const tb = Date.parse(String(b.createdAt))
      return (Number.isFinite(tb) ? tb : 0) - (Number.isFinite(ta) ? ta : 0)
    })
  }, [artifacts, node])
  const latestArtifact = nodeArtifacts[0] ?? null
  // 经 refs 回退匹配到的产物 = 由别的节点产出 → 这是执行产物的可视化面,
  // 数据来源配置器 / 手填编辑器一律不该出现(canvas-spec §7.4 的虚拟节点版)。
  const producedElsewhere = nodeArtifacts.length > 0 && nodeArtifacts.every((a) => a.nodeId !== node.id)

  // 用户点版本 chip → 主预览切换到那个版本;默认显示 latest。
  // PR #91 codex P2: initialize from prop when caller (card chip) requested a specific
  // version. Re-sync when prop changes (modal reopens at a different artifact).
  const [selectedArtifactId, setSelectedArtifactId] = useState<string | null>(initialSelectedArtifactId)
  useEffect(() => {
    setSelectedArtifactId(initialSelectedArtifactId)
  }, [initialSelectedArtifactId])
  const activeArtifact =
    nodeArtifacts.find((a) => a.id === selectedArtifactId) ?? latestArtifact
  const [contentByArtifactId, setContentByArtifactId] = useState<Record<string, PlannerArtifactContent | null>>({})
  useEffect(() => {
    if (!activeArtifact) return
    if (Object.prototype.hasOwnProperty.call(contentByArtifactId, activeArtifact.id)) return
    let cancelled = false
    getPlannerArtifactContent(canvasId, activeArtifact.id)
      .then((content) => {
        if (!cancelled) {
          setContentByArtifactId((current) => ({ ...current, [activeArtifact.id]: content }))
        }
      })
      .catch(() => {
        if (!cancelled) {
          setContentByArtifactId((current) => ({ ...current, [activeArtifact.id]: null }))
        }
      })
    return () => {
      cancelled = true
    }
  }, [activeArtifact, canvasId, contentByArtifactId])
  const activeArtifactContent = activeArtifact ? contentByArtifactId[activeArtifact.id] ?? undefined : undefined

  // 版本链 — 真实链来自 version 行(每次 submit / update_artifact 追加一条),
  // 不是 latest-per-slot 的 head 镜像。按产物自身的 nodeId 查(虚拟节点的
  // 派生 id 查不到链)。
  const [versionChain, setVersionChain] = useState<PlannerArtifactVersion[] | null>(null)
  useEffect(() => {
    if (!activeArtifact) {
      setVersionChain(null)
      return undefined
    }
    let cancelled = false
    listArtifactVersions(canvasId, activeArtifact.nodeId, activeArtifact.reference)
      .then((res) => {
        if (!cancelled) setVersionChain(res.versions ?? [])
      })
      .catch(() => {
        if (!cancelled) setVersionChain([])
      })
    return () => {
      cancelled = true
    }
  }, [activeArtifact, canvasId])

  // 版本回放 — 点版本行把「预览」切到那一版的 snapshot(payload_inline),
  // 再点一次或点「回到最新」复位。切换主产物(多槽位 chip)时也复位。
  const [selectedVersionId, setSelectedVersionId] = useState<string | null>(null)
  useEffect(() => {
    setSelectedVersionId(null)
  }, [activeArtifact?.id])
  const selectedVersion = useMemo(
    () => versionChain?.find((v) => v.version_id === selectedVersionId) ?? null,
    [versionChain, selectedVersionId],
  )
  const selectedVersionNumber = useMemo(() => {
    if (!selectedVersion || !versionChain) return null
    const idx = versionChain.findIndex((v) => v.version_id === selectedVersion.version_id)
    return idx >= 0 ? versionChain.length - idx : null
  }, [selectedVersion, versionChain])
  // 历史回放体:payload_inline 盖掉 head 的 payload/typedPayload。content(blob
  // 全文)属于 head,回放时不沿用 — 否则新内容串进旧版本。inline 缺失(纯 blob
  // 引用)时回放不出来,预览区给提示并继续显示最新。
  const selectedVersionHasInline = selectedVersion ? selectedVersion.payload_inline != null : false
  const previewArtifact = useMemo(() => {
    if (!activeArtifact || !selectedVersion || selectedVersion.payload_inline == null) {
      return activeArtifact
    }
    return { ...activeArtifact, payload: selectedVersion.payload_inline, typedPayload: null }
  }, [activeArtifact, selectedVersion])
  const previewingHistory = Boolean(selectedVersion) && selectedVersionHasInline

  // 视图清单 — 产物自带的命名视图(update_artifact_views 固化)或按 payload
  // 形状派生的默认视图。预览区(ArtifactViewTabs)渲染的就是这一组。
  const artifactViews = useMemo(
    () => (activeArtifact ? resolveArtifactViews(activeArtifact, activeArtifactContent ?? null) : []),
    [activeArtifact, activeArtifactContent],
  )
  const hasSavedViews = Boolean(activeArtifact?.views?.length)

  // canvas-spec §7.4 — only source/seed artifacts are hand-fillable. See
  // isSeedAuthorableNode above. Gates both the AuthoredFirstArtifactEditor and
  // the per-version 「编辑」 toggles: a step node with upstream inputs producing
  // an execution product → NOT authorable; its output renders read-only.
  const isSeedAuthorable = useMemo(() => isSeedAuthorableNode(node), [node]) && !producedElsewhere

  // canvas-spec §7 — OUTPUT artifact 的 Inspector 是**可视化**面,不绑数据源。
  // gate 下面整段「数据来源」picker / Attach data source(见 isOutputArtifactNode)。
  const isOutputArtifact = useMemo(() => isOutputArtifactNode(node), [node]) || producedElsewhere

  // artifact = 数据源(绑定)+ view:绑定事实从产物自身投影(integration
  // entity → connector / 外部链接 / fields),不依赖节点上的配置。
  const bindingEntity = useMemo(
    () => (latestArtifact ? artifactToIntegrationEntity(latestArtifact) : undefined),
    [latestArtifact],
  )
  const bindingSchema = useMemo(() => {
    if (!bindingEntity) return undefined
    const sep = bindingEntity.schemaId.indexOf(':')
    return sep > 0
      ? getViewSchema(bindingEntity.schemaId.slice(0, sep), bindingEntity.schemaId.slice(sep + 1))
      : undefined
  }, [bindingEntity])

  // 编辑切换(仅 markdown / prd / kanban 类型可编辑;v0.1 是占位 — 编辑器尚未上)。
  const [editMode, setEditMode] = useState(false)
  const activePayload: ArtifactPayload | null =
    activeArtifact ? resolvedArtifactPayload(activeArtifact, activeArtifactContent) : null
  // canvas-spec §7.4 — 编辑入口只对源/种子产物开放。非种子(step 执行产物)的
  // payload 即便是 markdown/prd/kanban,也只读,不给「编辑」toggle。
  const canEditPayload =
    isSeedAuthorable &&
    (activePayload?.type === 'markdown' ||
      activePayload?.type === 'prd' ||
      activePayload?.type === 'kanban')

  // theta (2026-05-29) — review gate. Source of truth is the artifact-level
  // reviewStatus; typedPayload.reviewStatus mirrors it for callers that only
  // see the payload envelope. Absence ≡ 'approved'.
  const activeReviewStatus =
    activeArtifact?.reviewStatus ?? activePayload?.reviewStatus ?? 'approved'
  const isReviewPending = activeReviewStatus === 'pending'
  const [reviewAction, setReviewAction] = useState<ArtifactReviewStatus | null>(null)
  const handleReviewArtifact = (nextReviewStatus: ArtifactReviewStatus) => {
    if (!activeArtifact || reviewAction) return
    setReviewAction(nextReviewStatus)
    // theta-fix (2026-05-29): codex P1 — the previous fallback overwrote
    // payload with `{ type: 'markdown', preview: '' }` when typedPayload
    // was absent, which is the common case for normal markdown/prd/file
    // artifacts coming through PlannerGraphStateEnvelope (only `.payload`
    // is sent on the wire). That clobbered the original content during
    // review. Fix: carry `reviewStatus` on the draft itself
    // (PlanArtifactDraft.reviewStatus, added to Swift + Zod schema), and
    // preserve the original `payload` byte-for-byte. Apply-path stamps
    // PlannerArtifact.reviewStatus from the draft field directly.
    proposePlannerGraphChange(canvasId, {
      summary: `${nextReviewStatus === 'approved' ? 'Approve' : 'Reject'} ${activeArtifact.title}`,
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
            reviewStatus: nextReviewStatus,
          },
        },
      ],
    })
      .then((proposal) => {
        setReviewAction(null)
        if (!proposal) {
          toast.push('error', '审核失败:服务端没返回提议')
          return
        }
        onProposalCreated?.(proposal)
        toast.push('success', `已提交审核提议:${activeArtifact.title}`)
      })
      .catch((err) => {
        setReviewAction(null)
        toast.push('error', `审核失败:${(err as Error).message || '未知错误'}`)
      })
  }


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
          {/* theta — pending review badge + review actions. Only renders for
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
                disabled={Boolean(reviewAction)}
                onClick={() => handleReviewArtifact('approved')}
                title="把这份产物提升为 approved,下游 widget / resolver 会切到这一份"
              >
                <Sparkles size={12} aria-hidden />
                {reviewAction === 'approved' ? ' 提交中…' : ' Approve'}
              </button>
              <button
                type="button"
                className="planner-node-modal__attach-data-source-button"
                disabled={Boolean(reviewAction)}
                onClick={() => handleReviewArtifact('rejected')}
                title="拒绝这份产物,下游 widget / resolver 会继续使用上一份 approved 产物"
              >
                <Trash2 size={12} aria-hidden />
                {reviewAction === 'rejected' ? ' 提交中…' : ' Reject'}
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

      {/* 1. 数据源 — artifact = 数据源(绑定)+ view。有产物时先回答
          「这份数据绑定在哪」:integration 投影出 connector / 外部链接 /
          关键事实,只读;非 integration 产物给出产出方式 + 引用。 */}
      {bindingEntity && latestArtifact ? (
        <div className="planner-node-modal__section">
          <h3>
            <Database size={13} aria-hidden /> 数据源
          </h3>
          <div className="planner-artifact-binding">
            <span className="planner-artifact-binding__connector">
              <Plug size={11} aria-hidden /> {bindingEntity.schemaId}
            </span>
            <BindingFacts entity={bindingEntity} />
            {bindingUrl(bindingEntity) ? (
              <a href={bindingUrl(bindingEntity)!} target="_blank" rel="noreferrer">
                {bindingUrl(bindingEntity)}
              </a>
            ) : (
              <code title="内部槽位引用 — 版本链按它归并">{latestArtifact.reference}</code>
            )}
            {bindingSchema && (
              <small className="planner-node-modal__view-hint">
                视图 schema:{bindingSchema.integrationId}:{bindingSchema.entityKind} · {bindingSchema.preview.summary}
              </small>
            )}
          </div>
        </div>
      ) : latestArtifact ? (
        <div className="planner-node-modal__section">
          <h3>
            <Database size={13} aria-hidden /> 数据源
          </h3>
          <div className="planner-artifact-binding">
            <span className="planner-artifact-binding__connector">
              {isOutputArtifact ? '上游执行产物 — 由 step/会话产出,只读' : '手填种子 — 本节点自带 payload'}
            </span>
            <code title="槽位引用 — 版本链按它归并">{latestArtifact.reference}</code>
          </div>
        </div>
      ) : null}

      {/* 数据来源 picker — design spec ui_surface.inspector_picker.
          chip 2-option (authored / mirrored), auto-save.
          canvas-spec §7 — OUTPUT artifact 是可视化面、不绑数据源:这段只对
          **还没有产物**的 seed/mirrored artifact 节点渲染(配置态)。 */}
      {!isOutputArtifact && !latestArtifact && (
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
      )}

      {/* 2. 视图 — 这份数据有哪些投影。命名视图由 agent 经 update_artifact_views
          固化;没有命名视图时按 payload 形状派生(Integration / Table / Raw …)。
          预览区渲染的 tab 即这一组。 */}
      {activeArtifact && artifactViews.length > 0 && (
        <div className="planner-node-modal__section">
          <h3>
            <Layers size={13} aria-hidden /> 视图
          </h3>
          <div className="planner-node-modal__widget-kind-chips">
            {artifactViews.map((item) => (
              <span
                key={item.view.id}
                className="planner-node-modal__widget-kind-chip is-selected"
                title={`kind: ${item.view.kind}`}
              >
                {item.view.title}
              </span>
            ))}
          </div>
          <div className="planner-node-modal__view-hint">
            {hasSavedViews
              ? '产物自带的命名视图(update_artifact_views 写入,跨卡片/检查器/产物库一致)。'
              : '按 payload 形状派生的默认视图 — agent 可用 update_artifact_views 固化命名视图。'}
          </div>
        </div>
      )}

      {/* 3. 预览 — artifact 节点核心(按视图 tab 渲染) */}
      <div className="planner-node-modal__section planner-node-modal__artifact-body">
        <h3>
          <Eye size={13} aria-hidden /> 预览
          {canEditPayload && !previewingHistory && (
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
        {/* 版本回放横幅 — 预览正显示历史 snapshot,提醒 + 一键回到最新。 */}
        {previewingHistory && (
          <div className="planner-node-modal__version-replay-banner">
            <span>
              正在回放历史版本{selectedVersionNumber != null ? ` v${selectedVersionNumber}` : ''} 的快照
            </span>
            <button type="button" onClick={() => setSelectedVersionId(null)}>
              回到最新
            </button>
          </div>
        )}
        {/* 选了版本但没有内联快照(payload 只剩 blob 引用)— 回放不出来,如实说。 */}
        {selectedVersion && !selectedVersionHasInline && (
          <div className="planner-node-modal__version-replay-banner is-missing">
            <span>这一版没有内联快照,无法回放 — 下面显示的仍是最新内容</span>
            <button type="button" onClick={() => setSelectedVersionId(null)}>
              知道了
            </button>
          </div>
        )}
        {previewArtifact && (
          <PayloadBodySwitch
            artifact={previewArtifact}
            content={previewingHistory ? undefined : activeArtifactContent}
            editMode={editMode && canEditPayload && !previewingHistory}
          />
        )}
        {/* authored 模式编辑器:不论是否已有产物,都保留(2026-05-29 fix Q3)。
            原先只在 !activeArtifact 时渲染 → 用户填完一次就锁死,inbox 类
            累积型场景完全用不了。现在改成"始终可写",每次保存追加新版本
            (后端按 reference 做 append-version)。

            canvas-spec §7.4 gate(2026-05-29):手填编辑器**仅对源/种子 artifact**
            渲染 —— `isSeedAuthorable`(无上游 producer / 无 input 槽 / 无外部
            context)为真时才显示。step 节点带上游输入产出的执行产物 → 不显示
            编辑器,上面的 PayloadBodySwitch 已经把 agent 产出的内容只读展示。
            这修掉「output 居然能手填」的 bug。 */}
        {dataSourceDraft === 'authored' && isSeedAuthorable && (
          <AuthoredFirstArtifactEditor
            node={node}
            canvasId={canvasId}
            hasExisting={Boolean(activeArtifact)}
            onCreated={onProposalCreated}
            toast={toast}
          />
        )}
        {/* canvas-spec §7.4 — authored 模式但非源/种子(step 执行产物):明确告诉
            用户这份产物由执行产生、不能手填,内容已在上方只读展示。避免用户以为
            「这里没编辑器是 bug」。 */}
        {dataSourceDraft === 'authored' && !isSeedAuthorable && (
          <p className="planner-node-modal__view-hint">
            这份产物由上游执行(step / 会话)产生,只能由 agent 写回,不能手填。
            完整内容见上方预览与下方「版本」。
          </p>
        )}
        {dataSourceDraft === 'mirrored' && !activeArtifact && (
          <div className="planner-node-modal__empty planner-node-modal__empty-state-hint">
            <p style={{ marginBottom: 6 }}>这是个镜像外部数据源的 artifact 节点,还没绑定来源。</p>
            <p style={{ opacity: 0.85 }}>
              下面 <strong>Attach data source</strong> 按钮选一个 integration(Notion / Linear / GitHub 等),
              下游节点消费时会自动拉最新数据 + 冻一份快照。
            </p>
          </div>
        )}
      </div>

      {/* 4. 版本 — 真实版本链(每次 submit / update_artifact 追加一条),
          含提交方与来源;多槽位时上方 chip 切换主预览。 */}
      {nodeArtifacts.length >= 1 && (
        <div className="planner-node-modal__section">
          <h3>
            <GitCompare size={13} aria-hidden /> 版本
            {versionChain != null && <em className="planner-node-modal__view-saving">共 {versionChain.length} 版</em>}
          </h3>
          {nodeArtifacts.length > 1 && (
            <VersionTimeline
              artifacts={nodeArtifacts}
              activeId={activeArtifact?.id ?? null}
              onPick={(id) => setSelectedArtifactId(id)}
            />
          )}
          <VersionChainList
            versions={versionChain}
            fallbackArtifacts={nodeArtifacts}
            sessionId={node.sessionId ?? null}
            nodeId={node.id}
            selectedVersionId={selectedVersionId}
            onSelectVersion={setSelectedVersionId}
            onOpenSession={onOpenSession}
            onClose={onClose}
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

    </>
  )
}

// 数据源绑定的关键事实(tab / rows / columns / updated …)— 来自
// artifactToIntegrationEntity 铺进 entity payload 的 typedPayload.fields。
function BindingFacts({ entity }: { entity: { payload: unknown } }) {
  const payload = entity.payload && typeof entity.payload === 'object' && !Array.isArray(entity.payload)
    ? entity.payload as Record<string, unknown>
    : null
  if (!payload) return null
  const facts = ['tab', 'rows', 'columns', 'updated']
    .map((key) => {
      const value = payload[key]
      if (typeof value === 'string' && value.trim()) return `${key} ${value}`
      if (typeof value === 'number' && Number.isFinite(value)) return `${key} ${value}`
      return null
    })
    .filter((item): item is string => Boolean(item))
  if (facts.length === 0) return null
  return <span className="planner-artifact-binding__facts">{facts.join(' · ')}</span>
}

function bindingUrl(entity: { payload: unknown }): string | null {
  const payload = entity.payload && typeof entity.payload === 'object' && !Array.isArray(entity.payload)
    ? entity.payload as Record<string, unknown>
    : null
  const url = payload?.url
  return typeof url === 'string' && url.trim() ? url : null
}

// snapshot 成因 — 这一版是怎么来的。判定优先级:
//   1. metadata.source === 'updateArtifact' → 直接写入(update_artifact MCP /
//      同步快照按钮派发的同步会话都走这条路)
//   2. metadata 带 title/kind/status(submit 路径随提交写的展示元数据)→ 节点提交
//   3. 兜底按提交方:integration → 外部同步;human → 人工提交;其余 → 节点提交
function versionCauseLabel(
  meta: Record<string, unknown> | null,
  submittedByKind: string,
): string {
  const source = typeof meta?.source === 'string' ? meta.source : null
  if (source === 'updateArtifact') return '直接更新(update_artifact / 同步)'
  if (source) return source
  if (meta && ('title' in meta || 'kind' in meta || 'status' in meta)) return '节点提交'
  if (submittedByKind === 'integration') return '外部同步'
  if (submittedByKind === 'human') return '人工提交'
  return '节点提交'
}

// 版本链列表 — 真实 version 行(submit / update_artifact 各追加一条)。
// 链还没回来(null)显示加载;空链回退显示 latest-per-slot head(老画布的
// attach 不写 version 行,head 至少证明产物存在)。
// 每行可点 — 点了把「预览」切到那一版的 snapshot,再点一次取消回放。
function VersionChainList({
  versions,
  fallbackArtifacts,
  sessionId,
  nodeId,
  selectedVersionId,
  onSelectVersion,
  onOpenSession,
  onClose,
}: {
  versions: PlannerArtifactVersion[] | null
  fallbackArtifacts: PlannerArtifact[]
  sessionId: string | null
  nodeId: string
  selectedVersionId: string | null
  onSelectVersion: (versionId: string | null) => void
  onOpenSession?: (sessionId: string, nodeId: string) => void
  onClose: () => void
}) {
  const openSessionRow = sessionId && onOpenSession && (
    <li>
      <button
        type="button"
        className="planner-node-modal__open-session"
        onClick={() => {
          onOpenSession(sessionId, nodeId)
          onClose()
        }}
      >
        → 打开上游会话
      </button>
    </li>
  )
  if (versions == null) {
    return <p className="planner-node-modal__empty">加载版本链…</p>
  }
  if (versions.length === 0) {
    if (fallbackArtifacts.length === 0) {
      return <p className="planner-node-modal__empty">(版本链为空 — 还没有任何提交)</p>
    }
    return (
      <ul className="planner-node-modal__footprint-list">
        {fallbackArtifacts.map((art, idx) => (
          <li key={art.id}>
            <Archive size={11} aria-hidden />
            <strong>{positionTagLabel(art.positionTag ?? (idx === 0 ? 'latest' : 'candidate'))}</strong>
            <span>{formatDateShort(art.createdAt)}</span>
          </li>
        ))}
        {openSessionRow}
      </ul>
    )
  }
  const submitterLabel: Record<string, string> = {
    agent: 'agent',
    human: '人工',
    system: '系统',
    integration: 'integration',
  }
  return (
    <ul className="planner-node-modal__footprint-list">
      {versions.map((version, idx) => {
        const meta = version.metadata && typeof version.metadata === 'object' && !Array.isArray(version.metadata)
          ? version.metadata as Record<string, unknown>
          : null
        const isSelected = version.version_id === selectedVersionId
        const hasInline = version.payload_inline != null
        return (
          <li key={version.version_id}>
            <button
              type="button"
              className={`planner-node-modal__version-row${isSelected ? ' is-active' : ''}`}
              onClick={() => onSelectVersion(isSelected ? null : version.version_id)}
              title={
                isSelected
                  ? '取消回放,回到最新'
                  : hasInline
                    ? '把预览切到这一版的快照'
                    : '这一版没有内联快照,无法回放预览'
              }
            >
              <Archive size={11} aria-hidden />
              <em>v{versions.length - idx}</em>
              <strong>{submitterLabel[version.submitted_by_kind] ?? version.submitted_by_kind}</strong>
              <span className="planner-artifact-binding__facts">
                {versionCauseLabel(meta, version.submitted_by_kind)}
              </span>
              <span>{formatDateShort(version.created_at)}</span>
            </button>
          </li>
        )
      })}
      {openSessionRow}
    </ul>
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
  hasExisting = false,
  onCreated,
  toast,
}: {
  node: PlanningNode
  canvasId: string
  /** 2026-05-29 Q3 fix:已有产物时占位文案换成「继续加」语义,允许累积编辑。 */
  hasExisting?: boolean
  onCreated?: (proposal: PlanProposal) => void
  toast: { push: (kind: 'success' | 'error' | 'info', msg: string) => void }
}) {
  const widgetKind = node.widget?.kind
  const placeholder = hasExisting
    ? widgetKind === 'inbox'
      ? '继续加想法,每行一条,保存后追加一个新版本'
      : widgetKind === 'kanban'
        ? '继续写内容,保存后追加一个新版本'
        : '继续写,保存后追加一个新版本'
    : widgetKind === 'inbox'
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
          {hasExisting
            ? '每次保存会在版本链上追加一份新版本(同 reference,append-only)'
            : '保存后会作为第一份 artifact 落到这个节点的版本链'}
        </span>
        <button
          type="button"
          className="planner-node-modal__attach-data-source-button"
          onClick={handleSave}
          disabled={!content.trim() || saving}
        >
          {saving ? '保存中…' : hasExisting ? '追加版本' : '保存'}
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
  content,
  editMode,
}: {
  artifact: PlannerArtifact | null
  content?: PlannerArtifactContent | null
  editMode: boolean
}) {
  if (!artifact) {
    return <p className="planner-node-modal__empty">这个节点还没有产出</p>
  }
  const typed = resolvedArtifactPayload(artifact, content ?? undefined)
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
    return <ArtifactViewTabs artifact={artifact} content={content} />
  }
  // 旧 PlannerArtifactPayloadType 兜底 — text / html / json / file。
  return <ArtifactViewTabs artifact={artifact} content={content} />
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

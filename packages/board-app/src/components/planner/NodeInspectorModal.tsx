import {
  AlertTriangle,
  ArrowDownLeft,
  ArrowUpRight,
  CalendarClock,
  ChevronDown,
  ExternalLink,
  FileText,
  Flag,
  History,
  Layers,
  RefreshCw,
  Route,
  Settings2,
  Sparkles,
  UserRound,
  X,
} from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import {
  listArtifactVersions,
  proposePlannerGraphChange,
  resolvePlannerNodeReview,
  submitHumanPlannerNodeOutput,
  updatePlannerNodeSchedule,
} from '../../api'
import { loadSpawnProvider } from '../../preferences'
import type { TeamMember } from '../../api'
import type {
  CanvasEdge,
  DataSourceRecord,
  Session,
  NodeContractExternalInput,
  NodeStateSnapshot,
  PlanProposal,
  PlannerAccess,
  PlannerArtifact,
  PlannerArtifactKind,
  PlannerArtifactVersion,
  PlannerDispatchRunner,
  PlannerGraphState,
  PlanningNode,
  PlanningNodeStatus,
} from '../../types'
import { InputCardSections } from './InputCardSections'
import { InspectorArtifactBody } from './InspectorArtifactBody'
import { NodeContributionsSection } from './NodeContributionsSection'
import { deriveDisplayStatus } from './labels'
import { visibleOutputReferences, type IOArtifactVisibility } from './plannerGraphAdapter'

interface Props {
  node: PlanningNode
  canvasId: string
  /** Canvas runtime 一类边 / 数据源 / 节点标题 —— 喂给输入面读真实 Edge/DataSource(否则回落旧派生)。 */
  canvasEdges?: CanvasEdge[]
  canvasDataSources?: DataSourceRecord[]
  nodeTitleById?: Record<string, string>
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
   *  that used to live on the node card). Surfaced as the single open-session
   *  button inside the 进展 runtime block (the duplicate hover-revealed link on
   *  the 进展 group label was removed). */
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
  /** UI-simplification 进展 — the live board session DTO bound to this node
   *  (matched by node.sessionId). Drives the 进展 live block: what the session
   *  is actually doing right now (currentTask / currentTool / lastActivity /
   *  recentMessages) instead of just a status dot. */
  boundSession?: Session | null
}

export function NodeInspectorModal({
  node,
  canvasId,
  canvasEdges,
  canvasDataSources,
  nodeTitleById,
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
  boundSession = null,
}: Props) {
  const [assignOpen, setAssignOpen] = useState(false)
  const [scheduleOpen, setScheduleOpen] = useState(false)
  const [replaceConfirmOpen, setReplaceConfirmOpen] = useState(false)
  // UI-simplification chunk G — Schedule / Replace session / Assign owner
  // 都属于 advanced action,默认折叠;首次打开 inspector 只显示「Expand sub-canvas」。
  const [advancedOpen, setAdvancedOpen] = useState(false)
  const [scheduleInterval, setScheduleInterval] = useState(() => String(Math.max(1, Math.round((node.schedule?.intervalSeconds ?? 900) / 60))))
  const [schedulePrompt, setSchedulePrompt] = useState(() => node.schedule?.prompt ?? defaultSchedulePrompt(node))
  const [actionBusy, setActionBusy] = useState(false)
  const [humanOutput, setHumanOutput] = useState('')
  const [reviewComment, setReviewComment] = useState('')
  const [reviewCorrection, setReviewCorrection] = useState('')
  const [reviewPanel, setReviewPanel] = useState<'none' | 'changes' | 'correct'>('none')
  const [reviewBusy, setReviewBusy] = useState(false)
  const [reviewError, setReviewError] = useState<string | null>(null)

  const submitHumanOutput = async () => {
    const summary = humanOutput.trim()
    if (!summary || reviewBusy) return
    setReviewBusy(true)
    setReviewError(null)
    const reference = node.schema.outputs[0] ?? 'human-output'
    try {
      const result = await submitHumanPlannerNodeOutput(canvasId, node.id, {
        nodeId: node.id,
        status: 'done',
        message: { summary, routeTo: [] },
        artifacts: node.schema.outputs.length > 0 ? [{
          kind: 'generic',
          title: reference,
          reference,
          payload: { type: 'text', text: summary },
          routeTo: [],
        }] : [],
        next: 'complete',
      })
      setHumanOutput('')
      onGraphStateChanged?.(result.graph)
    } catch (cause) {
      setReviewError(cause instanceof Error ? cause.message : '提交失败')
    } finally {
      setReviewBusy(false)
    }
  }

  const resolveReview = async (decision: 'approve' | 'request_changes', corrected = false) => {
    if (reviewBusy) return
    if (decision === 'request_changes' && !reviewComment.trim()) {
      setReviewError('要求修改时必须填写具体意见。')
      return
    }
    if (corrected && !reviewCorrection.trim()) {
      setReviewError('请填写修订后的产物内容。')
      return
    }
    setReviewBusy(true)
    setReviewError(null)
    try {
      const matchingArtifacts = artifacts.filter((artifact) => artifact.nodeId === node.id)
      const latest = matchingArtifacts[matchingArtifacts.length - 1]
      const reference = latest?.reference ?? node.schema.outputs[0] ?? 'human-review'
      const kind: PlannerArtifactKind = latest?.kind ?? 'generic'
      const state = await resolvePlannerNodeReview(canvasId, node.id, {
        decision,
        comment: decision === 'request_changes' ? reviewComment.trim() : undefined,
        correctedOutput: corrected ? {
          nodeId: node.id,
          status: 'needs_review',
          message: { summary: 'Human reviewer submitted a corrected version.', routeTo: [] },
          artifacts: [{
            kind,
            title: latest?.title ?? reference,
            reference,
            payload: { type: 'text', text: reviewCorrection.trim() },
            routeTo: [],
          }],
          next: 'needs_owner_review',
          force_new_version: true,
        } : undefined,
      })
      setReviewComment('')
      setReviewCorrection('')
      setReviewPanel('none')
      onGraphStateChanged?.(state)
    } catch (cause) {
      setReviewError(cause instanceof Error ? cause.message : '审核失败')
    } finally {
      setReviewBusy(false)
    }
  }
  const [actionError, setActionError] = useState<string | null>(null)
  // canvas-spec §8 — the widget ⚙ popover was removed from the inspector;
  // node-view selection is no longer surfaced here.
  const isTemplate = variant === 'template'
  const nodeKind = node.nodeKind ?? (node.source === 'session' ? 'session' : node.subCanvasId ? 'subCanvas' : 'step')
  // PR1 (running-session-visual) — inspector 头部 / 进展段徽章统一从 deriveDisplayStatus 派生,
  // 让 workflowRunState (running / awaiting / failed) 在 inspector 里也显式可见。
  // 不再走 state.runState → runStateToBadge,这条路径只能反映 design status,
  // running / awaiting 都会被吃成「待办」。
  const displayStatus = deriveDisplayStatus(node)
  // canvas-spec §8 — needsOwnerReview: gateWait parked awaiting a human
  // confirm. Surfaced as 待确认, distinct from 卡住 (status === 'blocked').
  const needsOwnerReview = !isTemplate && state?.needsOwnerReview === true
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
  const runtimeSurfaceId = boundSession?.surfaceId?.trim() ?? ''
  const runtimeProviderId = boundSession?.providerResumeSessionId?.trim() ?? ''
  const hasRuntimeDebugIds = runtimeSurfaceId.length > 0 || runtimeProviderId.length > 0
  const plannedRunner = node.dispatch?.runner ?? node.executorType
  const actualProvider = boundSession?.pluginDisplayName?.trim() || boundSession?.pluginId?.trim() || null
  const actualModel = boundSession?.usageStats?.model?.trim() || null
  const runtimeMismatch = Boolean(
    actualProvider
      && (plannedRunner === 'codex' || plannedRunner === 'claude')
      && !actualProvider.toLowerCase().includes(plannedRunner),
  )

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

  const sendNodeActionToAI = (operation: 'expand-sub-canvas') => {
    onSendToAI?.(buildNodeActionPrompt(node, operation), {
      visibleText: 'Expand this node into a sub-canvas with me.',
      contextLabel: `Node: ${node.title}`,
    })
    onClose()
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
        </div>

        {/* canvas-spec §8 / §11 — inspector slimmed to TWO sections:
         *    1) 进展(Progress) — session/run state: bound? running /
         *       待确认 / 卡住 / 完成 + next action + open-session / re-dispatch.
         *    2) 输入 / 输出(I/O) — per schema slot, the bound artifact with
         *       its version history. Outputs are produced; inputs are consumed
         *       upstream artifacts.
         *  Removed: standalone 成果 section, 足迹/version-timeline section,
         *  the widget ⚙ popover. The advanced cluster (指派 / 定时 / 换会话)
         *  collapses behind a single 「更多」 so its APIs stay reachable. */}

        {/* UI-simplification cleanup — 进展 段去重:group label 只留标题。
         *  之前 hover 露出的「打开进展」link 与 runtime block 里的
         *  「打开会话查看进展」按钮重复,删掉 link,只留 runtime block 那个唯一的
         *  open-session 入口。 */}
        <div className="planner-node-modal__group-label planner-node-modal__group-label--progress">
          <span>进展</span>
        </div>

        {blockers.length > 0 && (
          <div className="planner-node-modal__blockers">
            {blockers.map((blocker) => (
              <span key={blocker}><AlertTriangle size={12} aria-hidden />{blocker}</span>
            ))}
          </div>
        )}

        {/* canvas-spec §8 — surface 待确认 (gate awaiting a human confirm)
         *  DISTINCTLY from 卡住. `state.needsOwnerReview` is true when the run
         *  is parked at a gateWait that needs the owner's go-ahead. All three
         *  decisions use the formal review endpoint and preserve artifact history. */}
        {!isTemplate && needsOwnerReview && (
          <div className="planner-node-modal__review-panel">
            <div className="planner-node-modal__progress-runtime-state is-awaiting">
              <span className="planner-node-modal__progress-runtime-dot" aria-hidden />
              <strong>待确认</strong>
              <span className="planner-node-modal__progress-runtime-session">批准后才会推进下游</span>
            </div>
            <div className="planner-node-modal__review-actions">
              <button type="button" className="is-primary" disabled={reviewBusy} onClick={() => void resolveReview('approve')}>
                批准
              </button>
              <button type="button" disabled={reviewBusy} onClick={() => setReviewPanel((value) => value === 'changes' ? 'none' : 'changes')}>
                要求修改
              </button>
              <button type="button" disabled={reviewBusy} onClick={() => setReviewPanel((value) => value === 'correct' ? 'none' : 'correct')}>
                修订并批准
              </button>
            </div>
            {reviewPanel === 'changes' && (
              <div className="planner-node-modal__review-form">
                <textarea value={reviewComment} onChange={(event) => setReviewComment(event.target.value)} placeholder="说明需要修改什么；这段意见会发送给当前会话或带入下一次运行。" />
                <button type="button" className="is-primary" disabled={reviewBusy || !reviewComment.trim()} onClick={() => void resolveReview('request_changes')}>
                  {reviewBusy ? '提交中…' : '提交修改意见'}
                </button>
              </div>
            )}
            {reviewPanel === 'correct' && (
              <div className="planner-node-modal__review-form">
                <textarea value={reviewCorrection} onChange={(event) => setReviewCorrection(event.target.value)} placeholder="填写修订后的最终内容；原 AI 版本会保留在版本历史中。" />
                <button type="button" className="is-primary" disabled={reviewBusy || !reviewCorrection.trim()} onClick={() => void resolveReview('approve', true)}>
                  {reviewBusy ? '保存中…' : '保存新版本并批准'}
                </button>
              </div>
            )}
            {reviewError && <p className="planner-node-modal__review-error" role="alert">{reviewError}</p>}
          </div>
        )}

        {/* 进展 runtime block — workflowRunState 中文 + spawn / 请回复 / 打开会话.
         *  gate-wait 显示「等审核」与 needsOwnerReview 的「待确认」是两种语义:
         *  gate-wait = 流程停在 gate;待确认 = 明确要 owner 拍板。 */}
        {!isTemplate && (nodeKind === 'step' || nodeKind === 'session') && (
          <div className="planner-node-modal__progress-runtime">
            {(() => {
              const wfs = node.workflowRunState
              const hasSession = Boolean(node.sessionId?.trim())
              // 3-态会话模型(2026-06-01): awaiting-input / gate-wait / failed → 「需要人回应」;
              // running / dispatched → 「运行中」;ready_to_start / pending → 「未启动」。「失败」下线
              // (会话结束=回到未启动;残留 failed 来自显式 blocked-submit,本质需要人回应)。
              const isAwaiting = wfs === 'awaiting-input' || wfs === 'gate-wait' || wfs === 'failed'
              const isRunning = wfs === 'running' || wfs === 'dispatched'
              // isDone 仅用于「进展」实时信息块的取舍(完成的会话只留最近消息+最后活动,
              // 不显示过期的 currentTask/currentTool),不再驱动「完成」标签或绿色样式。
              const isDone = wfs === 'done'
              const showLiveDetails = isRunning || isAwaiting || isDone
              // step / session 工作节点没有「完成」态(canvas 是账本不是 PM):
              // done = 会话结束 = 回到「未启动」,产物留在账本。本块仅渲染 step/session。
              const wfsLabel =
                isAwaiting ? '需要人回应'
                : isRunning ? '运行中'
                : wfs === 'ready_to_start' ? '未启动'
                : wfs === 'pending' ? '未启动'
                : wfs === 'done' ? '已完成'
                : null
              return (
                <>
                  {wfsLabel && (
                    <div
                      className={
                        'planner-node-modal__progress-runtime-state '
                        + (isAwaiting ? 'is-awaiting' : isRunning ? 'is-running' : '')
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
                  {/* 绑定会话时:展示该会话的信息 —— 让「进展」真有内容,而不只是一个
                   *  状态点。数据来自 board session DTO(boundSession),按
                   *  node.sessionId 匹配。
                   *    · running / awaiting:在干什么 / 工具(实时)+ 最近消息 + 最后活动
                   *    · done:不显示 currentTask/currentTool(对完成节点是过期的),
                   *      只留最近消息 + 完成/最后活动时间,外加下方的「打开会话」导航。 */}
                  {hasSession && boundSession && showLiveDetails && (
                    <div className="planner-node-modal__progress-runtime-live">
                      <span className="planner-node-modal__progress-runtime-live-row">
                        <Route size={11} aria-hidden /> 计划 {plannedRunner} · 实际 {actualProvider ?? '未知'} · {actualModel ?? '模型未知'}
                      </span>
                      {runtimeMismatch && (
                        <span className="planner-node-modal__progress-runtime-live-row planner-node-modal__runtime-mismatch">
                          <AlertTriangle size={11} aria-hidden /> 实际 Provider 与节点计划不一致
                        </span>
                      )}
                      {showLiveDetails && !isDone && boundSession.currentTask && (
                        <span className="planner-node-modal__progress-runtime-live-row">
                          <Route size={11} aria-hidden /> {boundSession.currentTask}
                        </span>
                      )}
                      {showLiveDetails && !isDone && boundSession.currentTool && (
                        <span className="planner-node-modal__progress-runtime-live-row">
                          <Settings2 size={11} aria-hidden /> {boundSession.currentTool}
                        </span>
                      )}
                      {showLiveDetails && (boundSession.recentMessages ?? [])
                        .slice(-2)
                        .filter((m) => m.text?.trim())
                        .map((m, i) => (
                          <span
                            key={`${m.role}-${i}`}
                            className="planner-node-modal__progress-runtime-live-row planner-node-modal__progress-runtime-live-muted"
                          >
                            <span className="planner-node-modal__progress-runtime-live-role">{m.role === 'user' ? '你' : m.role === 'assistant' ? 'AI' : m.role}</span>
                            {truncateMessageText(m.text)}
                          </span>
                        ))}
                      {showLiveDetails && boundSession.lastActivity && (
                        <span className="planner-node-modal__progress-runtime-live-row planner-node-modal__progress-runtime-live-muted">
                          <CalendarClock size={11} aria-hidden /> {isDone ? '最后活动 ' : ''}{relativeTimeLabel(boundSession.lastActivity)}
                        </span>
                      )}
                    </div>
                  )}
                  {/* 唯一的 open-session 入口:绑定了会话就给一个「打开会话」按钮。
                   *  等反馈时套 is-attention 高亮(会话在等回复),其余状态是普通
                   *  「打开会话查看进展」。不再有 group-label 上的 hover link 重复。 */}
                  {hasSession && onOpenSession && (
                    isAwaiting ? (
                      <button
                        type="button"
                        className="planner-node-modal__progress-runtime-action is-primary is-attention"
                        onClick={() => onOpenSession(node.sessionId!, node.id)}
                        title="会话在等你的回复 — 点击跳到会话窗口"
                      >
                        <AlertTriangle size={12} aria-hidden /> 请回复会话
                      </button>
                    ) : (
                      <button
                        type="button"
                        className="planner-node-modal__progress-runtime-action"
                        onClick={() => onOpenSession(node.sessionId!, node.id)}
                      >
                        → 打开会话查看进展
                      </button>
                    )
                  )}
                  {!hasSession && node.executorType !== 'human' && node.status === 'ready' && canChangeStatus && onReplaceSession && (
                    <button
                      type="button"
                      className="planner-node-modal__progress-runtime-action is-primary"
                      onClick={() => onReplaceSession?.(node.id, dispatchRunnerForNode(node.executorType))}
                      title="给这个节点起一个 AI 会话"
                    >
                      <Sparkles size={12} aria-hidden /> 开干 · 起会话
                    </button>
                  )}
                  {!hasSession && node.executorType === 'human' && node.status !== 'done' && !needsOwnerReview && (
                    <div className="planner-node-modal__human-output">
                      <textarea
                        value={humanOutput}
                        onChange={(event) => setHumanOutput(event.target.value)}
                        placeholder="填写这一步的完成说明或最终产物内容"
                      />
                      <button type="button" className="planner-node-modal__progress-runtime-action is-primary" disabled={reviewBusy || !humanOutput.trim()} onClick={() => void submitHumanOutput()}>
                        <UserRound size={12} aria-hidden /> {reviewBusy ? '提交中…' : '填写并提交'}
                      </button>
                      {reviewError && <span className="planner-node-modal__review-error" role="alert">{reviewError}</span>}
                    </div>
                  )}
                </>
              )
            })()}
          </div>
        )}

        {/* 进展 段次级动作:重跑 / 标记需要关注(从节点卡片 footer 搬来)。 */}
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

        {/* canvas-spec §8 — Section 2 · 输入 / 输出.
         *  Per schema slot, show the slot name + the artifact bound to it +
         *  its version history (the version chain). Input slots = consumed
         *  upstream; output slots = produced (latest + history). Replaces the
         *  old 成果 + 足迹 + IO-toggle clutter. */}
        <div className="planner-node-modal__group-label">
          <span>输入 / 输出</span>
          <small>每个槽位的产物与版本</small>
        </div>

        <div className="planner-node-modal__section">
          <h3><ArrowDownLeft size={13} aria-hidden /> 输入</h3>
          <InputCardSections
            node={node}
            variant="modal"
            canvasEdges={canvasEdges}
            canvasDataSources={canvasDataSources}
            nodeTitleById={nodeTitleById}
            onAttachDataSource={onAttachDataSource}
            onRefreshExternal={onRefreshExternalInput}
          />
        </div>

        <div className="planner-node-modal__section">
          <h3><ArrowUpRight size={13} aria-hidden /> 输出</h3>
          {outputItems.length > 0 ? (
            <div className="planner-node-modal__io-slots">
              {outputItems.map((reference) => (
                <OutputSlotRow
                  key={reference}
                  canvasId={canvasId}
                  nodeId={node.id}
                  reference={reference}
                  artifact={artifactForReference(artifacts, reference)}
                  showVisibilityToggle={canShowIOArtifactSwitches && Boolean(onToggleIOArtifact)}
                  visibleOnCanvas={visibleIOArtifacts.outputs.includes(reference)}
                  onToggleVisible={(visible) => onToggleIOArtifact?.(node.id, 'outputs', reference, visible)}
                />
              ))}
            </div>
          ) : (
            <p className="planner-node-modal__empty">这个节点暂时没有产出</p>
          )}
        </div>

        {/* Teams · 多人增量贡献 — collect-list step 的共享账本。owner 开关 +
         *  成员轻量添加 + 逐条归属。条目在云端,不进 canvas state。 */}
        {nodeKind === 'step' && !isTemplate && (
          <NodeContributionsSection
            canvasId={canvasId}
            node={node}
            isOwner={role === 'owner'}
            teamMembers={teamMembers}
            currentUserId={access?.actorId ?? null}
            canCloseout={role === 'owner' || (access?.actorId != null && node.doerId === access.actorId)}
            onOpenSession={onOpenSession}
            onGraphStateChanged={onGraphStateChanged}
          />
        )}

        {/* canvas-spec §11 — advanced cluster (指派 / 定时 / 展开子画板 /
         *  换一次进展) collapsed behind a single 「更多」 so the assign /
         *  schedule / replace-session APIs stay reachable without crowding the
         *  two primary sections. Default collapsed. */}
        {canUseStepActions && (
          <div className="planner-node-modal__section planner-node-modal__more">
            <button
              type="button"
              className="planner-node-modal__more-toggle"
              onClick={() => setAdvancedOpen((v) => !v)}
              aria-expanded={advancedOpen}
            >
              更多 {advancedOpen ? '▴' : '▾'}
            </button>
            {advancedOpen && (
              <>
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
                  {node.subCanvasId && (
                    <button
                      type="button"
                      onClick={() => {
                        onOpenSubCanvas?.(node.subCanvasId as string)
                        onClose()
                      }}
                    >
                      <ExternalLink size={12} aria-hidden /> 打开子画板
                    </button>
                  )}
                  {node.sessionId && onReplaceSession && (
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
                </div>
                {replaceConfirmOpen && node.sessionId && (
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
              </>
            )}
          </div>
        )}

        {hasRuntimeDebugIds && (
          <div className="planner-node-modal__runtime-debug-footer" aria-label="运行时标识">
            {runtimeSurfaceId && (
              <span
                className="planner-node-modal__runtime-debug-row"
                title={runtimeSurfaceId}
              >
                <span>Surface</span>
                <code>{runtimeSurfaceId}</code>
              </span>
            )}
            {runtimeProviderId && (
              <span
                className="planner-node-modal__runtime-debug-row"
                title={runtimeProviderId}
              >
                <span>Provider</span>
                <code>{runtimeProviderId}</code>
              </span>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

// canvas-spec §8 — find the produced artifact bound to an output slot
// reference. `artifacts` is the latest-per-slot mirror, so a match by
// reference / title yields the head (latest version) of that slot's chain.
export function artifactForReference(artifacts: PlannerArtifact[], reference: string): PlannerArtifact | undefined {
  const target = reference.trim().toLowerCase()
  return artifacts.find((artifact) =>
    artifact.reference.trim().toLowerCase() === target
    || (artifact.title ?? '').trim().toLowerCase() === target,
  )
}

// canvas-spec §8 — one output slot row: slot name + bound artifact (latest)
// + an inline, lazy-loaded version-history disclosure (the version chain via
// listArtifactVersions). Optionally an on-canvas visibility toggle reusing the
// I/O artifact expand mechanism.
function OutputSlotRow({
  canvasId,
  nodeId,
  reference,
  artifact,
  showVisibilityToggle,
  visibleOnCanvas,
  onToggleVisible,
}: {
  canvasId: string
  nodeId: string
  reference: string
  artifact: PlannerArtifact | undefined
  showVisibilityToggle: boolean
  visibleOnCanvas: boolean
  onToggleVisible: (visible: boolean) => void
}) {
  const [historyOpen, setHistoryOpen] = useState(false)
  const [versions, setVersions] = useState<PlannerArtifactVersion[] | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const ensureLoaded = () => {
    if (versions !== null || loading) return
    setLoading(true)
    setError(null)
    listArtifactVersions(canvasId, nodeId, reference)
      .then((result) => setVersions(result.versions ?? []))
      .catch((err) => {
        console.warn('[node-inspector] artifact versions load failed:', (err as Error)?.message)
        setError('历史版本暂时读不到,稍后再试')
      })
      .finally(() => setLoading(false))
  }

  const positionLabel = artifactPositionLabel(artifact?.positionTag)

  return (
    <div className="planner-node-modal__io-slot">
      <div className="planner-node-modal__io-slot-head">
        <strong title={reference}>
          <FileText size={11} aria-hidden />
          {artifact?.title?.trim() || compactLabel(reference)}
        </strong>
        {artifact ? (
          <span className="planner-node-modal__io-slot-version">{positionLabel}</span>
        ) : (
          <em className="planner-node-modal__io-slot-pending">待产出</em>
        )}
        {showVisibilityToggle && (
          <button
            type="button"
            className={`planner-node-modal__switch${visibleOnCanvas ? ' is-on' : ''}`}
            aria-pressed={visibleOnCanvas}
            aria-label={`${visibleOnCanvas ? '从画板收起' : '在画板展开'} ${reference}`}
            title={visibleOnCanvas ? '从画板收起这份产物' : '在画板上展开这份产物'}
            onClick={() => onToggleVisible(!visibleOnCanvas)}
          >
            <span />
          </button>
        )}
      </div>
      {artifact && (
        <button
          type="button"
          className="planner-node-modal__io-slot-history-toggle"
          aria-expanded={historyOpen}
          onClick={() => {
            setHistoryOpen((open) => {
              const next = !open
              if (next) ensureLoaded()
              return next
            })
          }}
        >
          <History size={11} aria-hidden />
          版本历史
          <ChevronDown size={11} aria-hidden />
        </button>
      )}
      {artifact && historyOpen && (
        <div className="planner-node-modal__io-slot-history">
          {loading && <p className="planner-node-modal__empty">载入中…</p>}
          {error && <p className="planner-node-modal__empty">{error}</p>}
          {!loading && !error && (versions?.length ?? 0) === 0 && (
            <p className="planner-node-modal__empty">只有当前这一版</p>
          )}
          {(versions ?? []).map((version, index) => (
            <div key={version.version_id} className="planner-node-modal__io-version">
              <span className="planner-node-modal__io-version-tag">
                {index === 0 ? '最新' : `v${(versions?.length ?? 0) - index}`}
              </span>
              <span className="planner-node-modal__io-version-meta">{formatVersionLabel(version)}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

// 版本链行文案:时间 + 提交者(不暴露 submitted_by_kind 这个隐藏词)。
function formatVersionLabel(v: PlannerArtifactVersion): string {
  const ts = Date.parse(v.created_at)
  const stamp = Number.isFinite(ts)
    ? new Date(ts).toLocaleString(undefined, { month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' })
    : v.created_at
  const submitter = v.submitted_by || '未知提交者'
  return `${stamp} · ${submitter}`
}

export function artifactPositionLabel(tag: PlannerArtifact['positionTag']): string {
  switch (tag) {
    case 'historical':
      return '历史版本'
    case 'discarded':
      return '已丢弃'
    case 'promoted':
      return '已提升'
    case 'proposed':
      return '提议中'
    case 'latest':
    default:
      return '最新'
  }
}

// 相对时间标签:把 ISO 时间戳渲染成「刚刚 / N 分钟前 / N 小时前 / N 天前」。
// 浏览器端 (board-app) 用 Date.now() / new Date() 没问题。
export function relativeTimeLabel(iso: string): string {
  const ts = Date.parse(iso)
  if (!Number.isFinite(ts)) return ''
  const deltaMs = Date.now() - ts
  if (deltaMs < 0) return '刚刚'
  const minutes = Math.floor(deltaMs / 60000)
  if (minutes < 1) return '刚刚'
  if (minutes < 60) return `${minutes} 分钟前`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} 小时前`
  const days = Math.floor(hours / 24)
  return `${days} 天前`
}

// 把会话最近消息裁成单行预览(role + 截断文本),给 进展 live block 用。
export function truncateMessageText(text: string, max = 80): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  if (flat.length <= max) return flat
  return `${flat.slice(0, max).trimEnd()}…`
}

export function compactRuntimeId(value: string, max = 28): string {
  const trimmed = value.trim()
  if (trimmed.length <= max) return trimmed
  return `${trimmed.slice(0, 14)}…${trimmed.slice(-8)}`
}

export function dedupeStrings(values: Array<string | null | undefined>): string[] {
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

export function compactLabel(value: string): string {
  const withoutQuery = value.trim().split('?')[0]
  const parts = withoutQuery.split(/[/:#]/).filter(Boolean)
  return parts[parts.length - 1]?.trim() || value
}

// PR1 (running-session-visual): runStateToBadge moved to deriveDisplayStatus
// in ./labels.ts so card + inspector share a single source of truth. Kept the
// removal here so future readers don't reach for a stale local helper.

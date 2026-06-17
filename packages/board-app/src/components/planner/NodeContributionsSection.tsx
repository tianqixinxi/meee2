import { Bot, Plus, Sparkles, UserRound, Users } from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import {
  completePlannerNodeContribution,
  fetchPlannerNodeContributions,
  startPlannerContributionSession,
  submitPlannerNodeContribution,
  updatePlannerNodeContribution,
} from '../../api'
import type { ContributionCompletionSuggestion, NodeCollector, TeamMember } from '../../api'
import type { NodeContribution, PlannerGraphState, PlanningNode } from '../../types'

// Teams · 多人增量贡献 — collect-list step 的共享账本面板。
//
// 节点保持单 owner;owner 把节点开放给团队(policy: 'team')后,任何成员都能
// 在这个节点上**启动自己的 AI 收集会话**(主路径):会话按节点契约调研,产出
// 经 MCP add_node_contribution 逐条进云端账本,归属=启动它的成员,kind=agent。
// 会话是专属轻量会话 — 不绑 node.sessionId、不动节点状态机,多成员可并发。
// 手动单条添加保留为次要补充(收起在「手动添加」后面)。
// 面板挂载期间轻量轮询,别人的新贡献十几秒内可见。

const POLL_MS = 15_000

interface Props {
  canvasId: string
  node: PlanningNode
  isOwner: boolean
  teamMembers: TeamMember[]
  /** 当前用户 id(access.actorId)— 区分「我的」收集会话。 */
  currentUserId?: string | null
  /** 收口权:canvas owner 或节点 doerId。 */
  canCloseout?: boolean
  /** 打开本地会话(自己的收集会话)。 */
  onOpenSession?: (sessionId: string, nodeId: string) => void
  onGraphStateChanged?: (state: PlannerGraphState) => void
}

// 只放行 http(s) 链接。账本 url 是别的成员提交的,javascript:/data: scheme
// 渲染成 href 会变成存储型 XSS;服务端同样校验,这里是渲染层的第二道闸。
function safeHttpUrl(url: string | null | undefined): string | null {
  if (!url) return null
  return /^https?:\/\//i.test(url) ? url : null
}

function relativeTime(iso: string): string {
  const t = Date.parse(iso)
  if (!Number.isFinite(t)) return ''
  const diff = Date.now() - t
  if (diff < 60_000) return '刚刚'
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)} 分钟前`
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)} 小时前`
  return new Date(t).toLocaleDateString()
}

export function NodeContributionsSection({
  canvasId,
  node,
  isOwner,
  teamMembers,
  currentUserId,
  canCloseout = false,
  onOpenSession,
  onGraphStateChanged,
}: Props) {
  const enabled = node.contribution?.policy === 'team'
  const itemLabel = node.contribution?.itemLabel?.trim() || '条目'

  const [items, setItems] = useState<NodeContribution[] | null>(null)
  const [collectors, setCollectors] = useState<NodeCollector[]>([])
  const [dashboardBaseUrl, setDashboardBaseUrl] = useState<string | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [title, setTitle] = useState('')
  const [note, setNote] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [policyBusy, setPolicyBusy] = useState(false)
  const [labelDraft, setLabelDraft] = useState(node.contribution?.itemLabel ?? '')
  const [doneWhenDraft, setDoneWhenDraft] = useState(node.contribution?.doneWhen ?? '')
  const [suggestion, setSuggestion] = useState<ContributionCompletionSuggestion | null>(null)
  const [closing, setClosing] = useState(false)
  const [manualOpen, setManualOpen] = useState(false)
  const [collectBusy, setCollectBusy] = useState(false)
  const [collectStatus, setCollectStatus] = useState<string | null>(null)
  const mountedRef = useRef(true)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  const refresh = useCallback(() => {
    fetchPlannerNodeContributions(canvasId, node.id)
      .then((res) => {
        if (!mountedRef.current) return
        setItems(res.contributions ?? [])
        setCollectors(res.collectors ?? [])
        if (res.dashboardBaseUrl) setDashboardBaseUrl(res.dashboardBaseUrl)
        setSuggestion(res.completionSuggestion ?? null)
        setLoadError(null)
      })
      .catch((err) => {
        if (!mountedRef.current) return
        setLoadError((err as Error).message || '加载贡献失败')
      })
  }, [canvasId, node.id])

  useEffect(() => {
    if (!enabled) return
    refresh()
    const timer = window.setInterval(refresh, POLL_MS)
    return () => window.clearInterval(timer)
  }, [enabled, refresh])

  const setPolicy = (policy: 'team' | 'closed', nextLabel?: string | null) => {
    setPolicyBusy(true)
    updatePlannerNodeContribution(canvasId, node.id, {
      policy,
      itemLabel: policy === 'team' ? (nextLabel ?? labelDraft).trim() || null : null,
      doneWhen: policy === 'team' ? doneWhenDraft.trim() || null : null,
    })
      .then((state) => {
        if (!mountedRef.current) return
        setPolicyBusy(false)
        onGraphStateChanged?.(state)
      })
      .catch((err) => {
        if (!mountedRef.current) return
        setPolicyBusy(false)
        setSubmitError((err as Error).message || '更新共建设置失败')
      })
  }

  // 主路径:启动(或复用)我的 AI 收集会话。产出会经 MCP 陆续进账本,
  // 这里只反馈派发结果;轮询会把新条目带进列表。
  const startCollect = () => {
    if (collectBusy) return
    setCollectBusy(true)
    setCollectStatus(null)
    startPlannerContributionSession(canvasId, node.id)
      .then((res) => {
        if (!mountedRef.current) return
        setCollectBusy(false)
        setCollectStatus(res.detail)
        refresh()
      })
      .catch((err) => {
        if (!mountedRef.current) return
        setCollectBusy(false)
        setCollectStatus((err as Error).message || '启动收集会话失败')
      })
  }

  // 收口:账本物化为节点输出 → 节点完成 → 触发下游。人做最终定夺。
  const closeout = () => {
    if (closing) return
    setClosing(true)
    completePlannerNodeContribution(canvasId, node.id)
      .then((state) => {
        if (!mountedRef.current) return
        setClosing(false)
        onGraphStateChanged?.(state)
      })
      .catch((err) => {
        if (!mountedRef.current) return
        setClosing(false)
        setSubmitError((err as Error).message || '收口失败')
      })
  }

  const submit = () => {
    const trimmed = title.trim()
    if (!trimmed || submitting) return
    setSubmitting(true)
    setSubmitError(null)
    submitPlannerNodeContribution(canvasId, node.id, {
      title: trimmed,
      note: note.trim() || undefined,
    })
      .then(() => {
        if (!mountedRef.current) return
        setSubmitting(false)
        setTitle('')
        setNote('')
        refresh()
      })
      .catch((err) => {
        if (!mountedRef.current) return
        setSubmitting(false)
        setSubmitError((err as Error).message || '提交失败')
      })
  }

  const memberById = new Map(teamMembers.map((m) => [m.userId, m]))
  const count = items?.length ?? 0
  const isCompleted = node.status === 'done'

  return (
    <>
      <div className="planner-node-modal__group-label">
        <span>团队共建</span>
        <small>
          {!enabled
            ? '关闭中 · 仅负责人可整理'
            : isCompleted
              ? `已收口 · 账本已冻结为节点输出(${count} 条)`
              : `开放中 · 每位成员都能启动自己的 AI 会话来收集${itemLabel}`}
        </small>
      </div>
      <div className="planner-node-modal__section planner-contrib">
        {isOwner && (
          <div className="planner-contrib__policy">
            <Users size={13} aria-hidden />
            {enabled ? (
              <>
                <input
                  className="planner-contrib__label-input"
                  value={labelDraft}
                  placeholder="条目名(如 startup)"
                  maxLength={40}
                  onChange={(e) => setLabelDraft(e.target.value)}
                  onBlur={() => {
                    const next = labelDraft.trim() || null
                    if ((node.contribution?.itemLabel ?? null) !== next) {
                      setPolicy('team', next)
                    }
                  }}
                />
                <input
                  className="planner-contrib__donewhen-input"
                  value={doneWhenDraft}
                  placeholder="收齐判据(如:50 家且每家有来源链接;空=人工定夺)"
                  maxLength={500}
                  title="自然语言判据 — 收集会话每轮对照自评,达成时发「建议收口」提醒;收口永远由人确认"
                  onChange={(e) => setDoneWhenDraft(e.target.value)}
                  onBlur={() => {
                    const next = doneWhenDraft.trim() || null
                    if ((node.contribution?.doneWhen ?? null) !== next) {
                      setPolicy('team', undefined)
                    }
                  }}
                />
                <button
                  type="button"
                  disabled={policyBusy}
                  onClick={() => setPolicy('closed')}
                >
                  关闭共建
                </button>
              </>
            ) : (
              <button
                type="button"
                disabled={policyBusy}
                onClick={() => setPolicy('team')}
              >
                开放给团队
              </button>
            )}
          </div>
        )}

        {!enabled && !isOwner && (
          <p className="planner-node-modal__empty">负责人还没开放这个节点的团队共建</p>
        )}

        {enabled && (
          <>
            {suggestion && !isCompleted && (
              <div className="planner-contrib__suggestion">
                <Bot size={13} aria-hidden />
                <span>
                  <strong>AI 建议收口</strong>
                  <em>{suggestion.rationale}</em>
                </span>
                {canCloseout && (
                  <button type="button" disabled={closing} onClick={closeout}>
                    {closing ? '收口中…' : '完成收集'}
                  </button>
                )}
              </div>
            )}
            {!isCompleted && (
            <div className="planner-contrib__collect">
              <button
                type="button"
                className="planner-contrib__collect-btn"
                disabled={collectBusy}
                onClick={startCollect}
                title={`派发我的专属收集会话:按节点契约调研,每确认一条${itemLabel}就写进账本(带我的署名)`}
              >
                <Sparkles size={13} aria-hidden />
                {collectBusy ? '派发中…' : `开始 AI 收集${itemLabel}`}
              </button>
              {collectStatus && <small className="planner-contrib__collect-status">{collectStatus}</small>}
              {canCloseout && !suggestion && count > 0 && (
                <button
                  type="button"
                  className="planner-contrib__closeout-btn"
                  disabled={closing}
                  onClick={closeout}
                  title="把账本物化为节点输出(全量快照),节点完成、触发下游"
                >
                  {closing ? '收口中…' : '完成收集'}
                </button>
              )}
            </div>
            )}

            {collectors.length > 0 && (
              <ul className="planner-contrib__collectors">
                {collectors.map((c) => {
                  const member = memberById.get(c.userId)
                  const who = member?.displayName ?? `${c.userId.slice(0, 8)}…`
                  const mine = c.mine ?? (currentUserId != null && c.userId === currentUserId)
                  const canOpenLocal = mine && !!c.sessionId && !!onOpenSession
                  const remoteUrl = !mine && c.sessionId && dashboardBaseUrl
                    ? `${dashboardBaseUrl.replace(/\/+$/, '')}/dashboard/sessions/${encodeURIComponent(c.sessionId)}`
                    : null
                  const clickable = canOpenLocal || !!remoteUrl
                  return (
                    <li key={c.userId}>
                      <button
                        type="button"
                        className="planner-contrib__collector"
                        disabled={!clickable}
                        title={clickable
                          ? (mine ? '打开我的收集会话' : `在网页查看 ${who} 的收集会话`)
                          : '会话还没同步出可打开的链接'}
                        onClick={() => {
                          if (canOpenLocal && c.sessionId) {
                            onOpenSession?.(c.sessionId, node.id)
                          } else if (remoteUrl) {
                            window.open(remoteUrl, '_blank', 'noreferrer')
                          }
                        }}
                      >
                        <span className="planner-contrib__avatar" title={who}>
                          {member?.avatarUrl
                            ? <img src={member.avatarUrl} alt="" />
                            : <UserRound size={12} aria-hidden />}
                        </span>
                        <span className="planner-contrib__collector-name">
                          {who}{mine ? ' (我)' : ''}
                        </span>
                        <span className={`planner-contrib__collector-state${c.alive ? ' is-alive' : ''}`}>
                          {mine
                            ? (c.alive ? '收集中' : '会话已结束')
                            : c.startedAt ? `启动于 ${relativeTime(c.startedAt)}` : '收集中'}
                        </span>
                      </button>
                    </li>
                  )
                })}
              </ul>
            )}

            {loadError ? (
              <p className="planner-contrib__error">{loadError}</p>
            ) : items === null ? (
              <p className="planner-node-modal__empty">加载中…</p>
            ) : count === 0 ? (
              <p className="planner-node-modal__empty">还没有{itemLabel} — 点上面开始 AI 收集,产出会陆续出现在这里</p>
            ) : (
              <ul className="planner-contrib__list">
                {items.map((item) => {
                  const member = item.submittedBy ? memberById.get(item.submittedBy) : undefined
                  const who = member?.displayName
                    ?? (item.submittedBy ? `${item.submittedBy.slice(0, 8)}…` : '未知成员')
                  const href = safeHttpUrl(item.url)
                  const viaAgent = item.kind === 'agent'
                  return (
                    <li key={item.id} className="planner-contrib__item">
                      <span className="planner-contrib__avatar" title={who}>
                        {member?.avatarUrl
                          ? <img src={member.avatarUrl} alt="" />
                          : <UserRound size={12} aria-hidden />}
                      </span>
                      <span className="planner-contrib__body">
                        <strong>
                          {href
                            ? <a href={href} target="_blank" rel="noreferrer">{item.title}</a>
                            : item.title}
                        </strong>
                        {item.note && <em>{item.note}</em>}
                      </span>
                      <span className="planner-contrib__meta">
                        {viaAgent && (
                          <span className="planner-contrib__via-agent" title={`${who} 的收集会话产出`}>
                            <Bot size={11} aria-hidden />
                          </span>
                        )}
                        {who} · {relativeTime(item.createdAt)}
                      </span>
                    </li>
                  )
                })}
              </ul>
            )}

            {isCompleted ? null : manualOpen ? (
              <div className="planner-contrib__form">
                <input
                  value={title}
                  placeholder={`手动添加一条${itemLabel}…`}
                  maxLength={500}
                  disabled={submitting}
                  autoFocus
                  onChange={(e) => setTitle(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' && !e.nativeEvent.isComposing) submit()
                  }}
                />
                <input
                  value={note}
                  placeholder="备注(可选)"
                  maxLength={4000}
                  disabled={submitting}
                  onChange={(e) => setNote(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' && !e.nativeEvent.isComposing) submit()
                  }}
                />
                <button
                  type="button"
                  disabled={submitting || !title.trim()}
                  onClick={submit}
                >
                  <Plus size={12} aria-hidden /> 添加
                </button>
              </div>
            ) : (
              <button
                type="button"
                className="planner-contrib__manual-toggle"
                onClick={() => setManualOpen(true)}
              >
                手动添加一条
              </button>
            )}
            {submitError && <p className="planner-contrib__error">{submitError}</p>}
          </>
        )}
      </div>
    </>
  )
}

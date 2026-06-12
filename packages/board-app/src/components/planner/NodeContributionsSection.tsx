import { Bot, Plus, Sparkles, UserRound, Users } from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import {
  fetchPlannerNodeContributions,
  startPlannerContributionSession,
  submitPlannerNodeContribution,
  updatePlannerNodeContribution,
} from '../../api'
import type { TeamMember } from '../../api'
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
  onGraphStateChanged,
}: Props) {
  const enabled = node.contribution?.policy === 'team'
  const itemLabel = node.contribution?.itemLabel?.trim() || '条目'

  const [items, setItems] = useState<NodeContribution[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [title, setTitle] = useState('')
  const [note, setNote] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [policyBusy, setPolicyBusy] = useState(false)
  const [labelDraft, setLabelDraft] = useState(node.contribution?.itemLabel ?? '')
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
      })
      .catch((err) => {
        if (!mountedRef.current) return
        setCollectBusy(false)
        setCollectStatus((err as Error).message || '启动收集会话失败')
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

  return (
    <>
      <div className="planner-node-modal__group-label">
        <span>团队共建</span>
        <small>
          {enabled
            ? `开放中 · 每位成员都能启动自己的 AI 会话来收集${itemLabel}`
            : '关闭中 · 仅负责人可整理'}
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
            </div>

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

            {manualOpen ? (
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

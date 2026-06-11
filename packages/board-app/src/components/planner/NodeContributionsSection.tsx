import { Plus, UserRound, Users } from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import {
  fetchPlannerNodeContributions,
  submitPlannerNodeContribution,
  updatePlannerNodeContribution,
} from '../../api'
import type { TeamMember } from '../../api'
import type { NodeContribution, PlannerGraphState, PlanningNode } from '../../types'

// Teams · 多人增量贡献 — collect-list step 的共享账本面板。
//
// 节点保持单 owner;owner 在这里把节点开放给团队(policy: 'team')后,每个
// 成员都能轻量地丢一条贡献(标题 + 备注/链接),不开工作 session、不动节点
// 状态机。条目存云端 contrib 账本,每条带 submittedBy 归属,这里用团队目录
// 解析成头像 + 名字。面板挂载期间轻量轮询,别人的新贡献十几秒内可见。

const POLL_MS = 15_000

interface Props {
  canvasId: string
  node: PlanningNode
  isOwner: boolean
  teamMembers: TeamMember[]
  onGraphStateChanged?: (state: PlannerGraphState) => void
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
            ? `开放中 · 每位成员都可以添加一条${itemLabel}`
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
            {loadError ? (
              <p className="planner-contrib__error">{loadError}</p>
            ) : items === null ? (
              <p className="planner-node-modal__empty">加载中…</p>
            ) : count === 0 ? (
              <p className="planner-node-modal__empty">还没有{itemLabel},来添加第一条</p>
            ) : (
              <ul className="planner-contrib__list">
                {items.map((item) => {
                  const member = item.submittedBy ? memberById.get(item.submittedBy) : undefined
                  const who = member?.displayName
                    ?? (item.submittedBy ? `${item.submittedBy.slice(0, 8)}…` : '未知成员')
                  return (
                    <li key={item.id} className="planner-contrib__item">
                      <span className="planner-contrib__avatar" title={who}>
                        {member?.avatarUrl
                          ? <img src={member.avatarUrl} alt="" />
                          : <UserRound size={12} aria-hidden />}
                      </span>
                      <span className="planner-contrib__body">
                        <strong>
                          {item.url
                            ? <a href={item.url} target="_blank" rel="noreferrer">{item.title}</a>
                            : item.title}
                        </strong>
                        {item.note && <em>{item.note}</em>}
                      </span>
                      <span className="planner-contrib__meta">
                        {who} · {relativeTime(item.createdAt)}
                      </span>
                    </li>
                  )
                })}
              </ul>
            )}

            <div className="planner-contrib__form">
              <input
                value={title}
                placeholder={`添加一条${itemLabel}…`}
                maxLength={500}
                disabled={submitting}
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
            {submitError && <p className="planner-contrib__error">{submitError}</p>}
          </>
        )}
      </div>
    </>
  )
}

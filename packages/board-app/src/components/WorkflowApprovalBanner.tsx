import { useCallback, useEffect, useState } from 'react'
import { fetchWorkflowApprovals, resolveWorkflowApproval } from '../api'
import type { WorkflowApprovalRecord } from '../types'
import { useI18n } from '../lib/i18n'

const POLL_MS = 5000

const COPY = {
  en: {
    apply: 'Create or update workflow',
    enable: 'Enable recurring jobs',
    pause: 'Pause recurring jobs',
    detail: 'Requested by your agent. Review and decide here; agents cannot approve this action.',
    approve: 'Approve',
    reject: 'Reject',
    working: 'Applying…',
  },
  'zh-CN': {
    apply: '创建或更新工作流',
    enable: '启用定时任务',
    pause: '暂停定时任务',
    detail: '这是 Agent 提交的请求，需要你在这里决定；Agent 无法替你批准。',
    approve: '批准',
    reject: '拒绝',
    working: '处理中…',
  },
} as const

export function WorkflowApprovalBanner() {
  const { locale } = useI18n()
  const copy = COPY[locale] ?? COPY.en
  const [approval, setApproval] = useState<WorkflowApprovalRecord | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    try {
      const pending = await fetchWorkflowApprovals()
      setApproval(pending.find((item) => item.status === 'pending') ?? null)
    } catch {
      // Older BoardServer versions do not expose workflow approvals.
    }
  }, [])

  useEffect(() => {
    void refresh()
    const id = window.setInterval(refresh, POLL_MS)
    const onVisible = () => document.visibilityState === 'visible' && void refresh()
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      window.clearInterval(id)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [refresh])

  const resolve = async (approved: boolean) => {
    if (!approval || busy) return
    setBusy(true)
    setError(null)
    try {
      await resolveWorkflowApproval(approval.id, approved)
      setApproval(null)
      await refresh()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Workflow approval failed')
    } finally {
      setBusy(false)
    }
  }

  if (!approval) return null
  return (
    <div className="workflow-approval-banner" role="alert" aria-live="assertive">
      <div className="workflow-approval-banner__copy">
        <strong>{copy[approval.action]}</strong>
        <span>{copy.detail}</span>
        {error && <span className="workflow-approval-banner__error">{error}</span>}
      </div>
      <div className="workflow-approval-banner__actions">
        <button type="button" className="ghost" disabled={busy} onClick={() => void resolve(false)}>
          {copy.reject}
        </button>
        <button type="button" className="primary" disabled={busy} onClick={() => void resolve(true)}>
          {busy ? copy.working : copy.approve}
        </button>
      </div>
    </div>
  )
}

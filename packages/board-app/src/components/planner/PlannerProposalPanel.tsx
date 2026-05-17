import { Eye, Send } from 'lucide-react'
import { useState } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import type { PlanProposal, PlannerAccess } from '../../types'

interface Props {
  proposal: PlanProposal | null
  previewActive: boolean
  busy: boolean
  error: string | null
  access: PlannerAccess | null
  nodeCount: number
  hasActionableDrift: boolean
  onSubmit: (message: string) => void
  onApplyPreview: () => void
  onApprove: () => void
  onApply: () => void
  onReject: () => void
}

export function PlannerProposalPanel({
  proposal,
  previewActive,
  busy,
  error,
  access,
  nodeCount,
  hasActionableDrift,
  onSubmit,
  onApplyPreview,
  onApprove,
  onApply,
  onReject,
}: Props) {
  const [message, setMessage] = useState('')
  const [lastUserMessage, setLastUserMessage] = useState('')
  const canCreateProposal = access?.canCreateProposal ?? true
  const canSend = (message.trim().length > 0 || hasActionableDrift) && !busy && canCreateProposal
  const guidance = plannerGuidance(nodeCount, hasActionableDrift)

  return (
    <aside className="planner-proposal-panel">
      <div className="planner-dialog">
        <div className="planner-dialog__messages">
          {error && <div className="planner-dialog__message planner-dialog__message--error">{error}</div>}
          {lastUserMessage && (
            <div className="planner-dialog__message planner-dialog__message--user">
              <MarkdownMessage markdown={lastUserMessage} />
            </div>
          )}
          {proposal ? (
            <div className="planner-dialog__message planner-dialog__message--planner">
              <div className="planner-dialog__message-meta">
                <span>{proposal.status}</span>
                <span>{proposal.changes.length} changes</span>
              </div>
              <MarkdownMessage markdown={proposalMarkdown(proposal)} />
              <div className="planner-dialog__actions">
                <button
                  type="button"
                  className="planner-proposal__preview"
                  disabled={busy}
                  onClick={onApplyPreview}
                >
                  <Eye size={14} aria-hidden />
                  {previewActive ? 'Update preview' : 'Apply preview'}
                </button>
                <button
                  type="button"
                  disabled={busy || proposal.status !== 'pending' || !access?.canApproveProposal}
                  onClick={onApprove}
                >
                  Approve
                </button>
                <button
                  type="button"
                  className="primary"
                  disabled={busy || proposal.status !== 'approved' || !access?.canApplyProposal}
                  onClick={onApply}
                >
                  Apply
                </button>
                <button
                  type="button"
                  disabled={busy || proposal.status === 'applied' || proposal.status === 'rejected' || !access?.canRejectProposal}
                  onClick={onReject}
                >
                  Reject
                </button>
              </div>
            </div>
          ) : (
            <div className="planner-dialog__message planner-dialog__message--planner">
              <MarkdownMessage markdown={guidance} />
            </div>
          )}
        </div>
      </div>

      <div className="planner-dialog__composer">
        <textarea
          value={message}
          onChange={(event) => setMessage(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
              event.preventDefault()
              if (!canSend) return
              const next = message.trim()
              setLastUserMessage(next || 'Inspect the current graph drift.')
              onSubmit(next)
              setMessage('')
            }
          }}
          placeholder={hasActionableDrift ? 'Ask Planner what to fix, or send empty to inspect drift' : 'Ask Planner to change the graph'}
          rows={5}
        />
        <div className="planner-proposal-panel__buttons">
          <button
            type="button"
            className="primary"
            disabled={!canSend}
            onClick={() => {
              const next = message.trim()
              setLastUserMessage(next || 'Inspect the current graph drift.')
              onSubmit(next)
              setMessage('')
            }}
            title={!canCreateProposal ? 'Only canvas owner can create topology proposals in this build.' : undefined}
          >
            <Send size={14} aria-hidden />
            Send
          </button>
        </div>
      </div>
    </aside>
  )
}

function MarkdownMessage({ markdown }: { markdown: string }) {
  return (
    <div className="planner-markdown">
      <ReactMarkdown remarkPlugins={[remarkGfm]}>
        {markdown}
      </ReactMarkdown>
    </div>
  )
}

function plannerGuidance(nodeCount: number, hasActionableDrift: boolean): string {
  if (nodeCount === 0) {
    return [
      'Tell me the outcome you want.',
      '',
      'I will turn it into a planner proposal first. You approve before the graph changes.',
    ].join('\n')
  }
  if (hasActionableDrift) {
    return [
      'I found graph state that may need attention.',
      '',
      'Send a message, or send with the input empty, and I will inspect the drift before proposing a fix.',
    ].join('\n')
  }
  return [
    'Ask me to adjust the planner graph.',
    '',
    'I will decide whether this should create new plan work or inspect the current state.',
  ].join('\n')
}

function proposalMarkdown(proposal: PlanProposal): string {
  const rows = proposal.changes.map((change) => {
    if (change.kind === 'addNode') {
      return `| add node | ${escapeMarkdown(change.node?.title ?? 'Untitled node')} |`
    }
    const target = change.title ?? change.nodeId ?? 'Unknown node'
    const details = [
      change.status,
      change.ioSchema ? 'schema' : null,
      change.contextSources ? 'context' : null,
      change.dependsOnNodeIds ? `${change.dependsOnNodeIds.length} deps` : null,
      change.subCanvasId ? 'sub-canvas' : null,
    ].filter(Boolean).join(', ')
    return `| update node | ${escapeMarkdown(target)}${details ? ` (${escapeMarkdown(details)})` : ''} |`
  })

  return [
    `### ${proposal.summary}`,
    '',
    `Status: **${proposal.status}**`,
    '',
    '| Change | Target |',
    '|---|---|',
    ...rows,
  ].join('\n')
}

function escapeMarkdown(value: string): string {
  return value.replace(/\|/g, '\\|')
}

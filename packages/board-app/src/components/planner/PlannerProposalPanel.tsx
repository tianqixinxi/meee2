import { Check, Eye, GitBranch, Send, X } from 'lucide-react'
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
  onCreateDeliveryPipeline?: () => void
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
  onCreateDeliveryPipeline,
}: Props) {
  const [message, setMessage] = useState('')
  const [lastUserMessage, setLastUserMessage] = useState('')
  const [reviewOpen, setReviewOpen] = useState(false)
  const canCreateProposal = access?.canCreateProposal ?? true
  const canSend = (message.trim().length > 0 || hasActionableDrift) && !busy && canCreateProposal
  const guidance = plannerGuidance(nodeCount, hasActionableDrift)

  return (
    <aside className="planner-proposal-panel">
      <div className="planner-dialog">
        <div className="planner-dialog__messages">
          <WorkflowGuide
            proposal={proposal}
            previewActive={previewActive}
            nodeCount={nodeCount}
            hasActionableDrift={hasActionableDrift}
          />
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
                {previewActive && <span>preview active</span>}
              </div>
              <MarkdownMessage markdown={proposalChatMarkdown(proposal)} />
              <div className="planner-dialog__actions planner-dialog__actions--single">
                <button
                  type="button"
                  className="planner-proposal__preview"
                  disabled={busy}
                  onClick={() => setReviewOpen(true)}
                >
                  <Eye size={14} aria-hidden />
                  Review proposal
                </button>
              </div>
            </div>
          ) : (
            <div className="planner-dialog__message planner-dialog__message--planner">
              <MarkdownMessage markdown={guidance} />
              {nodeCount === 0 && onCreateDeliveryPipeline && (
                <div className="planner-dialog__actions">
                  <button
                    type="button"
                    disabled={busy || !canCreateProposal}
                    onClick={onCreateDeliveryPipeline}
                  >
                    <GitBranch size={14} aria-hidden />
                    Create delivery pipeline
                  </button>
                </div>
              )}
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
          placeholder={hasActionableDrift ? 'Ask meee2 AI what to fix, or send empty to inspect drift' : 'Ask meee2 AI to change the graph'}
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

      {reviewOpen && proposal && (
        <div
          className="planner-proposal-modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setReviewOpen(false)
          }}
        >
          <div className="planner-proposal-modal" role="dialog" aria-modal="true" aria-label="Review proposal">
            <button
              type="button"
              className="planner-proposal-modal__close"
              onClick={() => setReviewOpen(false)}
              aria-label="Close proposal review"
            >
              <X size={15} aria-hidden />
            </button>
            <div className="planner-proposal-modal__header">
              <span>{proposal.status}</span>
              <h2>{proposal.summary}</h2>
              <p>{proposal.changes.length} proposed graph {proposal.changes.length === 1 ? 'change' : 'changes'}</p>
            </div>
            <div className="planner-proposal-modal__flow" aria-label="Proposal action order">
              <span className={previewActive ? 'is-done' : ''}>1 Preview graph</span>
              <span className={proposal.status === 'approved' || proposal.status === 'applied' ? 'is-done' : ''}>2 Approve</span>
              <span className={proposal.status === 'applied' ? 'is-done' : ''}>3 Apply to live graph</span>
              <em>Reject can be used before apply</em>
            </div>
            <MarkdownMessage markdown={proposalMarkdown(proposal)} />
            <div className="planner-proposal-modal__actions">
              <button
                type="button"
                disabled={busy}
                onClick={onApplyPreview}
              >
                <Eye size={14} aria-hidden />
                {previewActive ? 'Update preview' : 'Preview graph'}
              </button>
              <button
                type="button"
                disabled={busy || proposal.status !== 'pending' || !access?.canApproveProposal}
                onClick={onApprove}
              >
                <Check size={14} aria-hidden />
                Approve proposal
              </button>
              <button
                type="button"
                className="primary"
                disabled={busy || proposal.status !== 'approved' || !access?.canApplyProposal}
                onClick={() => {
                  onApply()
                  setReviewOpen(false)
                }}
              >
                Apply to live
              </button>
              <button
                type="button"
                disabled={busy || proposal.status === 'applied' || proposal.status === 'rejected' || !access?.canRejectProposal}
                onClick={() => {
                  onReject()
                  setReviewOpen(false)
                }}
              >
                Reject
              </button>
            </div>
          </div>
        </div>
      )}
    </aside>
  )
}

function WorkflowGuide({
  proposal,
  previewActive,
  nodeCount,
  hasActionableDrift,
}: {
  proposal: PlanProposal | null
  previewActive: boolean
  nodeCount: number
  hasActionableDrift: boolean
}) {
  const copy = workflowGuideCopy(proposal, previewActive, nodeCount, hasActionableDrift)
  return (
    <div className="planner-workflow-guide" aria-label="Workflow next step">
      <span>Next</span>
      <strong>{copy.title}</strong>
      <p>{copy.body}</p>
    </div>
  )
}

function workflowGuideCopy(
  proposal: PlanProposal | null,
  previewActive: boolean,
  nodeCount: number,
  hasActionableDrift: boolean,
): { title: string; body: string } {
  if (proposal?.status === 'pending') {
    return previewActive
      ? {
          title: 'Approve the proposal if the preview is right',
          body: 'Preview is only a temporary graph. Approve first, then apply it to the live workflow.',
        }
      : {
          title: 'Preview this proposal',
          body: 'Review what meee2 AI wants to change before approving. Nothing has changed in the live graph yet.',
        }
  }
  if (proposal?.status === 'approved') {
    return {
      title: 'Apply to live graph',
      body: 'The owner has approved this proposal. Apply it to make the workflow state real.',
    }
  }
  if (nodeCount === 0) {
    return {
      title: 'Create a workflow',
      body: 'Describe the outcome you want, or start from the delivery pipeline template.',
    }
  }
  if (hasActionableDrift) {
    return {
      title: 'Inspect blocked or review nodes',
      body: 'Ask meee2 AI to inspect drift, then approve a repair proposal. Open Details on a node for bindings and artifacts.',
    }
  }
  return {
    title: 'Dispatch the next step',
    body: 'Open a node Details modal, bind a session only when you know the relation, then dispatch or attach artifacts.',
  }
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
      'I will turn it into a meee2 AI proposal first. You approve before the graph changes.',
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
    'Ask meee2 AI to adjust the graph.',
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
      change.nodeKind ? change.nodeKind : null,
      change.workflowRunState ? change.workflowRunState : null,
      change.sessionId ? 'session bind' : null,
      change.artifactRefs ? `${change.artifactRefs.length} artifacts` : null,
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

function proposalChatMarkdown(proposal: PlanProposal): string {
  const firstChanges = proposal.changes.slice(0, 3).map((change) => {
    if (change.kind === 'addNode') {
      return `- Add ${escapeMarkdown(change.node?.title ?? 'Untitled node')}`
    }
    return `- Update ${escapeMarkdown(change.title ?? change.nodeId ?? 'Unknown node')}`
  })
  const more = proposal.changes.length > 3 ? [`- +${proposal.changes.length - 3} more`] : []
  return [
    `### ${proposal.summary}`,
    '',
    ...firstChanges,
    ...more,
  ].join('\n')
}

function escapeMarkdown(value: string): string {
  return value.replace(/\|/g, '\\|')
}

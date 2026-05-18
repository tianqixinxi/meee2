import { Check, Eye, GitBranch, Info, Send, X } from 'lucide-react'
import { useEffect, useState } from 'react'
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
  /** Incremented when a node action (dispatch/bind/…) creates a proposal —
   *  triggers the review modal so the action has a visible result. */
  reviewRequestTick?: number
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
  reviewRequestTick,
}: Props) {
  const [message, setMessage] = useState('')
  const [lastUserMessage, setLastUserMessage] = useState('')
  const [reviewOpen, setReviewOpen] = useState(false)

  // A node action just produced a proposal — surface it immediately.
  useEffect(() => {
    if (reviewRequestTick && reviewRequestTick > 0) setReviewOpen(true)
  }, [reviewRequestTick])
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
            <div className="planner-dialog__hint" role="note">
              <div className="planner-dialog__hint-label">
                <Info size={11} aria-hidden />
                <span>How this works</span>
              </div>
              <MarkdownMessage markdown={guidance} />
              {nodeCount === 0 && onCreateDeliveryPipeline && (
                <div className="planner-dialog__secondary">
                  <span>Prefer a head start?</span>
                  <button
                    type="button"
                    className="planner-dialog__link-action"
                    disabled={busy || !canCreateProposal}
                    onClick={onCreateDeliveryPipeline}
                    title="Drops in the meee2 delivery skeleton as a proposal — you still refine and approve it with meee2 AI."
                  >
                    <GitBranch size={12} aria-hidden />
                    Start from the meee2 delivery skeleton
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
                title={
                  previewActive
                    ? 'Re-render the temporary preview graph — use this after the proposal changed. The live graph is still untouched.'
                    : 'Render the proposal as a temporary preview graph. Nothing in the live graph changes.'
                }
              >
                <Eye size={14} aria-hidden />
                {previewActive ? 'Update preview' : 'Preview graph'}
              </button>
              <button
                type="button"
                disabled={busy || proposal.status !== 'pending' || !access?.canApproveProposal}
                onClick={onApprove}
                title="Owner sign-off. Marks the proposal approved — it still does NOT touch the live graph."
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
                title="Write the approved changes into the live graph. This is the only step that mutates the real workflow."
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
      title: 'Co-create a workflow with meee2 AI',
      body: 'Describe the outcome you want and we shape the graph together. The delivery skeleton is just an optional starting point.',
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
      'Describe the outcome you want in the box below.',
      '',
      'meee2 AI drafts it as a proposal — you refine it and approve before anything lands in the graph.',
    ].join('\n')
  }
  if (hasActionableDrift) {
    return [
      'This graph has nodes that may need attention.',
      '',
      'Send a message — or send with the box empty — and meee2 AI will inspect the drift before proposing a fix.',
    ].join('\n')
  }
  return [
    'Ask meee2 AI to adjust the graph in the box below.',
    '',
    'It decides whether to create new plan work or inspect the current state.',
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

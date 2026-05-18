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
  onApproveAndApply: () => void
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
  onApproveAndApply,
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
                {previewActive && <span>Previewing proposal</span>}
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
        <div className="planner-proposal-panel__buttons" aria-label="Send message">
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
            aria-label="Send to meee2 AI"
          >
            <Send size={14} aria-hidden />
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
              <span className={previewActive ? 'is-done' : ''}>1 Preview changes</span>
              <span className={proposal.status === 'applied' ? 'is-done' : ''}>2 Approve and apply</span>
              <em>Reject before apply if the proposal is wrong</em>
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
                Preview changes
              </button>
              <button
                type="button"
                className="primary"
                disabled={busy || proposal.status === 'applied' || proposal.status === 'rejected' || !canApproveAndApply(proposal, access)}
                onClick={() => {
                  onApproveAndApply()
                  setReviewOpen(false)
                }}
                title="Write the approved changes into the live graph. This is the only step that mutates the real workflow."
              >
                <Check size={14} aria-hidden />
                Approve and apply
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
              <details className="planner-proposal-modal__advanced">
                <summary>Advanced</summary>
                <div>
                  <button
                    type="button"
                    disabled={busy || proposal.status !== 'pending' || !access?.canApproveProposal}
                    onClick={onApprove}
                  >
                    Approve only
                  </button>
                  <button
                    type="button"
                    disabled={busy || proposal.status !== 'approved' || !access?.canApplyProposal}
                    onClick={() => {
                      onApply()
                      setReviewOpen(false)
                    }}
                  >
                    Apply approved
                  </button>
                </div>
              </details>
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
          title: 'Approve and apply if the preview is right',
          body: 'Preview is temporary. The main action approves the proposal and applies it to the live workflow.',
        }
      : {
          title: 'Preview this proposal',
          body: 'Review what meee2 AI wants to change before approving. Nothing has changed in the live graph yet.',
        }
  }
  if (proposal?.status === 'approved') {
    return {
      title: 'Apply the approved proposal',
      body: 'This proposal is already approved. Use Approve and apply to make it live.',
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
      body: 'Ask meee2 AI to inspect drift, then approve a repair proposal. Open a node for execution or evidence details.',
    }
  }
  return {
    title: 'Start the next step',
    body: 'Open a node, start work or attach a known existing session, then submit structured output when the step is done or blocked.',
  }
}

function canApproveAndApply(proposal: PlanProposal, access: PlannerAccess | null): boolean {
  if (proposal.status === 'pending') {
    return Boolean(access?.canApproveProposal && access?.canApplyProposal)
  }
  if (proposal.status === 'approved') {
    return Boolean(access?.canApplyProposal)
  }
  return false
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
      const node = change.node
      return `| add node | ${escapeMarkdown(node?.title ?? 'Untitled node')} | ${escapeMarkdown(changeDetails([
        node?.nodeKind,
        node?.status,
        node?.doerId ? `doer ${node.doerId}` : null,
        node?.dependsOnNodeIds?.length ? `${node.dependsOnNodeIds.length} deps` : null,
        node?.ioSchema ? schemaSummary(node.ioSchema) : null,
        node?.contextSources?.length ? `${node.contextSources.length} context` : null,
      ]))} |`
    }
    const target = change.title ?? change.nodeId ?? 'Unknown node'
    const details = changeDetails([
      change.title ? `title -> ${change.title}` : null,
      change.status ? `status -> ${change.status}` : null,
      change.ioSchema ? schemaSummary(change.ioSchema) : null,
      change.contextSources ? `${change.contextSources.length} context source${change.contextSources.length === 1 ? '' : 's'}` : null,
      change.dependsOnNodeIds ? `${change.dependsOnNodeIds.length} deps` : null,
      change.doerId ? `doer -> ${change.doerId}` : null,
      change.subCanvasId ? `sub-canvas -> ${change.subCanvasId}` : null,
      change.nodeKind ? `kind -> ${change.nodeKind}` : null,
      change.gate ? `gate -> ${change.gate.label}` : null,
      change.dispatch ? `runner -> ${change.dispatch.runner}` : null,
      change.workflowRunState ? change.workflowRunState : null,
      change.sessionId ? 'session bind' : null,
      change.artifactRefs ? `${change.artifactRefs.length} outputs` : null,
    ])
    return `| update node | ${escapeMarkdown(target)} | ${escapeMarkdown(details || 'metadata update')} |`
  })

  return [
    `### ${proposal.summary}`,
    '',
    `Status: **${proposal.status}**`,
    '',
    '| Change | Target | Detail |',
    '|---|---|---|',
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

function changeDetails(values: Array<string | null | undefined>): string {
  return values.filter(Boolean).join(', ')
}

function schemaSummary(schema: { consumes: string[]; produces: string[]; completionSignal: string }): string {
  const consumes = schema.consumes.length ? `in ${schema.consumes.join('+')}` : 'no input'
  const produces = schema.produces.length ? `out ${schema.produces.join('+')}` : 'no output'
  return `schema ${consumes} -> ${produces}; done=${schema.completionSignal}`
}

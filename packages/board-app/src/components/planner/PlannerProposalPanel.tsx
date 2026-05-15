import { Eye, GitPullRequestArrow, ScanSearch, WandSparkles } from 'lucide-react'
import { useState } from 'react'
import type { PlanChange, PlanProposal } from '../../types'

interface Props {
  proposal: PlanProposal | null
  previewActive: boolean
  busy: boolean
  error: string | null
  onGenerate: (goal: string) => void
  onInspectDrift: () => void
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
  onGenerate,
  onInspectDrift,
  onApplyPreview,
  onApprove,
  onApply,
  onReject,
}: Props) {
  const [goal, setGoal] = useState('')
  const canGenerate = goal.trim().length > 0 && !busy

  return (
    <aside className="planner-proposal-panel">
      <div className="planner-proposal-panel__header">
        <div>
          <h2>Proposal</h2>
          <p>Planner proposes. Owner approves.</p>
        </div>
        <GitPullRequestArrow size={18} aria-hidden />
      </div>

      <div className="planner-proposal-panel__controls">
        <textarea
          value={goal}
          onChange={(event) => setGoal(event.target.value)}
          placeholder="Describe the owner goal for this canvas"
          rows={4}
        />
        <div className="planner-proposal-panel__buttons">
          <button
            type="button"
            className="primary"
            disabled={!canGenerate}
            onClick={() => onGenerate(goal.trim())}
          >
            <WandSparkles size={14} aria-hidden />
            Generate plan
          </button>
          <button type="button" disabled={busy} onClick={onInspectDrift}>
            <ScanSearch size={14} aria-hidden />
            Inspect drift
          </button>
        </div>
      </div>

      {error && <div className="planner-proposal-panel__error">{error}</div>}

      {proposal ? (
        <div className="planner-proposal">
          <div className="planner-proposal__meta">
            <span>{proposal.status}</span>
            <span>{proposal.changes.length} changes</span>
          </div>
          <h3>{proposal.summary}</h3>
          <div className="planner-proposal__changes">
            {proposal.changes.map((change, index) => (
              <ProposalChangeRow key={`${change.kind}-${change.nodeId ?? change.node?.id ?? index}`} change={change} />
            ))}
          </div>
          <button
            type="button"
            className="planner-proposal__preview"
            disabled={busy}
            onClick={onApplyPreview}
          >
            <Eye size={14} aria-hidden />
            {previewActive ? 'Refresh preview' : 'Apply preview'}
          </button>
          <div className="planner-proposal__lifecycle">
            <button
              type="button"
              disabled={busy || proposal.status !== 'pending'}
              onClick={onApprove}
            >
              Approve
            </button>
            <button
              type="button"
              className="primary"
              disabled={busy || proposal.status !== 'approved'}
              onClick={onApply}
            >
              Apply
            </button>
            <button
              type="button"
              disabled={busy || proposal.status === 'applied' || proposal.status === 'rejected'}
              onClick={onReject}
            >
              Reject
            </button>
          </div>
        </div>
      ) : (
        <div className="planner-proposal-panel__empty">
          Generate a proposal or inspect drift to preview topology changes.
        </div>
      )}
    </aside>
  )
}

function ProposalChangeRow({ change }: { change: PlanChange }) {
  if (change.kind === 'addNode') {
    return (
      <div className="planner-proposal-change add">
        <span>addNode</span>
        <strong>{change.node?.title ?? 'Untitled node'}</strong>
      </div>
    )
  }

  return (
    <div className="planner-proposal-change update">
      <span>updateNode</span>
      <strong>{change.title ?? change.nodeId ?? 'Unknown node'}</strong>
      {change.status && <em>{change.status}</em>}
    </div>
  )
}

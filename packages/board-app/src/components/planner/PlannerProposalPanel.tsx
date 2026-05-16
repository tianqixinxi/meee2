import { Eye, ScanSearch, WandSparkles } from 'lucide-react'
import { useState } from 'react'
import type { PlanChange, PlanProposal, PlannerAccess } from '../../types'

interface Props {
  proposal: PlanProposal | null
  previewActive: boolean
  busy: boolean
  error: string | null
  access: PlannerAccess | null
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
  access,
  onGenerate,
  onInspectDrift,
  onApplyPreview,
  onApprove,
  onApply,
  onReject,
}: Props) {
  const [goal, setGoal] = useState('')
  const canCreateProposal = access?.canCreateProposal ?? true
  const canGenerate = goal.trim().length > 0 && !busy && canCreateProposal

  return (
    <aside className="planner-proposal-panel">
      <div className="planner-dialog">
        <div className="planner-dialog__messages">
          {error && <div className="planner-dialog__message planner-dialog__message--error">{error}</div>}
          {proposal ? (
            <div className="planner-dialog__message planner-dialog__message--planner">
              <div className="planner-dialog__message-meta">
                <span>{proposal.status}</span>
                <span>{proposal.changes.length} changes</span>
              </div>
              <h3>{proposal.summary}</h3>
              <div className="planner-proposal__changes">
                {proposal.changes.map((change, index) => (
                  <ProposalChangeRow key={`${change.kind}-${change.nodeId ?? change.node?.id ?? index}`} change={change} />
                ))}
              </div>
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
            <div className="planner-dialog__empty">Ask Planner to propose the next topology change.</div>
          )}
        </div>
      </div>

      <div className="planner-dialog__composer">
        <textarea
          value={goal}
          onChange={(event) => setGoal(event.target.value)}
          placeholder="Tell Planner what should change"
          rows={5}
        />
        <div className="planner-proposal-panel__buttons">
          <button
            type="button"
            className="primary"
            disabled={!canGenerate}
            onClick={() => onGenerate(goal.trim())}
            title={!canCreateProposal ? 'Only canvas owner can create topology proposals in this build.' : undefined}
          >
            <WandSparkles size={14} aria-hidden />
            Generate plan
          </button>
          <button
            type="button"
            disabled={busy || !canCreateProposal}
            onClick={onInspectDrift}
            title={!canCreateProposal ? 'Only canvas owner can create topology proposals in this build.' : undefined}
          >
            <ScanSearch size={14} aria-hidden />
            Inspect drift
          </button>
        </div>
      </div>
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
      {change.ioSchema && <em>schema</em>}
      {change.contextSources && <em>context</em>}
      {change.dependsOnNodeIds && <em>deps {change.dependsOnNodeIds.length}</em>}
      {change.subCanvasId && <em>sub-canvas</em>}
    </div>
  )
}

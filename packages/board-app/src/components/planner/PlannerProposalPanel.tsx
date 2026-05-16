import { Eye, GitPullRequestArrow, ScanSearch, WandSparkles } from 'lucide-react'
import { useState } from 'react'
import type { PlanChange, PlanProposal, PlannerAccess, PlanningNode } from '../../types'

interface Props {
  proposal: PlanProposal | null
  previewActive: boolean
  busy: boolean
  error: string | null
  access: PlannerAccess | null
  selectedNode: PlanningNode | null
  onGenerate: (goal: string) => void
  onInspectDrift: () => void
  onRefineNode: (reason: string) => void
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
  selectedNode,
  onGenerate,
  onInspectDrift,
  onRefineNode,
  onApplyPreview,
  onApprove,
  onApply,
  onReject,
}: Props) {
  const [goal, setGoal] = useState('')
  const [refineReason, setRefineReason] = useState('')
  const canCreateProposal = access?.canCreateProposal ?? true
  const canGenerate = goal.trim().length > 0 && !busy && canCreateProposal
  const canRefine = Boolean(selectedNode) && refineReason.trim().length > 0 && !busy && canCreateProposal

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

      <div className="planner-refine-panel">
        <div className="planner-refine-panel__header">
          <span>Selected node</span>
          <strong>{selectedNode?.title ?? 'None'}</strong>
        </div>
        <textarea
          value={refineReason}
          onChange={(event) => setRefineReason(event.target.value)}
          placeholder="Describe how Planner should refine the selected node"
          rows={3}
          disabled={!selectedNode}
        />
        <button
          type="button"
          disabled={!canRefine}
          onClick={() => {
            const reason = refineReason.trim()
            if (!reason) return
            onRefineNode(reason)
            setRefineReason('')
          }}
          title={!selectedNode ? 'Select a node in the graph first.' : undefined}
        >
          <WandSparkles size={14} aria-hidden />
          Refine selected
        </button>
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
            {previewActive ? 'Update preview' : 'Apply preview'}
          </button>
          <div className="planner-proposal__lifecycle">
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
      {change.ioSchema && <em>schema</em>}
      {change.contextSources && <em>context</em>}
      {change.dependsOnNodeIds && <em>deps {change.dependsOnNodeIds.length}</em>}
      {change.subCanvasId && <em>sub-canvas</em>}
    </div>
  )
}

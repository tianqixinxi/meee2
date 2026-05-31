import { useEffect, useMemo, useRef, useState } from 'react'
import { AlertTriangle, Search, UserRound, X } from 'lucide-react'
import type { NodeContractV2, PlanningNode } from '../../types'
import type { TeamMember } from '../../api'

/**
 * UI-2 · F1.1–F1.3 + U2.2 — assign a node to a teammate. Two phases:
 *   1. Picker — choose a person; show what the assignee will own.
 *   2. Confirm — assign only runs from an already-published Team Canvas.
 *
 * F1.4 (flow-vs-item mode) is UX待验 and intentionally not surfaced; we
 * always treat the action as "assign the whole node as a sub-canvas".
 */
type AssignPhase = 'pick' | 'confirm-public'

export interface AssignNodeDialogProps {
  node: PlanningNode
  /** Frozen contract snapshot — what the assignee owes back upstream. */
  frozenIOContract: NodeContractV2 | null
  /** Team member directory (already filtered to candidates). */
  teamMembers: TeamMember[]
  /** Anyone we should exclude (e.g. current owner, who cannot assign to self). */
  excludedUserIds?: string[]
  busy?: boolean
  errorMessage?: string | null
  onCancel: () => void
  onConfirm: (input: { assigneeUserId: string; acceptPrivateUpgrade: boolean }) => void
}

export function AssignNodeDialog({
  node,
  frozenIOContract,
  teamMembers,
  excludedUserIds,
  busy,
  errorMessage,
  onCancel,
  onConfirm,
}: AssignNodeDialogProps) {
  const [phase, setPhase] = useState<AssignPhase>('pick')
  const [query, setQuery] = useState('')
  const [pickedUserId, setPickedUserId] = useState<string | null>(null)
  const searchRef = useRef<HTMLInputElement | null>(null)

  useEffect(() => {
    searchRef.current?.focus()
  }, [])

  // ESC closes — except when an RPC is in flight, to avoid mid-assign exits.
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !busy) onCancel()
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [busy, onCancel])

  const excludeSet = useMemo(() => new Set(excludedUserIds ?? []), [excludedUserIds])
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    return teamMembers
      .filter((member) => !excludeSet.has(member.userId))
      .filter((member) => {
        if (!q) return true
        return (
          member.displayName.toLowerCase().includes(q)
          || (member.email ?? '').toLowerCase().includes(q)
          || member.userId.toLowerCase().includes(q)
        )
      })
  }, [teamMembers, query, excludeSet])

  const picked = pickedUserId ? teamMembers.find((m) => m.userId === pickedUserId) ?? null : null

  const handleNextFromPicker = () => {
    if (!picked) return
    setPhase('confirm-public')
  }

  const handleFinalConfirm = () => {
    if (!picked) return
    onConfirm({
      assigneeUserId: picked.userId,
      acceptPrivateUpgrade: false,
    })
  }

  return (
    <div
      className="planner-assign-dialog__backdrop"
      role="dialog"
      aria-modal="true"
      aria-labelledby="planner-assign-dialog-title"
      onClick={(event) => {
        if (event.target === event.currentTarget && !busy) onCancel()
      }}
    >
      <div className="planner-assign-dialog">
        <header className="planner-assign-dialog__header">
          <div>
            <h2 id="planner-assign-dialog-title">Assign node</h2>
            <p className="planner-assign-dialog__subtitle">
              {node.title}
            </p>
          </div>
          <button
            type="button"
            className="planner-assign-dialog__close"
            aria-label="Close assign dialog"
            disabled={busy}
            onClick={onCancel}
          >
            <X size={16} aria-hidden />
          </button>
        </header>

        {phase === 'pick' && (
          <div className="planner-assign-dialog__body">
            <label className="planner-assign-dialog__search">
              <Search size={14} aria-hidden />
              <input
                ref={searchRef}
                value={query}
                placeholder="Search teammates by name or id"
                onChange={(event) => setQuery(event.target.value)}
              />
            </label>
            <ul className="planner-assign-dialog__list" role="listbox" aria-label="Team members">
              {filtered.length === 0 ? (
                <li className="planner-assign-dialog__empty">
                  No matching teammate. Invite people from the Team panel first.
                </li>
              ) : (
                filtered.map((member) => {
                  const selected = member.userId === pickedUserId
                  return (
                    <li key={member.userId}>
                      <button
                        type="button"
                        role="option"
                        aria-selected={selected}
                        className={`planner-assign-dialog__member${selected ? ' is-selected' : ''}`}
                        onClick={() => setPickedUserId(member.userId)}
                      >
                        <span className="planner-assign-dialog__avatar" aria-hidden>
                          {member.avatarUrl
                            ? <img src={member.avatarUrl} alt="" />
                            : <UserRound size={14} />}
                        </span>
                        <span className="planner-assign-dialog__member-main">
                          <span className="planner-assign-dialog__member-name">
                            {member.displayName || member.userId}
                          </span>
                          {member.email && member.email !== member.userId && (
                            <span className="planner-assign-dialog__member-email">
                              {member.email}
                            </span>
                          )}
                        </span>
                        {member.role && (
                          <span className="planner-assign-dialog__member-role">{member.role}</span>
                        )}
                      </button>
                    </li>
                  )
                })
              )}
            </ul>

            <section className="planner-assign-dialog__summary" aria-label="What happens after assigning">
              <h3>What this does</h3>
              <ul>
                <li>The node is replaced with a sub-canvas owned by the assignee.</li>
                <li>
                  You keep a read-only reference to the I/O contract; the
                  sub-canvas internals become the assignee's to edit.
                </li>
                <li>
                  Active sessions bound to this node move with the work to
                  the new sub-canvas (billing stays with this team).
                </li>
              </ul>
              {frozenIOContract && (
                <details className="planner-assign-dialog__contract">
                  <summary>Frozen I/O contract (v{frozenIOContract.version})</summary>
                  <pre>{JSON.stringify(frozenIOContract, null, 2)}</pre>
                </details>
              )}
            </section>
          </div>
        )}

        {phase === 'confirm-public' && picked && (
          <PublicConfirmation picked={picked} errorMessage={errorMessage} />
        )}

        {errorMessage && phase === 'pick' && (
          <div className="planner-assign-dialog__error" role="alert">
            <AlertTriangle size={14} aria-hidden />
            <span>{errorMessage}</span>
          </div>
        )}

        <footer className="planner-assign-dialog__footer">
          {phase === 'pick' ? (
            <>
              <button type="button" onClick={onCancel} disabled={busy} className="planner-assign-dialog__secondary">
                Cancel
              </button>
              <button
                type="button"
                onClick={handleNextFromPicker}
                disabled={!picked || busy}
                className="planner-assign-dialog__primary"
              >
                Continue
              </button>
            </>
          ) : (
            <>
              <button
                type="button"
                onClick={() => setPhase('pick')}
                disabled={busy}
                className="planner-assign-dialog__secondary"
              >
                Back
              </button>
              <button
                type="button"
                onClick={handleFinalConfirm}
                disabled={busy}
                className="planner-assign-dialog__primary"
              >
                {busy ? 'Assigning…' : 'Assign'}
              </button>
            </>
          )}
        </footer>
      </div>
    </div>
  )
}

function PublicConfirmation({ picked, errorMessage }: { picked: TeamMember; errorMessage?: string | null }) {
  return (
    <div className="planner-assign-dialog__body planner-assign-dialog__body--upgrade">
      <h3>Confirm assignment</h3>
      <p className="planner-assign-dialog__warning-lead">
        Assign this node to <strong>{picked.displayName || picked.userId}</strong>. They
        will own the new sub-canvas; you will keep a reference to its I/O contract.
      </p>
      {errorMessage && (
        <div className="planner-assign-dialog__error" role="alert">
          <AlertTriangle size={14} aria-hidden />
          <span>{errorMessage}</span>
        </div>
      )}
    </div>
  )
}

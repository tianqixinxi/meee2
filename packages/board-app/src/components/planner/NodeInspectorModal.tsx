import {
  AlertTriangle,
  ExternalLink,
  FileText,
  Layers,
  Route,
  Signpost,
  Sparkles,
  UserRound,
  X,
} from 'lucide-react'
import { useState } from 'react'
import {
  bindPlannerNodeInput,
  proposePlannerGraphChange,
} from '../../api'
import type { TeamMember } from '../../api'
import type {
  ContextSource,
  NodeStateSnapshot,
  PlanProposal,
  PlannerAccess,
  PlannerGraphState,
  PlanningNode,
} from '../../types'
import type { IOArtifactVisibility } from './plannerGraphAdapter'

interface Props {
  node: PlanningNode
  canvasId: string
  variant?: 'board' | 'template'
  state: NodeStateSnapshot | null
  doerLabel?: string
  access?: PlannerAccess | null
  teamMembers?: TeamMember[]
  onClose: () => void
  onOpenSubCanvas?: (canvasId: string) => void
  onProposalCreated?: (proposal: PlanProposal) => void
  onGraphStateChanged?: (state: PlannerGraphState) => void
  onSendToAI?: (message: string) => void
  showOwnerInfo?: boolean
  visibleIOArtifacts?: IOArtifactVisibility
  onToggleIOArtifact?: (
    nodeId: string,
    direction: keyof IOArtifactVisibility,
    item: string,
    visible: boolean,
  ) => void
}

export function NodeInspectorModal({
  node,
  canvasId,
  variant = 'board',
  state,
  doerLabel,
  access = null,
  teamMembers = [],
  onClose,
  onOpenSubCanvas,
  onProposalCreated,
  onGraphStateChanged,
  onSendToAI,
  showOwnerInfo = true,
  visibleIOArtifacts = { inputs: [], outputs: [] },
  onToggleIOArtifact,
}: Props) {
  const [assignOpen, setAssignOpen] = useState(false)
  const [editingInput, setEditingInput] = useState<string | null>(null)
  const [inputDraftValue, setInputDraftValue] = useState('')
  const [actionBusy, setActionBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)
  const isTemplate = variant === 'template'
  const nodeKind = node.nodeKind ?? (node.source === 'session' ? 'session' : node.subCanvasId ? 'subCanvas' : 'step')
  const runState = state?.runState ?? node.status
  const blockers = isTemplate
    ? []
    : state?.blockers?.length
      ? state.blockers
      : node.status === 'blocked' && node.blockedReason?.trim()
        ? [node.blockedReason.trim()]
        : []
  const inputs = dedupeStrings(node.schema?.inputs ?? [])
  const outputs = dedupeStrings(node.schema?.outputs ?? [])
  const inputBindings = inputBindingMap(inputs, node.contextSources ?? [])
  const artifactRefs = dedupeStrings([...(node.artifactRefs ?? []), ...(state?.artifactRefs ?? [])])
  const outputItems = dedupeStrings([...outputs, ...artifactRefs])
  const nextAction = node.nextAction?.trim() || null
  const responsibleId = node.doerId?.trim() ?? ''
  const responsibleMember = teamMembers.find((member) => member.userId === responsibleId)
  const responsibleFallback = (doerLabel ?? node.doerId).trim()
  const responsibleLabel = (responsibleMember?.displayName ?? responsibleFallback) || 'Unassigned'
  const role = access?.role ?? 'owner'
  const canAssignOwner = role === 'owner'
  const canShowIOArtifactSwitches = nodeKind === 'step'
  const canUseStepActions = nodeKind === 'step'
  const permissionTooltip = canAssignOwner ? undefined : 'Only the canvas owner can assign this node.'

  const runProposalAction = (work: () => Promise<PlanProposal | null>) => {
    setActionBusy(true)
    setActionError(null)
    work()
      .then((proposal) => {
        setActionBusy(false)
        if (!proposal) {
          setActionError('No proposal returned for this action.')
          return
        }
        onProposalCreated?.(proposal)
        onClose()
      })
      .catch((err) => {
        setActionBusy(false)
        setActionError((err as Error).message || 'Action failed')
      })
  }

  const sendNodeActionToAI = (operation: 'revise' | 'expand-sub-canvas') => {
    onSendToAI?.(buildNodeActionPrompt(node, operation))
    onClose()
  }

  const startEditingInput = (item: string) => {
    setActionError(null)
    setEditingInput(item)
    setInputDraftValue(inputBindings[item]?.reference ?? '')
  }

  const saveInputBinding = (item: string) => {
    const reference = inputDraftValue.trim()
    if (!reference) {
      setActionError('Input value cannot be empty.')
      return
    }
    setActionBusy(true)
    setActionError(null)
    bindPlannerNodeInput(canvasId, node.id, {
      input: item,
      reference,
      kind: inferContextSourceKind(reference, item),
      title: item,
    })
      .then((state) => {
        setActionBusy(false)
        onGraphStateChanged?.(state)
        setEditingInput(null)
      })
      .catch((err) => {
        setActionBusy(false)
        setActionError((err as Error).message || 'Input value was not saved')
      })
  }

  return (
    <div
      className="planner-node-modal-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <div className="planner-node-modal planner-node-modal--info" role="dialog" aria-modal="true" aria-label="Node info">
        <button type="button" className="planner-node-modal__close" onClick={onClose} aria-label="Close node details">
          <X size={15} aria-hidden />
        </button>

        <div className="planner-node-modal__header">
          <div className="planner-node-modal__header-tags">
            {!isTemplate && <span className={`planner-node-modal__state planner-node-modal__state--${runState}`}>{runState}</span>}
            <span className="planner-node-modal__kind">{nodeKind}</span>
          </div>
          <h2>{node.title}</h2>
        </div>

        {blockers.length > 0 && (
          <div className="planner-node-modal__blockers">
            {blockers.map((blocker) => (
              <span key={blocker}><AlertTriangle size={12} aria-hidden />{blocker}</span>
            ))}
          </div>
        )}

        <div className="planner-node-modal__info-grid">
          {!isTemplate && (
            <InfoTile label="Status" value={displayRunState(String(runState))} />
          )}
          {showOwnerInfo && <InfoTile label="Owner" value={responsibleLabel} />}
          <InfoTile label="Gate" value={gateModeLabel(node)} />
          <InfoTile label="Type" value={nodeKind} />
        </div>

        <div className="planner-node-modal__section">
          <h3><Route size={13} aria-hidden /> Schema</h3>
          <div className="planner-node-modal__schema">
            <SchemaList
              title="Inputs"
              items={inputs}
              empty="No required input"
              visibleItems={visibleIOArtifacts.inputs}
              switchesEnabled={canShowIOArtifactSwitches}
              onToggle={(item, visible) => onToggleIOArtifact?.(node.id, 'inputs', item, visible)}
              inputBindings={inputBindings}
              editingItem={editingInput}
              draftValue={inputDraftValue}
              actionBusy={actionBusy}
              onStartEdit={startEditingInput}
              onCancelEdit={() => setEditingInput(null)}
              onDraftChange={setInputDraftValue}
              onSaveInput={saveInputBinding}
            />
            <SchemaList
              title="Outputs"
              items={outputItems}
              empty="No expected output"
              visibleItems={visibleIOArtifacts.outputs}
              switchesEnabled={canShowIOArtifactSwitches}
              onToggle={(item, visible) => onToggleIOArtifact?.(node.id, 'outputs', item, visible)}
            />
            <div className="planner-node-modal__schema-row planner-node-modal__schema-row--wide">
              <span>Do what</span>
              <strong>{node.schema?.goal || nextAction || 'Discuss with meee2 AI to define this step.'}</strong>
            </div>
          </div>
        </div>

        {nextAction && !isTemplate && (
          <div className="planner-node-modal__next-action">
            <Signpost size={13} aria-hidden />
            <div><em>Next step</em><strong>{nextAction}</strong></div>
          </div>
        )}

        {canUseStepActions && (
          <div className="planner-node-modal__section">
            <h3><Sparkles size={13} aria-hidden /> Actions</h3>
            <div className="planner-node-actions__buttons">
              <button
                type="button"
                className="primary"
                disabled={actionBusy}
                onClick={() => sendNodeActionToAI('revise')}
              >
                <Sparkles size={12} aria-hidden /> Revise with AI
              </button>
              <button
                type="button"
                disabled={actionBusy}
                onClick={() => sendNodeActionToAI('expand-sub-canvas')}
              >
                <Layers size={12} aria-hidden /> Expand sub-canvas
              </button>
              {showOwnerInfo && (
                <button
                  type="button"
                  disabled={actionBusy || !canAssignOwner}
                  title={permissionTooltip}
                  onClick={() => {
                    setActionError(null)
                    setAssignOpen((value) => !value)
                  }}
                >
                  <UserRound size={12} aria-hidden /> Assign owner
                </button>
              )}
            </div>
            {showOwnerInfo && assignOpen && (
              <div className="planner-node-actions__panel">
                {teamMembers.length === 0 ? (
                  <p className="planner-node-modal__empty">No team members available to assign.</p>
                ) : (
                  <div className="planner-node-actions__members">
                    {teamMembers.map((member) => {
                      const current = member.userId === responsibleId
                      return (
                        <button
                          key={member.userId}
                          type="button"
                          className={`planner-node-actions__member${current ? ' is-current' : ''}`}
                          disabled={actionBusy || current}
                          onClick={() => {
                            runProposalAction(() =>
                              proposePlannerGraphChange(canvasId, {
                                summary: `Assign ${member.displayName} as owner of ${node.title}`,
                                changes: [{ kind: 'updateNode', nodeId: node.id, doerId: member.userId }],
                              }),
                            )
                          }}
                        >
                          <span className="planner-node-modal__avatar" aria-hidden>
                            {member.avatarUrl ? <img src={member.avatarUrl} alt="" /> : <UserRound size={12} />}
                          </span>
                          <span>{member.displayName}</span>
                          {current && <em>current</em>}
                        </button>
                      )
                    })}
                  </div>
                )}
              </div>
            )}
            {actionError && <p className="planner-node-actions__error">{actionError}</p>}
          </div>
        )}

        {node.subCanvasId && (
          <button
            type="button"
            className="planner-node-modal__subcanvas"
            onClick={() => {
              onOpenSubCanvas?.(node.subCanvasId as string)
              onClose()
            }}
          >
            <ExternalLink size={13} aria-hidden /> Open sub-flow
          </button>
        )}
      </div>
    </div>
  )
}

function InfoTile({ label, value }: { label: string; value: string }) {
  return (
    <div className="planner-node-modal__info-tile">
      <em>{label}</em>
      <strong>{value}</strong>
    </div>
  )
}

function SchemaList({
  title,
  items,
  empty,
  visibleItems = [],
  switchesEnabled = false,
  onToggle,
  inputBindings,
  editingItem,
  draftValue = '',
  actionBusy = false,
  onStartEdit,
  onCancelEdit,
  onDraftChange,
  onSaveInput,
}: {
  title: string
  items: string[]
  empty: string
  visibleItems?: string[]
  switchesEnabled?: boolean
  onToggle?: (item: string, visible: boolean) => void
  inputBindings?: Record<string, ContextSource>
  editingItem?: string | null
  draftValue?: string
  actionBusy?: boolean
  onStartEdit?: (item: string) => void
  onCancelEdit?: () => void
  onDraftChange?: (value: string) => void
  onSaveInput?: (item: string) => void
}) {
  const normalized = dedupeStrings(items)
  const visibleSet = new Set(visibleItems.map((item) => item.trim()).filter(Boolean))
  const canEditInputs = Boolean(inputBindings && onStartEdit && onDraftChange && onSaveInput)
  const editingBinding = editingItem ? inputBindings?.[editingItem] : null
  return (
    <div className="planner-node-modal__schema-row">
      <span>{title}</span>
      {normalized.length > 0 ? (
        <div className="planner-node-modal__schema-chips">
          {normalized.map((item) => {
            const checked = visibleSet.has(item)
            const binding = inputBindings?.[item]
            const isEditing = editingItem === item
            return (
              <div key={item} className={`planner-node-modal__schema-item${isEditing ? ' is-editing' : ''}`}>
                <div className="planner-node-modal__schema-item-main">
                  <strong title={item}><FileText size={11} aria-hidden />{compactLabel(item)}</strong>
                  {canEditInputs && (
                    <span className={`planner-node-modal__input-value${binding ? ' is-set' : ''}`}>
                      {binding ? compactLabel(binding.reference) : 'not set'}
                    </span>
                  )}
                </div>
                {switchesEnabled && (
                  <button
                    type="button"
                    className={`planner-node-modal__switch${checked ? ' is-on' : ''}`}
                    aria-pressed={checked}
                    aria-label={`${checked ? 'Hide' : 'Show'} ${item} as artifact node`}
                    onClick={() => onToggle?.(item, !checked)}
                  >
                    <span />
                  </button>
                )}
                {canEditInputs && !isEditing && (
                  <button
                    type="button"
                    className="planner-node-modal__input-edit"
                    disabled={actionBusy}
                    onClick={() => onStartEdit?.(item)}
                  >
                    {binding ? 'Edit' : 'Set'}
                  </button>
                )}
              </div>
            )
          })}
          {canEditInputs && editingItem && (
            <div className="planner-node-modal__input-editor">
              <div className="planner-node-modal__input-editor-head">
                <span>{compactLabel(editingItem)}</span>
                {editingBinding && <em>{compactLabel(editingBinding.reference)}</em>}
              </div>
              <textarea
                value={draftValue}
                onChange={(event) => onDraftChange?.(event.target.value)}
                placeholder="Paste document URL or artifact reference"
                autoFocus
                rows={4}
              />
              <div className="planner-node-modal__input-editor-actions">
                <button
                  type="button"
                  disabled={actionBusy}
                  onClick={onCancelEdit}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  className="primary"
                  disabled={actionBusy || draftValue.trim().length === 0}
                  onClick={() => onSaveInput?.(editingItem)}
                >
                  Save input
                </button>
              </div>
            </div>
          )}
        </div>
      ) : (
        <strong>{empty}</strong>
      )}
    </div>
  )
}

function inputBindingMap(inputs: string[], sources: ContextSource[]): Record<string, ContextSource> {
  const result: Record<string, ContextSource> = {}
  const inputKeys = new Map(inputs.map((input) => [normalizeKey(input), input]))
  for (const source of sources) {
    const input = inputKeys.get(normalizeKey(source.title))
    if (input) result[input] = source
  }
  return result
}

function normalizeKey(value: string): string {
  return value.trim().toLowerCase()
}

function inferContextSourceKind(reference: string, title: string): ContextSource['kind'] {
  const normalized = `${title} ${reference}`.toLowerCase()
  if (normalized.startsWith('artifact:') || normalized.includes('artifact://')) return 'artifact'
  if (normalized.startsWith('repo:') || normalized.startsWith('git:') || normalized.includes('github.com')) return 'repository'
  if (normalized.includes('lark') || normalized.includes('feishu') || normalized.includes('doc')) return 'document'
  if (normalized.startsWith('http://') || normalized.startsWith('https://')) return 'web'
  return 'document'
}

function dedupeStrings(values: Array<string | null | undefined>): string[] {
  const seen = new Set<string>()
  const result: string[] = []
  for (const value of values) {
    const normalized = value?.trim()
    if (!normalized || seen.has(normalized)) continue
    seen.add(normalized)
    result.push(normalized)
  }
  return result
}

function buildNodeActionPrompt(node: PlanningNode, operation: 'revise' | 'expand-sub-canvas'): string {
  const tag = `@node:${node.id}`
  const opTag = operation === 'revise' ? '#revise' : '#expand-sub-canvas'
  const input = (node.schema?.inputs ?? []).join(', ') || 'none'
  const output = (node.schema?.outputs ?? []).join(', ') || 'none'
  const doWhat = node.schema?.goal || node.nextAction || node.title
  return [
    `${tag} ${opTag}`,
    `Node: ${node.title}`,
    `Inputs: ${input}`,
    `Outputs: ${output}`,
    `Do what: ${doWhat}`,
    '',
    operation === 'revise'
      ? 'Revise this node with me.'
      : 'Expand this node into a sub-canvas with me.',
  ].join('\n')
}

function compactLabel(value: string): string {
  const withoutQuery = value.trim().split('?')[0]
  const parts = withoutQuery.split(/[/:#]/).filter(Boolean)
  return parts[parts.length - 1]?.trim() || value
}

function gateModeLabel(node: PlanningNode): 'Human' | 'Auto' {
  if (node.executionMode === 'human') return 'Human'
  if ((node.gate?.approvers ?? []).length > 0) return 'Human'
  return 'Auto'
}

function displayRunState(runState: string): string {
  switch (runState) {
    case 'dispatched':
      return 'starting'
    case 'ready_to_start':
      return 'ready to start'
    case 'gate-wait':
      return 'review output'
    default:
      return runState.replace(/_/g, ' ')
  }
}

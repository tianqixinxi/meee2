import { Background, ReactFlow, ReactFlowProvider } from '@xyflow/react'
import { Check, ChevronDown, Eye, Info, Send, X } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import {
  fetchLocalAssistantSessionMessages,
  type LocalAssistantSessionMessage,
} from '../../api'
import type { PlanProposal, PlannerAccess } from '../../types'
import { PlannerNodeCard } from './PlannerNodeCard'
import type { PlannerGraphEdge, PlannerGraphNode } from './plannerGraphAdapter'

interface Props {
  canvasId: string
  proposal: PlanProposal | null
  variant?: 'board' | 'template'
  previewGraph: { nodes: PlannerGraphNode[]; edges: PlannerGraphEdge[] }
  busy: boolean
  error: string | null
  access: PlannerAccess | null
  nodeCount: number
  hasActionableDrift: boolean
  onSubmit: (message: string) => void
  onApproveAndApply: () => void
  onReject: () => void
  draftMessage?: { id: number; text: string } | null
  clearRevision?: number
  /** Incremented when a node action (dispatch/bind/…) creates a proposal —
   *  triggers the review modal so the action has a visible result. */
  reviewRequestTick?: number
}

const reviewNodeTypes = {
  plannerNode: PlannerNodeCard,
}

interface PlannerChatMessage {
  id: string
  role: 'user' | 'planner' | 'injected'
  markdown: string
  meta?: string[]
}

export function PlannerProposalPanel({
  canvasId,
  proposal,
  variant = 'board',
  previewGraph,
  busy,
  error,
  access,
  nodeCount,
  hasActionableDrift,
  onSubmit,
  onApproveAndApply,
  onReject,
  draftMessage = null,
  clearRevision = 0,
  reviewRequestTick,
}: Props) {
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const handledClearRevisionRef = useRef(0)
  const [message, setMessage] = useState('')
  const [history, setHistory] = useState<PlannerChatMessage[]>(() => readChatHistory(canvasId))
  const [historyOpen, setHistoryOpen] = useState(false)
  const [reviewOpen, setReviewOpen] = useState(false)
  const [thinking, setThinking] = useState(false)
  const isTemplate = variant === 'template'

  useEffect(() => {
    setHistory(readChatHistory(canvasId))
    setHistoryOpen(false)
  }, [canvasId])

  useEffect(() => {
    let cancelled = false
    fetchLocalAssistantSessionMessages(canvasId)
      .then(({ sessionId, messages }) => {
        if (cancelled) return
        setHistory((current) => mergeClaudeSessionMessages(current, sessionId, messages))
      })
      .catch(() => {
        // Local Claude transcript sync is best-effort; local draft history still works.
      })
    return () => {
      cancelled = true
    }
  }, [canvasId])

  useEffect(() => {
    if (busy) return
    let cancelled = false
    fetchLocalAssistantSessionMessages(canvasId)
      .then(({ sessionId, messages }) => {
        if (cancelled) return
        setHistory((current) => mergeClaudeSessionMessages(current, sessionId, messages))
      })
      .catch(() => {
        // The session file may not exist yet; keep the visible chat unchanged.
      })
    return () => {
      cancelled = true
    }
  }, [busy, canvasId])

  useEffect(() => {
    writeChatHistory(canvasId, history)
  }, [canvasId, history])

  useEffect(() => {
    if (clearRevision <= 0) return
    if (handledClearRevisionRef.current === clearRevision) return
    handledClearRevisionRef.current = clearRevision
    clearChatHistory(canvasId)
    setHistory([])
    setReviewOpen(false)
    setThinking(false)
  }, [canvasId, clearRevision])

  useEffect(() => {
    if (!proposal) return
    setThinking(false)
    const nextMessage: PlannerChatMessage = {
      id: `proposal:${proposal.id}`,
      role: 'planner',
      markdown: proposalChatMarkdown(proposal),
      meta: [
        proposal.status,
        `${proposal.changes.length} ${proposal.changes.length === 1 ? 'change' : 'changes'}`,
      ].filter(Boolean),
    }
    setHistory((current) => upsertChatMessage(current, nextMessage))
  }, [proposal])

  useEffect(() => {
    if (error) setThinking(false)
  }, [error])

  useEffect(() => {
    if (!busy) setThinking(false)
  }, [busy])

  // A node action just produced a proposal — surface it immediately.
  useEffect(() => {
    if (reviewRequestTick && reviewRequestTick > 0) setReviewOpen(true)
  }, [reviewRequestTick])

  useEffect(() => {
    if (!draftMessage) return
    setMessage(draftMessage.text)
    window.requestAnimationFrame(() => textareaRef.current?.focus())
  }, [draftMessage])

  const canCreateProposal = access?.canCreateProposal ?? true
  const canSend = (message.trim().length > 0 || hasActionableDrift) && !busy && canCreateProposal
  const guidance = plannerGuidance(nodeCount, hasActionableDrift)
  const submitMessage = () => {
    if (!canSend) return
    const next = message.trim()
    const displayMessage = next || 'Inspect the current graph drift.'
    setHistory((current) => [
      ...current,
      {
        id: `user:${Date.now()}:${Math.random().toString(36).slice(2)}`,
        role: 'user',
        markdown: displayMessage,
      },
    ])
    setThinking(true)
    onSubmit(next)
    setMessage('')
  }

  return (
    <aside className="planner-proposal-panel">
      <div className="planner-dialog">
        <div className="planner-dialog__messages">
          <WorkflowGuide
            proposal={proposal}
            nodeCount={nodeCount}
            hasActionableDrift={hasActionableDrift}
          />
          {error && <div className="planner-dialog__message planner-dialog__message--error">{error}</div>}
          {history.length > 0 && (
            <div className={`planner-dialog__history${historyOpen ? ' is-open' : ''}`}>
              <button
                type="button"
                className="planner-dialog__history-toggle"
                onClick={() => setHistoryOpen((value) => !value)}
                aria-expanded={historyOpen}
              >
                <ChevronDown size={13} aria-hidden />
                <span>History</span>
                <em>{history.length}</em>
              </button>
              {historyOpen && history.map((item) => (
                <div
                  key={item.id}
                  className={`planner-dialog__message planner-dialog__message--${item.role === 'user' ? 'user' : item.role === 'injected' ? 'injected' : 'planner'}`}
                >
                  {item.meta && item.meta.length > 0 && (
                    <div className="planner-dialog__message-meta">
                      {item.meta.map((meta) => <span key={meta}>{meta}</span>)}
                    </div>
                  )}
                  <MarkdownMessage markdown={item.markdown} />
                  {item.role === 'planner' && item.id === `proposal:${proposal?.id ?? ''}` && (
                    <div className="planner-dialog__actions planner-dialog__actions--single">
                      <button
                        type="button"
                        className="planner-proposal__preview"
                        disabled={busy || proposal?.status === 'applied' || proposal?.status === 'rejected'}
                        onClick={() => setReviewOpen(true)}
                      >
                        <Eye size={14} aria-hidden />
                        Review changes
                      </button>
                    </div>
                  )}
                </div>
              ))}
            </div>
          )}
          {thinking && (
            <div className="planner-dialog__message planner-dialog__message--planner planner-dialog__message--thinking">
              <span>meee2 AI is thinking</span>
              <span className="planner-thinking-dots" aria-hidden>
                <i />
                <i />
                <i />
              </span>
            </div>
          )}
          {proposal && !history.some((item) => item.id === `proposal:${proposal.id}`) ? (
            <div className="planner-dialog__message planner-dialog__message--planner">
              <div className="planner-dialog__message-meta">
                <span>{proposal.status}</span>
                <span>{proposal.changes.length} changes</span>
              </div>
              <MarkdownMessage markdown={proposalChatMarkdown(proposal)} />
              <div className="planner-dialog__actions planner-dialog__actions--single">
                <button
                  type="button"
                  className="planner-proposal__preview"
                  disabled={busy || proposal.status === 'applied' || proposal.status === 'rejected'}
                  onClick={() => setReviewOpen(true)}
                >
                  <Eye size={14} aria-hidden />
                  Review changes
                </button>
              </div>
            </div>
          ) : history.length === 0 && (
            <div className="planner-dialog__hint" role="note">
              <div className="planner-dialog__hint-label">
                <Info size={11} aria-hidden />
                <span>How this works</span>
              </div>
              <MarkdownMessage markdown={guidance} />
            </div>
          )}
        </div>
      </div>

      <div className="planner-dialog__composer">
        <textarea
          ref={textareaRef}
          value={message}
          onChange={(event) => setMessage(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
              event.preventDefault()
              submitMessage()
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
            onClick={submitMessage}
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
          <div className="planner-proposal-modal" role="dialog" aria-modal="true" aria-label="Review changes">
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
              <p>Preview only. The canvas changes after you apply.</p>
            </div>
            <div className="planner-proposal-modal__body">
              <section className="planner-proposal-modal__changes" aria-label="Proposed changes">
                <MarkdownMessage markdown={proposalMarkdown(proposal)} />
              </section>
              <section className="planner-proposal-modal__preview-canvas" aria-label="Preview canvas">
                <div className="planner-proposal-modal__preview-head">
                  <span>Preview</span>
                  <em>{proposal.changes.length} {proposal.changes.length === 1 ? 'change' : 'changes'}</em>
                </div>
                <div className="planner-proposal-modal__preview-viewport">
                  {previewGraph.nodes.length > 0 ? (
                    <ReactFlowProvider>
                      <ReactFlow
                        nodes={previewGraph.nodes}
                        edges={previewGraph.edges}
                        nodeTypes={reviewNodeTypes}
                        nodesDraggable={false}
                        nodesConnectable={false}
                        elementsSelectable={false}
                        panOnDrag
                        zoomOnScroll
                        fitView
                        minZoom={0.25}
                        maxZoom={1.2}
                        proOptions={{ hideAttribution: true }}
                      >
                        <Background color="rgba(168, 165, 155, 0.10)" gap={32} />
                      </ReactFlow>
                    </ReactFlowProvider>
                  ) : (
                    <div className="planner-proposal-modal__preview-empty">No preview available</div>
                  )}
                </div>
              </section>
            </div>
            <div className="planner-proposal-modal__actions">
              <button
                type="button"
                className="primary"
                disabled={busy || proposal.status === 'applied' || proposal.status === 'rejected' || !canApproveAndApply(proposal, access)}
                onClick={() => {
                  onApproveAndApply()
                  setReviewOpen(false)
                }}
                title={isTemplate ? 'Write the previewed changes into this template.' : 'Apply these changes to the canvas.'}
              >
                <Check size={14} aria-hidden />
                {isTemplate ? 'Apply to template' : 'Apply to canvas'}
              </button>
              <button
                type="button"
                disabled={busy || proposal.status === 'applied' || proposal.status === 'rejected' || !access?.canRejectProposal}
                onClick={() => {
                  onReject()
                  setReviewOpen(false)
                }}
              >
                {isTemplate ? 'Discard' : 'Reject'}
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
  nodeCount,
  hasActionableDrift,
}: {
  proposal: PlanProposal | null
  nodeCount: number
  hasActionableDrift: boolean
}) {
  const copy = workflowGuideCopy(proposal, nodeCount, hasActionableDrift)
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
  nodeCount: number,
  hasActionableDrift: boolean,
): { title: string; body: string } {
  if (proposal?.status === 'pending') {
    return {
      title: 'Review these changes',
      body: 'Open the preview modal. The canvas is unchanged until you apply.',
    }
  }
  if (proposal?.status === 'approved') {
    return {
      title: 'Apply these changes',
      body: 'This proposal is already approved. Apply it to update the canvas.',
    }
  }
  if (nodeCount === 0) {
    return {
      title: 'Co-create the canvas with meee2 AI',
      body: 'Describe the outcome you want and meee2 AI will shape the canvas with you.',
    }
  }
  if (hasActionableDrift) {
    return {
      title: 'Inspect blocked or review nodes',
      body: 'Ask meee2 AI to inspect drift, then approve a repair proposal. Open a node for details or outputs.',
    }
  }
  return {
    title: 'Start the next step',
    body: 'Keep talking with meee2 AI or open a node to adjust details and attach outputs.',
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

function chatHistoryKey(canvasId: string): string {
  return `meee2.planner.chatHistory.${canvasId}.v1`
}

function readChatHistory(canvasId: string): PlannerChatMessage[] {
  if (typeof window === 'undefined') return []
  try {
    const raw = window.localStorage.getItem(chatHistoryKey(canvasId))
    if (!raw) return []
    const parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    const history = parsed
      .map((item): PlannerChatMessage | null => {
        if (!item || typeof item !== 'object') return null
        if (item.role !== 'user' && item.role !== 'planner' && item.role !== 'injected') return null
        if (typeof item.id !== 'string' || typeof item.markdown !== 'string') return null
        const meta = Array.isArray(item.meta)
          ? item.meta.filter((value: unknown): value is string => typeof value === 'string')
          : undefined
        return {
          id: item.id,
          role: item.role,
          markdown: item.markdown,
          meta,
        }
      })
      .filter((item): item is PlannerChatMessage => Boolean(item))
    return normalizeChatHistoryOrder(history).slice(-80)
  } catch {
    return []
  }
}

function writeChatHistory(canvasId: string, history: PlannerChatMessage[]) {
  if (typeof window === 'undefined') return
  try {
    window.localStorage.setItem(chatHistoryKey(canvasId), JSON.stringify(normalizeChatHistoryOrder(history).slice(-80)))
  } catch {
    // History persistence is best-effort; chat actions still work without it.
  }
}

function clearChatHistory(canvasId: string) {
  if (typeof window === 'undefined') return
  try {
    window.localStorage.removeItem(chatHistoryKey(canvasId))
  } catch {
    // History persistence is best-effort.
  }
}

function upsertChatMessage(history: PlannerChatMessage[], next: PlannerChatMessage): PlannerChatMessage[] {
  const index = history.findIndex((item) => item.id === next.id)
  if (index < 0) return normalizeChatHistoryOrder([...history, next]).slice(-80)
  return normalizeChatHistoryOrder(history.map((item, itemIndex) => (itemIndex === index ? next : item)))
}

function mergeClaudeSessionMessages(
  history: PlannerChatMessage[],
  sessionId: string,
  messages: LocalAssistantSessionMessage[],
): PlannerChatMessage[] {
  const existingIds = new Set(history.map((item) => item.id))
  const existingContent = new Set(history.map(contentKey))
  const restored: PlannerChatMessage[] = []

  for (const message of messages) {
    const markdown = message.content.trim()
    if (!markdown) continue
    const role: PlannerChatMessage['role'] =
      message.role === 'assistant' ? 'planner' : message.role === 'injected' ? 'injected' : 'user'
    const id = message.id || `claude:${sessionId}:${role}:${restored.length}`
    if (existingIds.has(id)) continue
    const next: PlannerChatMessage = {
      id,
      role,
      markdown,
      meta: role === 'injected' ? ['session context'] : undefined,
    }
    const key = contentKey(next)
    if (existingContent.has(key)) continue
    existingContent.add(key)
    restored.push(next)
  }

  if (restored.length === 0) return normalizeChatHistoryOrder(history)
  return normalizeChatHistoryOrder([...history, ...restored]).slice(-80)
}

function normalizeChatHistoryOrder(history: PlannerChatMessage[]): PlannerChatMessage[] {
  const conversational = history.filter((item) => !isProposalChatMessage(item))
  const proposals = history.filter(isProposalChatMessage)
  return [...conversational, ...proposals]
}

function isProposalChatMessage(item: PlannerChatMessage): boolean {
  return item.id.startsWith('proposal:')
}

function contentKey(item: PlannerChatMessage): string {
  return `${item.role}:${item.markdown.replace(/\s+/g, ' ').trim()}`
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
    'It decides whether to reshape the canvas or inspect the current state.',
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
        node?.schema ? schemaSummary(node.schema) : null,
        node?.contextSources?.length ? `${node.contextSources.length} context` : null,
      ]))} |`
    }
    if (change.kind === 'attachArtifact') {
      const artifact = change.artifact
      return `| attach artifact | ${escapeMarkdown(artifact?.title ?? change.nodeId ?? 'Artifact')} | ${escapeMarkdown(changeDetails([
        artifact?.kind,
        artifact?.reference,
        artifact?.payload ? 'payload' : null,
      ]))} |`
    }
    const target = change.title ?? change.nodeId ?? 'Unknown node'
    const details = changeDetails([
      change.title ? `title -> ${change.title}` : null,
      change.status ? `status -> ${change.status}` : null,
      change.schema ? schemaSummary(change.schema) : null,
      change.contextSources ? `${change.contextSources.length} context source${change.contextSources.length === 1 ? '' : 's'}` : null,
      change.dependsOnNodeIds ? `${change.dependsOnNodeIds.length} deps` : null,
      change.doerId ? `doer -> ${change.doerId}` : null,
      change.subCanvasId ? `sub-canvas -> ${change.subCanvasId}` : null,
      change.nodeKind ? `kind -> ${change.nodeKind}` : null,
      change.executionMode ? `gate -> ${change.executionMode === 'human' ? 'Human' : 'Auto'}` : null,
      change.clearGate ? 'gate cleared' : null,
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
    if (change.kind === 'attachArtifact') {
      return `- Attach ${escapeMarkdown(change.artifact?.title ?? 'artifact')}`
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

function schemaSummary(schema: { inputs: string[]; outputs: string[]; goal: string }): string {
  const inputs = schema.inputs.length ? `in ${schema.inputs.join('+')}` : 'no input'
  const outputs = schema.outputs.length ? `out ${schema.outputs.join('+')}` : 'no output'
  return `schema ${inputs} -> ${outputs}; goal=${schema.goal}`
}

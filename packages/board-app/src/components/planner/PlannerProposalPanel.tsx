import { Background, ReactFlow, ReactFlowProvider } from '@xyflow/react'
import { Check, ChevronDown, Eye, Info, LayoutTemplate, Send, X } from 'lucide-react'
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
  canvasName: string
  canvasTask?: string
  proposal: PlanProposal | null
  variant?: 'board' | 'template'
  previewGraph: { nodes: PlannerGraphNode[]; edges: PlannerGraphEdge[] }
  busy: boolean
  error: string | null
  access: PlannerAccess | null
  nodeCount: number
  hasActionableDrift: boolean
  onSubmit: (message: string) => void
  onUseRecommendedTemplate?: () => void
  onApproveAndApply: () => void
  onReject: () => void
  draftMessage?: PlannerDraftMessage | null
  clearRevision?: number
  /** Incremented when a node action (dispatch/bind/…) creates a proposal —
   *  triggers the review modal so the action has a visible result. */
  reviewRequestTick?: number
  /** ENG-5: incremented when a planner turn produces an answer-only reply
   *  (no canvas mutation). Adds the reply to history and force-expands it
   *  so the user sees the textual answer instead of an empty turn. */
  answerOnlyReply?: { id: number; markdown: string } | null
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

interface PlannerDraftMessage {
  id: number
  text: string
  visibleText?: string
  contextLabel?: string
}

interface PlannerChatChoice {
  id: string
  label: string
  value: string
  description?: string
}

interface PlannerChatChoiceGroup {
  id: string
  question?: string
  choices: PlannerChatChoice[]
}

const PERSISTED_CHAT_LIMIT = 30
const SESSION_SYNC_LIMIT = 12
const VISIBLE_HISTORY_LIMIT = 12
const COLLAPSE_LINE_LIMIT = 8
const COLLAPSE_CHAR_LIMIT = 900

export function PlannerProposalPanel({
  canvasId,
  canvasName,
  canvasTask = '',
  proposal,
  variant = 'board',
  previewGraph,
  busy,
  error,
  access,
  nodeCount,
  hasActionableDrift,
  onSubmit,
  onUseRecommendedTemplate,
  onApproveAndApply,
  onReject,
  draftMessage = null,
  clearRevision = 0,
  reviewRequestTick,
  answerOnlyReply = null,
}: Props) {
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const handledClearRevisionRef = useRef(0)
  const handledAnswerOnlyIdRef = useRef(0)
  // ENG-5: first-Q&A auto-expand. We flip historyOpen=true the first time a
  // planner reply (proposal OR answer-only) lands following a user message,
  // so the textual answer doesn't stay buried in a collapsed panel — which
  // is the exact bug benjamin reported in the 2026-05-22 meeting.
  const autoExpandedRef = useRef(false)
  const [message, setMessage] = useState('')
  const [history, setHistory] = useState<PlannerChatMessage[]>(() => readChatHistory(canvasId))
  const [historyOpen, setHistoryOpen] = useState(false)
  const [reviewOpen, setReviewOpen] = useState(false)
  const [thinking, setThinking] = useState(false)
  const [draftContext, setDraftContext] = useState<{ text: string; label: string } | null>(null)
  const isTemplate = variant === 'template'

  useEffect(() => {
    setHistory(readChatHistory(canvasId))
    setHistoryOpen(false)
    autoExpandedRef.current = false
  }, [canvasId])

  useEffect(() => {
    let cancelled = false
    fetchLocalAssistantSessionMessages(canvasId, SESSION_SYNC_LIMIT)
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
    fetchLocalAssistantSessionMessages(canvasId, SESSION_SYNC_LIMIT)
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
    setHistory((current) => {
      const next = upsertChatMessage(current, nextMessage)
      // ENG-5: first-Q&A auto-expand. If the user has anything in history
      // (i.e. they just asked something), open the panel so they see the
      // answer alongside the canvas mutation summary.
      if (!autoExpandedRef.current && next.some((item) => item.role === 'user')) {
        autoExpandedRef.current = true
        setHistoryOpen(true)
      }
      return next
    })
  }, [proposal])

  // ENG-5: answer-only path. PlannerGraph hands us a markdown string when it
  // decides the user's message was a question that does not warrant a canvas
  // mutation. We add it to history and force-expand the panel on first reply.
  useEffect(() => {
    if (!answerOnlyReply) return
    if (handledAnswerOnlyIdRef.current === answerOnlyReply.id) return
    handledAnswerOnlyIdRef.current = answerOnlyReply.id
    setThinking(false)
    const nextMessage: PlannerChatMessage = {
      id: `answer:${answerOnlyReply.id}`,
      role: 'planner',
      markdown: answerOnlyReply.markdown,
      meta: ['answer'],
    }
    setHistory((current) => {
      const next = upsertChatMessage(current, nextMessage)
      if (!autoExpandedRef.current && next.some((item) => item.role === 'user')) {
        autoExpandedRef.current = true
        setHistoryOpen(true)
      }
      return next
    })
  }, [answerOnlyReply])

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
    const visibleText = draftMessage.visibleText ?? draftMessage.text
    setMessage(visibleText)
    setDraftContext(draftMessage.visibleText
      ? { text: draftMessage.text, label: draftMessage.contextLabel ?? 'Selected node' }
      : null)
    window.requestAnimationFrame(() => textareaRef.current?.focus())
  }, [draftMessage])

  const canCreateProposal = access?.canCreateProposal ?? true
  const canSend = (message.trim().length > 0 || hasActionableDrift) && !busy && canCreateProposal
  const templateRecommendation = recommendTemplate(canvasName, canvasTask, nodeCount, variant)
  const guidance = plannerGuidance(nodeCount, hasActionableDrift)
  const visibleHistory = history.slice(-VISIBLE_HISTORY_LIMIT)
  const hiddenHistoryCount = Math.max(0, history.length - visibleHistory.length)
  const submitMessage = () => {
    if (!canSend) return
    const next = message.trim()
    const displayMessage = next || 'Inspect the current graph drift.'
    const outboundMessage = draftContext
      ? `${draftContext.text}\n\nUser request: ${displayMessage}`
      : next
    setHistory((current) => [
      ...current,
      {
        id: `user:${Date.now()}:${Math.random().toString(36).slice(2)}`,
        role: 'user',
        markdown: displayMessage,
        meta: draftContext ? [draftContext.label] : undefined,
      },
    ])
    setThinking(true)
    onSubmit(outboundMessage)
    setMessage('')
    setDraftContext(null)
  }

  return (
    <aside className="planner-proposal-panel">
      <div className="planner-dialog">
        <div className="planner-dialog__messages">
          {templateRecommendation && !proposal && (
            <RecommendedTemplate
              recommendation={templateRecommendation}
              busy={busy}
              canCreateProposal={canCreateProposal}
              onUse={onUseRecommendedTemplate}
            />
          )}
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
              {historyOpen && hiddenHistoryCount > 0 && (
                <div className="planner-dialog__history-trimmed">
                  Showing latest {visibleHistory.length} messages. {hiddenHistoryCount} older {hiddenHistoryCount === 1 ? 'message is' : 'messages are'} kept out of this panel.
                </div>
              )}
              {historyOpen && visibleHistory.map((item) => (
                <PlannerChatMessageRow
                  key={item.id}
                  item={item}
                  proposal={proposal}
                  busy={busy}
                  onReview={() => setReviewOpen(true)}
                  onChoice={(value) => {
                    setMessage(value)
                    window.requestAnimationFrame(() => textareaRef.current?.focus())
                  }}
                />
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
              <MarkdownMessage markdown={proposalChatMarkdown(proposal)} collapsible />
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
        {draftContext && (
          <div className="planner-dialog__selection" aria-label="Selected context">
            <span>{draftContext.label}</span>
            <button
              type="button"
              onClick={() => setDraftContext(null)}
              aria-label="Clear selected node context"
            >
              <X size={12} aria-hidden />
            </button>
          </div>
        )}
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
          placeholder={hasActionableDrift ? 'Ask meee2 AI what to fix, or send empty to inspect drift' : 'Ask meee2 AI to adjust node inputs, outputs, artifacts, gates, or tasks'}
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

interface TemplateRecommendation {
  id: 'delivery-pipeline'
  title: string
  body: string
  label: string
}

function RecommendedTemplate({
  recommendation,
  busy,
  canCreateProposal,
  onUse,
}: {
  recommendation: TemplateRecommendation
  busy: boolean
  canCreateProposal: boolean
  onUse?: () => void
}) {
  return (
    <div className="planner-template-recommendation" aria-label="Recommended template">
      <div className="planner-template-recommendation__icon">
        <LayoutTemplate size={15} aria-hidden />
      </div>
      <div className="planner-template-recommendation__copy">
        <span>Recommended template</span>
        <strong>{recommendation.title}</strong>
        <p>{recommendation.body}</p>
      </div>
      <button
        type="button"
        disabled={busy || !canCreateProposal || !onUse}
        onClick={onUse}
        title={!canCreateProposal ? 'Only canvas owner can create topology proposals in this build.' : undefined}
      >
        <LayoutTemplate size={14} aria-hidden />
        {recommendation.label}
      </button>
    </div>
  )
}

function recommendTemplate(
  canvasName: string,
  canvasTask: string,
  nodeCount: number,
  variant: 'board' | 'template',
): TemplateRecommendation | null {
  if (variant === 'template' || nodeCount > 0) return null
  const task = readableCanvasTask(canvasName, canvasTask)
  return {
    id: 'delivery-pipeline',
    title: 'Delivery pipeline',
    body: `Best fit for turning ${task} into scoped steps, handoffs, review gates, and output artifacts.`,
    label: 'Use template',
  }
}

function readableCanvasTask(canvasName: string, canvasTask: string): string {
  const title = canvasName.trim()
  const context = canvasTask.trim()
  if (title && !isGenericCanvasTitle(title)) return `"${title}"`
  if (context && !context.startsWith('canvas:')) return `"${context}"`
  return 'this canvas task'
}

function isGenericCanvasTitle(title: string): boolean {
  return /^(untitled|new canvas|default canvas|personal canvas)$/i.test(title)
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

function PlannerChatMessageRow({
  item,
  proposal,
  busy,
  onReview,
  onChoice,
}: {
  item: PlannerChatMessage
  proposal: PlanProposal | null
  busy: boolean
  onReview: () => void
  onChoice: (value: string) => void
}) {
  const choiceBlocks = parseChoiceBlocks(item.markdown)
  return (
    <div
      className={`planner-dialog__message planner-dialog__message--${item.role === 'user' ? 'user' : item.role === 'injected' ? 'injected' : 'planner'}`}
    >
      {item.meta && item.meta.length > 0 && (
        <div className="planner-dialog__message-meta">
          {item.meta.map((meta) => <span key={meta}>{meta}</span>)}
        </div>
      )}
      <MarkdownMessage markdown={choiceBlocks.markdown} collapsible />
      {choiceBlocks.groups.length > 0 && (
        <div className="planner-dialog__choices" aria-label="Message choices">
          {choiceBlocks.groups.map((group) => (
            <div key={group.id} className="planner-dialog__choice-group">
              {group.question && <strong>{group.question}</strong>}
              <div className="planner-dialog__choice-list">
                {group.choices.map((choice) => (
                  <button
                    key={choice.id}
                    type="button"
                    onClick={() => onChoice(choice.value)}
                    title={choice.description}
                  >
                    <span>{choice.label}</span>
                    {choice.description && <small>{choice.description}</small>}
                  </button>
                ))}
              </div>
            </div>
          ))}
        </div>
      )}
      {item.role === 'planner' && item.id === `proposal:${proposal?.id ?? ''}` && (
        <div className="planner-dialog__actions planner-dialog__actions--single">
          <button
            type="button"
            className="planner-proposal__preview"
            disabled={busy || proposal?.status === 'applied' || proposal?.status === 'rejected'}
            onClick={onReview}
          >
            <Eye size={14} aria-hidden />
            Review changes
          </button>
        </div>
      )}
    </div>
  )
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
    return normalizeChatHistoryOrder(history).slice(-PERSISTED_CHAT_LIMIT)
  } catch {
    return []
  }
}

function writeChatHistory(canvasId: string, history: PlannerChatMessage[]) {
  if (typeof window === 'undefined') return
  try {
    const localHistory = history.filter((item) => !item.id.startsWith('claude:'))
    window.localStorage.setItem(chatHistoryKey(canvasId), JSON.stringify(normalizeChatHistoryOrder(localHistory).slice(-PERSISTED_CHAT_LIMIT)))
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
  if (index < 0) return normalizeChatHistoryOrder([...history, next]).slice(-PERSISTED_CHAT_LIMIT)
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
  return normalizeChatHistoryOrder([...history, ...restored]).slice(-PERSISTED_CHAT_LIMIT)
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

function MarkdownMessage({ markdown, collapsible = false }: { markdown: string; collapsible?: boolean }) {
  const [expanded, setExpanded] = useState(false)
  const displayMarkdown = normalizeJsonMarkdown(markdown)
  const shouldCollapse = collapsible && isLongMarkdown(displayMarkdown)
  return (
    <>
      <div className={`planner-markdown${shouldCollapse ? ' is-collapsible' : ''}${shouldCollapse && !expanded ? ' is-collapsed' : ''}`}>
        <ReactMarkdown remarkPlugins={[remarkGfm]}>
          {displayMarkdown}
        </ReactMarkdown>
      </div>
      {shouldCollapse && (
        <button
          type="button"
          className="planner-markdown__expand"
          onClick={() => setExpanded((value) => !value)}
        >
          {expanded ? 'Show less' : 'Show more'}
        </button>
      )}
    </>
  )
}

function isLongMarkdown(markdown: string): boolean {
  return markdown.length > COLLAPSE_CHAR_LIMIT || markdown.split('\n').length > COLLAPSE_LINE_LIMIT
}

function normalizeJsonMarkdown(markdown: string): string {
  const trimmed = markdown.trim()
  const fullJson = formatJsonIfObject(trimmed)
  if (fullJson) return `\`\`\`json\n${fullJson}\n\`\`\``

  return markdown.replace(/```([a-zA-Z0-9_-]*)?\s*\n([\s\S]*?)```/g, (raw, lang = '', body: string) => {
    const normalizedLang = lang.trim().toLowerCase()
    if (normalizedLang && normalizedLang !== 'json') return raw
    const formatted = formatJsonIfObject(body.trim())
    return formatted ? `\`\`\`json\n${formatted}\n\`\`\`` : raw
  })
}

function formatJsonIfObject(value: string): string | null {
  const trimmed = value.trim()
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return null
  try {
    const parsed = JSON.parse(trimmed) as unknown
    if (!parsed || (typeof parsed !== 'object' && !Array.isArray(parsed))) return null
    return JSON.stringify(parsed, null, 2)
  } catch {
    return null
  }
}

function parseChoiceBlocks(markdown: string): { markdown: string; groups: PlannerChatChoiceGroup[] } {
  const groups: PlannerChatChoiceGroup[] = []
  const nextMarkdown = markdown.replace(/```(?:choices|ask_user)\s*\n([\s\S]*?)\n```/g, (raw, jsonText: string) => {
    const parsed = parseChoiceGroup(jsonText, groups.length)
    if (!parsed) return raw
    groups.push(parsed)
    return ''
  }).trim()
  return { markdown: nextMarkdown || markdown, groups }
}

function parseChoiceGroup(raw: string, index: number): PlannerChatChoiceGroup | null {
  let data: unknown
  try {
    data = JSON.parse(raw)
  } catch {
    return null
  }
  if (!data || typeof data !== 'object') return null
  const item = data as Record<string, unknown>
  const question = typeof item.question === 'string'
    ? item.question
    : typeof item.prompt === 'string'
      ? item.prompt
      : undefined
  const rawChoices = Array.isArray(item.choices)
    ? item.choices
    : Array.isArray(item.options)
      ? item.options
      : Array.isArray(item.questions)
        ? choiceOptionsFromAskUserQuestions(item.questions)
        : []
  const choices = rawChoices
    .map((choice, choiceIndex): PlannerChatChoice | null => normalizeChoice(choice, choiceIndex))
    .filter((choice): choice is PlannerChatChoice => Boolean(choice))
  if (choices.length === 0) return null
  return {
    id: `choices:${index}`,
    question,
    choices,
  }
}

function choiceOptionsFromAskUserQuestions(rawQuestions: unknown[]): unknown[] {
  const first = rawQuestions.find((item) => item && typeof item === 'object') as Record<string, unknown> | undefined
  if (!first) return []
  if (Array.isArray(first.options)) return first.options
  if (Array.isArray(first.choices)) return first.choices
  return []
}

function normalizeChoice(raw: unknown, index: number): PlannerChatChoice | null {
  if (typeof raw === 'string') {
    const label = raw.trim()
    return label ? { id: `choice:${index}`, label, value: label } : null
  }
  if (!raw || typeof raw !== 'object') return null
  const item = raw as Record<string, unknown>
  const label = stringValue(item.label) ?? stringValue(item.title) ?? stringValue(item.text) ?? stringValue(item.value)
  if (!label) return null
  return {
    id: stringValue(item.id) ?? `choice:${index}`,
    label,
    value: stringValue(item.value) ?? label,
    description: stringValue(item.description),
  }
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined
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
    'Ask meee2 AI to adjust the workflow in the box below.',
    '',
    'Natural language changes to a node schema, inputs, outputs, artifacts, gates, or task requirements become a proposal you can review and approve.',
    '',
    'For a node that already has a live session, direct execution notes can still be injected into that session prompt.',
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

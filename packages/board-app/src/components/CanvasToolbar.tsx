import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  ArrowLeft,
  ArrowRight,
  Check,
  ChevronDown,
  Eraser,
  Globe2,
  Info,
  Layers,
  LockKeyhole,
  Plus,
  RefreshCw,
  Search,
  Sparkles,
  Trash2,
} from 'lucide-react'
import { fetchPlannerGraphState, setPlannerCanvasDescription, streamAssistantChat } from '../api'
import {
  CANVAS_RECAP_PREFERENCES_CHANGED,
  loadCanvasRecapIntervalMinutes,
} from '../preferences'
import { readLlmSettings } from '../lib/llmSettings'
import type { BoardState, CanvasInfo, CanvasScope, PlannerGraphState } from '../types'
import type { UserProfile } from '../api'
import { AIRecapDrawer } from './planner/AIRecapDrawer'

interface Props {
  canvases: CanvasInfo[]
  activeCanvasId: string
  canGoBack?: boolean
  canGoForward?: boolean
  onActiveCanvasChange: (canvasId: string) => void
  onGoBack?: () => void
  onGoForward?: () => void
  onCreateCanvas: (name: string, scope: CanvasScope) => Promise<void> | void
  onRenameCanvas: (canvasId: string, name: string) => Promise<void> | void
  onClearCanvas?: (canvasId: string) => Promise<void> | void
  onDeleteCanvas: (canvasId: string) => Promise<void> | void
  // UI-6 · AI Recap Drawer needs richer context. All optional so callers
  // that don't yet pipe them through keep working (drawer still renders local
  // planner-state aggregates and shows ENG-2 stub copy).
  userProfile?: UserProfile | null
  boardState?: BoardState | null
  /** Switch the workspace rail to `SessionsView`. Forwarded to the drawer's
   *  "View all sessions" CTA so it can hand off instead of duplicating the
   *  global session list. */
  onOpenAllSessions?: () => void
}

interface CanvasRecap {
  mode: 'ai' | 'empty'
  description: string
  headline: string
  statuses: Array<{ label: string; value: number; tone: CanvasStatusTone }>
  details: string[]
  updatedAt: string
}

type CanvasStatusTone = 'ready' | 'running' | 'attention' | 'done' | 'neutral'

export function CanvasToolbar({
  canvases,
  activeCanvasId,
  canGoBack = false,
  canGoForward = false,
  onActiveCanvasChange,
  onGoBack,
  onGoForward,
  onCreateCanvas,
  onRenameCanvas,
  onClearCanvas,
  onDeleteCanvas,
  userProfile = null,
  boardState = null,
  onOpenAllSessions,
}: Props) {
  const rootRef = useRef<HTMLDivElement | null>(null)
  const recapRequestRef = useRef(0)
  const recapCacheRef = useRef<Record<string, CanvasRecap>>({})
  const [menuOpen, setMenuOpen] = useState(false)
  const [creating, setCreating] = useState(false)
  const [clearConfirming, setClearConfirming] = useState(false)
  const [deleteConfirming, setDeleteConfirming] = useState(false)
  const [infoOpen, setInfoOpen] = useState(false)
  const [infoTab, setInfoTab] = useState<'overview' | 'settings' | 'danger'>('overview')
  const [canvasQuery, setCanvasQuery] = useState('')
  const [canvasNameDraft, setCanvasNameDraft] = useState('')
  const [canvasDescriptionDraft, setCanvasDescriptionDraft] = useState('')
  const [canvasDescriptionSaving, setCanvasDescriptionSaving] = useState(false)
  const [canvasScopeDraft, setCanvasScopeDraft] = useState<CanvasScope>('personal')
  const [recapIntervalMinutes, setRecapIntervalMinutes] = useState(loadCanvasRecapIntervalMinutes)
  const [recap, setRecap] = useState<CanvasRecap | null>(null)
  const [recapLoading, setRecapLoading] = useState(false)
  const [recapError, setRecapError] = useState<string | null>(null)
  const [recapAgeNow, setRecapAgeNow] = useState(() => Date.now())
  // UI-6 · drawer-open state and a cached PlannerGraphState (the same one
  // `refreshRecap` already fetches) so the drawer can render local
  // aggregates without re-fetching.
  const [recapDrawerOpen, setRecapDrawerOpen] = useState(false)
  const [recapPlannerState, setRecapPlannerState] = useState<PlannerGraphState | null>(null)

  const activeCanvas = canvases.find((canvas) => canvas.id === activeCanvasId) ?? canvases[0]
  const filteredCanvases = useMemo(() => canvases.filter((canvas) => {
    const query = canvasQuery.trim().toLowerCase()
    if (!query) return true
    return [canvas.name, canvas.id, visibilityLabel(canvas)]
      .some((value) => value.toLowerCase().includes(query))
  }), [canvasQuery, canvases])

  const closePanels = () => {
    setCreating(false)
    setClearConfirming(false)
    setDeleteConfirming(false)
  }

  useEffect(() => {
    if (!menuOpen) return
    const onPointerDown = (event: PointerEvent) => {
      const node = rootRef.current
      if (node && event.target instanceof Node && node.contains(event.target)) return
      setMenuOpen(false)
      closePanels()
    }
    document.addEventListener('pointerdown', onPointerDown, true)
    return () => document.removeEventListener('pointerdown', onPointerDown, true)
  }, [menuOpen])

  useEffect(() => {
    const reload = () => setRecapIntervalMinutes(loadCanvasRecapIntervalMinutes())
    window.addEventListener(CANVAS_RECAP_PREFERENCES_CHANGED, reload)
    window.addEventListener('storage', reload)
    return () => {
      window.removeEventListener(CANVAS_RECAP_PREFERENCES_CHANGED, reload)
      window.removeEventListener('storage', reload)
    }
  }, [])

  const refreshRecap = useCallback(async () => {
    if (!activeCanvas) return
    const requestId = recapRequestRef.current + 1
    recapRequestRef.current = requestId
    setRecapLoading(true)
    setRecapError(null)
    try {
      const state = await fetchPlannerGraphState(activeCanvas.id)
      if (recapRequestRef.current !== requestId) return
      setRecapPlannerState(state)
      const baseRecap = buildCanvasStatusRecap(state)
      setRecap(baseRecap)
      if (isBlankPlannerCanvas(state)) {
        const nextRecap = buildBlankCanvasRecap(state)
        recapCacheRef.current[activeCanvas.id] = nextRecap
        setRecap(nextRecap)
        return
      }
      const aiRecap = await generateAIRecap(state, activeCanvas)
      if (recapRequestRef.current !== requestId) return
      const nextRecap = { ...baseRecap, ...aiRecap, updatedAt: new Date().toISOString() }
      recapCacheRef.current[activeCanvas.id] = nextRecap
      setRecap(nextRecap)
    } catch (err) {
      if (recapRequestRef.current !== requestId) return
      setRecapError((err as Error).message || 'Recap unavailable')
      setRecap(buildEmptyCanvasRecap('AI recap unavailable.'))
    } finally {
      if (recapRequestRef.current === requestId) setRecapLoading(false)
    }
  }, [activeCanvas?.id, activeCanvas?.name])

  useEffect(() => {
    if (!activeCanvas) return
    setRecapError(null)
    setRecapLoading(false)
    const cached = recapCacheRef.current[activeCanvas.id]
    if (cached) {
      setRecap(cached)
      return
    }
    setRecap(buildEmptyCanvasRecap())
    void refreshRecap()
  }, [activeCanvas?.id, refreshRecap])

  useEffect(() => {
    const timer = window.setInterval(() => setRecapAgeNow(Date.now()), 60 * 1000)
    return () => window.clearInterval(timer)
  }, [])

  useEffect(() => {
    if (recapIntervalMinutes <= 0) return
    const timer = window.setInterval(() => {
      void refreshRecap()
    }, recapIntervalMinutes * 60 * 1000)
    return () => window.clearInterval(timer)
  }, [recapIntervalMinutes, refreshRecap])

  const submitCreate = () => {
    const name = canvasNameDraft.trim()
    if (!name) return
    Promise.resolve(onCreateCanvas(name, canvasScopeDraft)).then(() => {
      setCanvasNameDraft('')
      setCanvasScopeDraft('personal')
      setCanvasQuery('')
      setCreating(false)
      setMenuOpen(false)
    })
  }

  const submitRename = () => {
    const name = canvasNameDraft.trim()
    if (!activeCanvas || !name) return
    Promise.resolve(onRenameCanvas(activeCanvas.id, name)).then(() => {
      setCanvasNameDraft(name)
    })
  }

  const submitDescription = () => {
    if (!activeCanvas) return
    setCanvasDescriptionSaving(true)
    Promise.resolve(setPlannerCanvasDescription(activeCanvas.id, canvasDescriptionDraft))
      .then((canvas) => {
        setCanvasDescriptionDraft(editableCanvasDescription(canvas.plannerContext))
        void refreshRecap()
      })
      .catch((err) => setRecapError((err as Error).message || 'Failed to save description'))
      .finally(() => setCanvasDescriptionSaving(false))
  }

  const submitDelete = () => {
    if (!activeCanvas || activeCanvas.isDefault) return
    Promise.resolve(onDeleteCanvas(activeCanvas.id)).then(() => {
      setDeleteConfirming(false)
      setMenuOpen(false)
      setInfoOpen(false)
    })
  }

  const submitClear = () => {
    if (!activeCanvas || !onClearCanvas) return
    Promise.resolve(onClearCanvas(activeCanvas.id)).then(() => {
      setClearConfirming(false)
      setInfoOpen(false)
      setMenuOpen(false)
    })
  }

  if (!activeCanvas) return null

  return (
    <div className="canvas-toolbar" ref={rootRef}>
      <div className="canvas-toolbar__switcher">
        <button
          type="button"
          className="canvas-toolbar__nav"
          aria-label="Back to previous canvas"
          disabled={!canGoBack}
          onClick={() => onGoBack?.()}
        >
          <ArrowLeft size={14} aria-hidden />
        </button>
        <button
          type="button"
          className="canvas-toolbar__nav"
          aria-label="Forward to next canvas"
          disabled={!canGoForward}
          onClick={() => onGoForward?.()}
        >
          <ArrowRight size={14} aria-hidden />
        </button>
        <button
          type="button"
          className="canvas-toolbar__trigger"
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          onClick={() => {
            closePanels()
            setMenuOpen((value) => !value)
          }}
        >
          <Layers size={15} aria-hidden />
          <span className="canvas-toolbar__switcher-label">Canvas</span>
          <span className="canvas-toolbar__switcher-current">{displayCanvasName(activeCanvas)}</span>
          <ChevronDown size={14} aria-hidden />
        </button>
        <button
          type="button"
          className="canvas-toolbar__info"
          aria-label="Canvas info"
          onClick={() => {
            closePanels()
            setMenuOpen(false)
            setCanvasNameDraft(activeCanvas.name)
            setCanvasDescriptionDraft(recap?.description ?? '')
            setInfoTab('overview')
            setInfoOpen(true)
          }}
        >
          <Info size={14} aria-hidden />
        </button>

        {menuOpen && (
          <div className="canvas-toolbar__panel">
            <div className="canvas-toolbar__menu-tools">
              <button
                type="button"
                className="canvas-toolbar__new-canvas"
                onClick={() => {
                  setCanvasNameDraft('')
                  setCanvasScopeDraft('personal')
                  setDeleteConfirming(false)
                  setCreating(true)
                  setMenuOpen(false)
                }}
              >
                <Plus size={13} aria-hidden /> New
              </button>
              <label className="canvas-toolbar__search">
                <Search size={13} aria-hidden />
                <input
                  value={canvasQuery}
                  onChange={(event) => setCanvasQuery(event.target.value)}
                  placeholder="Find canvas"
                  autoFocus
                />
              </label>
            </div>
            <div className="canvas-toolbar__list">
              {filteredCanvases.map((canvas) => {
                const selected = canvas.id === activeCanvas.id
                return (
                  <button
                    key={canvas.id}
                    type="button"
                    className={'canvas-toolbar__item' + (selected ? ' is-selected' : '')}
                    onClick={() => {
                      closePanels()
                      setMenuOpen(false)
                      onActiveCanvasChange(canvas.id)
                    }}
                  >
                    <span className="canvas-toolbar__check">
                      {selected && <Check size={13} aria-hidden />}
                    </span>
                    <span className="canvas-toolbar__item-text">
                      <span>{displayCanvasName(canvas)}</span>
                      <span className={`canvas-toolbar__visibility canvas-toolbar__visibility--${visibilityLabel(canvas).toLowerCase()}`}>
                        {visibilityLabel(canvas) === 'Public' ? <Globe2 size={10} aria-hidden /> : <LockKeyhole size={10} aria-hidden />}
                        {visibilityLabel(canvas)}
                      </span>
                    </span>
                  </button>
                )
              })}
              {filteredCanvases.length === 0 && (
                <div className="canvas-toolbar__empty">No matching canvas</div>
              )}
            </div>
          </div>
        )}
      </div>
      <div className="canvas-toolbar__context" aria-live="polite">
        <div className="canvas-toolbar__recap">
          <button
            type="button"
            className="canvas-toolbar__recap-trigger"
            aria-label="Open AI recap drawer"
            aria-expanded={recapDrawerOpen}
            title="Open AI recap"
            onClick={() => setRecapDrawerOpen((v) => !v)}
          >
            <Sparkles size={13} aria-hidden />
            <span className="canvas-toolbar__recap-copy">
              <strong>{recapLoading ? 'Refreshing recap...' : (recap?.headline ?? 'Reading canvas state...')}</strong>
              {recapError ? (
                <small>{recapError}</small>
              ) : recap?.updatedAt ? (
                <small className="canvas-toolbar__recap-age">{formatRecapAge(recap.updatedAt, recapAgeNow)}</small>
              ) : null}
            </span>
          </button>
          <button
            type="button"
            className="canvas-toolbar__recap-refresh"
            aria-label="Refresh canvas recap"
            title="Refresh canvas recap"
            onClick={() => void refreshRecap()}
            disabled={recapLoading}
          >
            <RefreshCw size={13} aria-hidden />
          </button>
        </div>
        {recap?.details && recap.details.length > 0 && (
          <div className="canvas-toolbar__recap-details">
            {recap.details.map((line) => (
              <p key={line}>{line}</p>
            ))}
          </div>
        )}
      </div>
      {recap?.mode !== 'empty' && recap?.statuses && (
        <div className="canvas-toolbar__status-strip" aria-label="Canvas status overview">
          {recap.statuses.map((item) => (
            <span key={item.label} className={`canvas-toolbar__status-pill is-${item.tone}`}>
              <strong>{item.value}</strong>
              <small>{item.label}</small>
            </span>
          ))}
        </div>
      )}

      <AIRecapDrawer
        open={recapDrawerOpen}
        onClose={() => setRecapDrawerOpen(false)}
        canvasId={activeCanvas.id}
        canvasName={displayCanvasName(activeCanvas)}
        plannerState={recapPlannerState}
        boardState={boardState}
        userProfile={userProfile}
        onOpenAllSessions={onOpenAllSessions}
      />

      {infoOpen && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setInfoOpen(false)
          }}
        >
          <div className="modal canvas-info-modal" role="dialog" aria-modal="true" aria-label="Canvas info">
            <div className="modal-header">
              <div className="modal-title">{displayCanvasName(activeCanvas)}</div>
              <div className="modal-subtitle">{visibilityLabel(activeCanvas)} planning canvas</div>
            </div>
            <div className="canvas-info-modal__tabs" role="tablist" aria-label="Canvas sections">
              {(['overview', 'settings', 'danger'] as const).map((tab) => (
                <button
                  key={tab}
                  type="button"
                  className={infoTab === tab ? 'is-active' : ''}
                  aria-selected={infoTab === tab}
                  onClick={() => setInfoTab(tab)}
                >
                  {tab === 'overview' ? 'Overview' : tab === 'settings' ? 'Settings' : 'Danger'}
                </button>
              ))}
            </div>
            <div className="modal-body col canvas-info-modal__body">
              {infoTab === 'overview' && (
                <>
                  <div className="canvas-info-modal__row">
                    <span>Visibility</span>
                    <strong>{visibilityLabel(activeCanvas)}</strong>
                  </div>
                  <div className="canvas-info-modal__row">
                    <span>Canvas ID</span>
                    <strong className="is-mono">{activeCanvas.id}</strong>
                  </div>
                  <p>
                    meee2 AI changes are scoped to this canvas. Sessions only appear after explicit binding.
                  </p>
                </>
              )}
              {infoTab === 'settings' && (
                <div className="canvas-info-modal__settings">
                  <label>
                    <span>Name</span>
                    <input
                      value={canvasNameDraft}
                      onChange={(event) => setCanvasNameDraft(event.target.value)}
                      onKeyDown={(event) => {
                        if (event.key === 'Enter') submitRename()
                        if (event.key === 'Escape') setCanvasNameDraft(activeCanvas.name)
                      }}
                      placeholder="Canvas name"
                    />
                  </label>
                  <button
                    type="button"
                    className="primary"
                    onClick={submitRename}
                    disabled={!canvasNameDraft.trim() || canvasNameDraft.trim() === activeCanvas.name}
                  >
                    Save name
                  </button>
                  <label>
                    <span>Description</span>
                    <textarea
                      value={canvasDescriptionDraft}
                      onChange={(event) => setCanvasDescriptionDraft(event.target.value)}
                      placeholder="What is this canvas trying to accomplish?"
                      rows={4}
                    />
                  </label>
                  <button
                    type="button"
                    className="primary"
                    onClick={submitDescription}
                    disabled={canvasDescriptionSaving || canvasDescriptionDraft.trim() === (recap?.description ?? '').trim()}
                  >
                    {canvasDescriptionSaving ? 'Saving...' : 'Save description'}
                  </button>
                </div>
              )}
              {infoTab === 'danger' && (
                <>
                  {onClearCanvas && (
                    <div className="canvas-info-modal__danger">
                      <Eraser size={15} aria-hidden />
                      <div>
                        <strong>Clear this canvas</strong>
                        <p>Removes meee2 AI nodes, proposals, outputs, and local chat history. The canvas remains.</p>
                      </div>
                      <button
                        type="button"
                        className="danger"
                        title="Clear canvas content"
                        onClick={() => {
                          setInfoOpen(false)
                          setClearConfirming(true)
                        }}
                      >
                        Clear
                      </button>
                    </div>
                  )}
                  <div className="canvas-info-modal__danger">
                    <Trash2 size={15} aria-hidden />
                    <div>
                      <strong>Delete this canvas</strong>
                      <p>Sessions and local AI history are not deleted.</p>
                    </div>
                    <button
                      type="button"
                      className="danger"
                      disabled={activeCanvas.isDefault}
                      title={activeCanvas.isDefault ? 'This canvas cannot be deleted.' : 'Delete canvas'}
                      onClick={() => {
                        setInfoOpen(false)
                        setDeleteConfirming(true)
                      }}
                    >
                      Delete
                    </button>
                  </div>
                </>
              )}
            </div>
            <div className="modal-footer">
              <button className="primary" type="button" onClick={() => setInfoOpen(false)}>Done</button>
            </div>
          </div>
        </div>
      )}

      {creating && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setCreating(false)
          }}
        >
          <div className="modal canvas-confirm-modal" role="dialog" aria-modal="true" aria-label="Create canvas">
            <div className="modal-header">
              <div className="modal-title">New canvas</div>
              <div className="modal-subtitle">Choose who can view this planning space.</div>
            </div>
            <div className="modal-body col" style={{ gap: 10 }}>
              <input
                value={canvasNameDraft}
                onChange={(event) => setCanvasNameDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') submitCreate()
                  if (event.key === 'Escape') setCreating(false)
                }}
                placeholder="Canvas name"
                autoFocus
              />
              <div className="canvas-toolbar__scope-toggle" role="group" aria-label="Canvas visibility">
                {(['personal', 'team'] as CanvasScope[]).map((scope) => (
                  <button
                    key={scope}
                    type="button"
                    className={canvasScopeDraft === scope ? 'is-selected' : ''}
                    aria-pressed={canvasScopeDraft === scope}
                    onClick={() => setCanvasScopeDraft(scope)}
                  >
                    {scope === 'team' ? 'Public' : 'Private'}
                  </button>
                ))}
              </div>
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setCreating(false)}>Cancel</button>
              <button
                className="primary"
                type="button"
                onClick={submitCreate}
                disabled={!canvasNameDraft.trim()}
              >
                Create
              </button>
            </div>
          </div>
        </div>
      )}
      {clearConfirming && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setClearConfirming(false)
          }}
        >
          <div className="modal canvas-confirm-modal" role="dialog" aria-modal="true" aria-label="Clear canvas">
            <div className="modal-header">
              <div className="modal-title">Clear canvas</div>
              <div className="modal-subtitle">This keeps the canvas but removes its meee2 AI graph.</div>
            </div>
            <div className="modal-body col" style={{ gap: 8 }}>
              <strong>{activeCanvas.name}</strong>
              <span className="muted" style={{ fontSize: 12, lineHeight: 1.4 }}>
                Nodes, pending proposals, outputs, runs, and local meee2 AI chat history for this canvas will be removed. Sessions are not deleted.
              </span>
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setClearConfirming(false)}>Cancel</button>
              <button className="danger" type="button" onClick={submitClear}>Clear</button>
            </div>
          </div>
        </div>
      )}
      {deleteConfirming && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setDeleteConfirming(false)
          }}
        >
          <div className="modal canvas-confirm-modal" role="dialog" aria-modal="true" aria-label="Delete canvas">
            <div className="modal-header">
              <div className="modal-title">Delete canvas</div>
              <div className="modal-subtitle">This only removes the canvas container.</div>
            </div>
            <div className="modal-body col" style={{ gap: 8 }}>
              <strong>{activeCanvas.name}</strong>
              <span className="muted" style={{ fontSize: 12, lineHeight: 1.4 }}>
                This removes the canvas layout and memberships. Sessions are not deleted.
              </span>
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setDeleteConfirming(false)}>Cancel</button>
              <button className="danger" type="button" onClick={submitDelete}>Delete</button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

function visibilityLabel(canvas: CanvasInfo): 'Private' | 'Public' {
  return canvas.scope === 'team' ? 'Public' : 'Private'
}

function displayCanvasName(canvas: CanvasInfo): string {
  return canvas.name === 'Default canvas' ? 'My' : canvas.name
}

function buildCanvasStatusRecap(state: PlannerGraphState): CanvasRecap {
  const nodes = state.nodes ?? []
  const artifacts = state.artifacts ?? []
  const ready = nodes.filter((node) => node.status === 'ready')
  const working = nodes.filter((node) => node.status === 'working' || node.workflowRunState === 'running')
  const blocked = nodes.filter((node) => node.status === 'blocked' || node.workflowRunState === 'failed' || node.blockedReason)
  const done = nodes.filter((node) => node.status === 'done')
  const scheduled = nodes.filter((node) => node.schedule?.enabled)
  const description = editableCanvasDescription(state.canvas?.plannerContext)

  return {
    mode: 'ai',
    description,
    headline: 'Generating AI recap...',
    statuses: [
      { label: 'Ready', value: ready.length, tone: 'ready' },
      { label: 'Running', value: working.length, tone: 'running' },
      { label: 'Attention', value: blocked.length, tone: 'attention' },
      { label: 'Done', value: done.length, tone: 'done' },
      { label: 'Artifacts', value: artifacts.length, tone: 'neutral' },
      { label: 'Scheduled', value: scheduled.length, tone: 'neutral' },
    ],
    details: [],
    updatedAt: new Date().toISOString(),
  }
}

function buildEmptyCanvasRecap(headline = 'Generating AI recap...'): CanvasRecap {
  return {
    mode: 'ai',
    description: '',
    headline,
    statuses: [
      { label: 'Ready', value: 0, tone: 'ready' },
      { label: 'Running', value: 0, tone: 'running' },
      { label: 'Attention', value: 0, tone: 'attention' },
      { label: 'Done', value: 0, tone: 'done' },
      { label: 'Artifacts', value: 0, tone: 'neutral' },
      { label: 'Scheduled', value: 0, tone: 'neutral' },
    ],
    details: [],
    updatedAt: new Date().toISOString(),
  }
}

function buildBlankCanvasRecap(state: PlannerGraphState): CanvasRecap {
  return {
    ...buildCanvasStatusRecap(state),
    mode: 'empty',
    headline: 'Ready to build this canvas',
    details: [
      'Describe the outcome you want in AIChat.',
      'meee2 AI will draft nodes for review before applying.',
    ],
    updatedAt: new Date().toISOString(),
  }
}

function isBlankPlannerCanvas(state: PlannerGraphState): boolean {
  const nodes = state.nodes ?? []
  const artifacts = state.artifacts ?? []
  return nodes.length === 0 && artifacts.length === 0
}

function editableCanvasDescription(value: string | null | undefined): string {
  const trimmed = value?.trim() ?? ''
  if (trimmed && !/^canvas:/i.test(trimmed)) return trimmed
  return ''
}

async function generateAIRecap(
  state: PlannerGraphState,
  canvas: CanvasInfo,
): Promise<Pick<CanvasRecap, 'headline' | 'details'>> {
  const llm = readLlmSettings()
  let text = ''
  for await (const ev of streamAssistantChat({
    messages: [{ role: 'user', content: buildAIRecapPrompt(state) }],
    settings: {
      provider: llm.provider,
      apiKey: llm.apiKey,
      baseUrl: llm.baseUrl,
      model: llm.model,
      enabledTools: [],
      scope: 'this-mac',
      canvasId: canvas.id,
      workspacePath: canvas.workspacePath ?? '',
      canvasName: canvas.name,
    },
  })) {
    if (ev.type === 'delta') text += ev.text
    if (ev.type === 'error') throw new Error(ev.message)
  }
  return parseAIRecap(text)
}

function buildAIRecapPrompt(state: PlannerGraphState): string {
  const payload = {
    canvas: {
      title: state.canvas.title,
      context: state.canvas.plannerContext,
    },
    nodes: state.nodes.slice(0, 24).map((node) => ({
      title: node.title,
      status: node.status,
      workflowRunState: node.workflowRunState ?? null,
      blockedReason: node.blockedReason ?? null,
      nextAction: node.nextAction ?? null,
      inputs: node.schema.inputs,
      outputs: node.schema.outputs,
      dependsOnNodeIds: node.dependsOnNodeIds ?? [],
      hasSession: Boolean(node.sessionId),
      scheduled: Boolean(node.schedule?.enabled),
    })),
    artifacts: state.artifacts.slice(-12).map((artifact) => ({
      title: artifact.title,
      kind: artifact.kind,
      status: artifact.status,
      nodeId: artifact.nodeId,
      createdAt: artifact.createdAt,
    })),
    pendingProposals: state.proposals
      .filter((proposal) => proposal.status === 'pending')
      .slice(0, 5)
      .map((proposal) => ({ summary: proposal.summary, changeCount: proposal.changes.length })),
    latestEvents: [...(state.events ?? [])]
      .sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt))
      .slice(0, 8)
      .map((event) => ({
        type: event.type,
        summary: event.summary,
        createdAt: event.createdAt,
      })),
  }
  return [
    '你是 meee2 的画板 recap writer。只根据下面 JSON 生成用户能快速理解画板的摘要。',
    '不要复述状态计数，不要写 ready/running/done/artifacts 的数字串；那些会由 UI 单独显示。',
    'headline 必须是最重要的业务判断、风险、瓶颈或下一步，不是状态标题。',
    '用中文。返回严格 JSON，不要 markdown，不要代码块。',
    '格式: {"headline":"不超过32个中文字符","details":["2-4条，每条不超过48个中文字符"]}',
    '',
    JSON.stringify(payload),
  ].join('\n')
}

function parseAIRecap(raw: string): Pick<CanvasRecap, 'headline' | 'details'> {
  const text = raw.trim()
  const jsonText = text
    .replace(/^```(?:json)?/i, '')
    .replace(/```$/i, '')
    .trim()
  const objectMatch = jsonText.match(/\{[\s\S]*\}/)
  const candidate = objectMatch?.[0] ?? jsonText
  try {
    const parsed = JSON.parse(candidate) as { headline?: unknown; details?: unknown }
    const headline = typeof parsed.headline === 'string'
      ? trimToSentence(parsed.headline.trim(), 92)
      : trimToSentence(text, 92)
    const details = Array.isArray(parsed.details)
      ? parsed.details
        .filter((item): item is string => typeof item === 'string' && item.trim().length > 0)
        .slice(0, 4)
        .map((item) => trimToSentence(item.trim(), 120))
      : []
    return { headline: headline || 'AI recap generated.', details }
  } catch {
    const lines = text.split('\n').map((line) => line.replace(/^[-*]\s*/, '').trim()).filter(Boolean)
    return {
      headline: trimToSentence(lines[0] ?? text, 92),
      details: lines.slice(1, 5).map((line) => trimToSentence(line, 120)),
    }
  }
}

function formatRecapAge(updatedAt: string, nowMs: number): string {
  const updatedMs = Date.parse(updatedAt)
  if (Number.isNaN(updatedMs)) return ''
  const elapsedSeconds = Math.max(0, Math.floor((nowMs - updatedMs) / 1000))
  if (elapsedSeconds < 60) return '刚刚'
  const elapsedMinutes = Math.floor(elapsedSeconds / 60)
  if (elapsedMinutes < 60) return `${elapsedMinutes}m前`
  const elapsedHours = Math.floor(elapsedMinutes / 60)
  if (elapsedHours < 24) return `${elapsedHours}h前`
  return `${Math.floor(elapsedHours / 24)}d前`
}

function trimToSentence(value: string, maxLength: number): string {
  if (value.length <= maxLength) return value
  return `${value.slice(0, Math.max(0, maxLength - 3)).trimEnd()}...`
}

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
import { setPlannerCanvasDescription, streamAssistantChat } from '../api'
import {
  CANVAS_RECAP_PREFERENCES_CHANGED,
  loadCanvasRecapIntervalMinutes,
} from '../preferences'
import { readLlmSettings } from '../lib/llmSettings'
import { useI18n } from '../lib/i18n'
import type { BoardState, CanvasInfo, CanvasScope, PlannerGraphState } from '../types'
import type { UserProfile } from '../api'
import { AIRecapDrawer } from './planner/AIRecapDrawer'
import {
  buildAIRecapPrompt,
  buildCanvasStatusRecap as buildCoreCanvasStatusRecap,
  buildEmptyCanvasRecap as buildCoreEmptyCanvasRecap,
  editableCanvasDescription,
  formatRecapAge,
  parseAIRecap,
  type CanvasMonitor,
  type CanvasStatusRecap as CoreCanvasStatusRecap,
} from '@meee1/recap-core'

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
  // AI Recap Drawer needs richer context. Optional so narrower callers can
  // still render the toolbar without canvas monitor wiring.
  userProfile?: UserProfile | null
  boardState?: BoardState | null
  plannerState?: PlannerGraphState | null
  canvasMonitor?: CanvasMonitor | null
  /** Switch the workspace rail to `SessionsView`. Forwarded to the drawer's
   *  "View all sessions" CTA so it can hand off instead of duplicating the
   *  global session list. */
  onOpenAllSessions?: () => void
}

type CanvasRecap = CoreCanvasStatusRecap & {
  mode: 'ai' | 'empty'
}
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
  plannerState = null,
  canvasMonitor = null,
  onOpenAllSessions,
}: Props) {
  const { t } = useI18n()
  const rootRef = useRef<HTMLDivElement | null>(null)
  const recapRequestRef = useRef(0)
  const recapCacheRef = useRef<Record<string, CanvasRecap>>({})
  const plannerStateRef = useRef<PlannerGraphState | null>(plannerState)
  const canvasMonitorRef = useRef<CanvasMonitor | null>(canvasMonitor)
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
  const [recapDrawerOpen, setRecapDrawerOpen] = useState(false)

  const activeCanvas = canvases.find((canvas) => canvas.id === activeCanvasId) ?? canvases[0]
  const filteredCanvasEntries = useMemo(
    () => buildCanvasListEntries(canvases, canvasQuery, t),
    [canvasQuery, canvases, t],
  )

  const closePanels = () => {
    setCreating(false)
    setClearConfirming(false)
    setDeleteConfirming(false)
  }

  useEffect(() => {
    plannerStateRef.current = plannerState
  }, [plannerState])

  useEffect(() => {
    canvasMonitorRef.current = canvasMonitor
  }, [canvasMonitor])

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
      const state = plannerStateRef.current
      if (!state || state.canvas.id !== activeCanvas.id) {
        setRecap(buildEmptyCanvasRecap(t, t('canvas.readingState')))
        return
      }
      if (recapRequestRef.current !== requestId) return
      const baseRecap = buildCanvasStatusRecap(state, t)
      setRecap(baseRecap)
      if (isBlankPlannerCanvas(state)) {
        const nextRecap = buildBlankCanvasRecap(state, t)
        recapCacheRef.current[activeCanvas.id] = nextRecap
        setRecap(nextRecap)
        return
      }
      const aiRecap = await generateAIRecap(state, activeCanvas, canvasMonitorRef.current)
      if (recapRequestRef.current !== requestId) return
      const nextRecap = { ...baseRecap, ...aiRecap, updatedAt: new Date().toISOString() }
      recapCacheRef.current[activeCanvas.id] = nextRecap
      setRecap(nextRecap)
    } catch (err) {
      if (recapRequestRef.current !== requestId) return
      setRecapError((err as Error).message || 'Recap unavailable')
      setRecap(buildEmptyCanvasRecap(t, t('canvas.recapUnavailable')))
    } finally {
      if (recapRequestRef.current === requestId) setRecapLoading(false)
    }
  }, [activeCanvas?.id, activeCanvas?.name, t])

  useEffect(() => {
    if (!activeCanvas) return
    setRecapError(null)
    setRecapLoading(false)
    const cached = recapCacheRef.current[activeCanvas.id]
    if (cached) {
      setRecap(cached)
      return
    }
    setRecap(buildEmptyCanvasRecap(t))
  }, [activeCanvas?.id, t])

  useEffect(() => {
    if (!activeCanvas) return
    if (recapCacheRef.current[activeCanvas.id]) return
    if (plannerState?.canvas.id !== activeCanvas.id) return
    void refreshRecap()
  }, [activeCanvas?.id, plannerState?.canvas.id, refreshRecap])

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
  const monitorBadge = monitorBadgeFor(canvasMonitor, t)

  return (
    <div className="canvas-toolbar" ref={rootRef}>
      <div className="canvas-toolbar__switcher">
        <button
          type="button"
          className="canvas-toolbar__nav"
          aria-label={t('canvas.back')}
          disabled={!canGoBack}
          onClick={() => onGoBack?.()}
        >
          <ArrowLeft size={14} aria-hidden />
        </button>
        <button
          type="button"
          className="canvas-toolbar__nav"
          aria-label={t('canvas.forward')}
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
          <span className="canvas-toolbar__switcher-label">{t('canvas.canvas')}</span>
          <span className="canvas-toolbar__switcher-current">{displayCanvasName(activeCanvas)}</span>
          <ChevronDown size={14} aria-hidden />
        </button>
        <button
          type="button"
          className="canvas-toolbar__info"
          aria-label={t('canvas.info')}
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
                <Plus size={13} aria-hidden /> {t('canvas.new')}
              </button>
              <label className="canvas-toolbar__search">
                <Search size={13} aria-hidden />
                <input
                  value={canvasQuery}
                  onChange={(event) => setCanvasQuery(event.target.value)}
                  placeholder={t('canvas.find')}
                  autoFocus
                />
              </label>
            </div>
            <div className="canvas-toolbar__list">
              {filteredCanvasEntries.map(({ canvas, depth }) => {
                const selected = canvas.id === activeCanvas.id
                return (
                  <button
                    key={canvas.id}
                    type="button"
                    className={[
                      'canvas-toolbar__item',
                      selected ? 'is-selected' : '',
                      depth > 0 ? 'is-subcanvas' : '',
                    ].filter(Boolean).join(' ')}
                    style={{ paddingLeft: 8 + Math.min(depth, 4) * 16 }}
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
                      <span className={`canvas-toolbar__visibility canvas-toolbar__visibility--${visibilityTone(canvas)}`}>
                        {canvas.scope === 'team' ? <Globe2 size={10} aria-hidden /> : <LockKeyhole size={10} aria-hidden />}
                        {visibilityLabel(canvas, t)}
                      </span>
                    </span>
                  </button>
                )
              })}
              {filteredCanvasEntries.length === 0 && (
                <div className="canvas-toolbar__empty">{t('canvas.noMatch')}</div>
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
            aria-label={t('canvas.openRecap')}
            aria-expanded={recapDrawerOpen}
            title={t('canvas.openRecap')}
            onClick={() => setRecapDrawerOpen((v) => !v)}
          >
            <Sparkles size={13} aria-hidden />
            <span className="canvas-toolbar__recap-copy">
              <strong>{recapLoading ? t('canvas.refreshingRecap') : (recap?.headline ?? t('canvas.readingState'))}</strong>
              {recapError ? (
                <small>{recapError}</small>
              ) : recap?.updatedAt ? (
                <small className="canvas-toolbar__recap-age">{formatRecapAge(recap.updatedAt, recapAgeNow)}</small>
              ) : null}
            </span>
            <span className={`canvas-toolbar__monitor-badge is-${monitorBadge.tone}`}>
              {monitorBadge.label}
            </span>
          </button>
          <button
            type="button"
            className="canvas-toolbar__recap-refresh"
            aria-label={t('canvas.refreshRecap')}
            title={t('canvas.refreshRecap')}
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
        <div className="canvas-toolbar__status-strip" aria-label={t('canvas.statusOverview')}>
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
        plannerState={plannerState}
        monitor={canvasMonitor}
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
          <div className="modal canvas-info-modal" role="dialog" aria-modal="true" aria-label={t('canvas.info')}>
            <div className="modal-header">
              <div className="modal-title">{displayCanvasName(activeCanvas)}</div>
              <div className="modal-subtitle">{t('canvas.planningCanvas', { visibility: visibilityLabel(activeCanvas, t) })}</div>
            </div>
            <div className="canvas-info-modal__tabs" role="tablist" aria-label={t('canvas.sections')}>
              {(['overview', 'settings', 'danger'] as const).map((tab) => (
                <button
                  key={tab}
                  type="button"
                  className={infoTab === tab ? 'is-active' : ''}
                  aria-selected={infoTab === tab}
                  onClick={() => setInfoTab(tab)}
                >
                  {tab === 'overview' ? t('canvas.overview') : tab === 'settings' ? t('canvas.settings') : t('canvas.danger')}
                </button>
              ))}
            </div>
            <div className="modal-body col canvas-info-modal__body">
              {infoTab === 'overview' && (
                <>
                  <div className="canvas-info-modal__row">
                    <span>{t('canvas.visibility')}</span>
                    <strong>{visibilityLabel(activeCanvas, t)}</strong>
                  </div>
                  <div className="canvas-info-modal__row">
                    <span>{t('canvas.id')}</span>
                    <strong className="is-mono">{activeCanvas.id}</strong>
                  </div>
                  <p>
                    {t('canvas.scopedHelp')}
                  </p>
                </>
              )}
              {infoTab === 'settings' && (
                <div className="canvas-info-modal__settings">
                  <label>
                    <span>{t('canvas.name')}</span>
                    <input
                      value={canvasNameDraft}
                      onChange={(event) => setCanvasNameDraft(event.target.value)}
                      onKeyDown={(event) => {
                        if (event.key === 'Enter') submitRename()
                        if (event.key === 'Escape') setCanvasNameDraft(activeCanvas.name)
                      }}
                      placeholder={t('canvas.namePlaceholder')}
                    />
                  </label>
                  <button
                    type="button"
                    className="primary"
                    onClick={submitRename}
                    disabled={!canvasNameDraft.trim() || canvasNameDraft.trim() === activeCanvas.name}
                  >
                    {t('canvas.saveName')}
                  </button>
                  <label>
                    <span>{t('canvas.description')}</span>
                    <textarea
                      value={canvasDescriptionDraft}
                      onChange={(event) => setCanvasDescriptionDraft(event.target.value)}
                      placeholder={t('canvas.descriptionPlaceholder')}
                      rows={4}
                    />
                  </label>
                  <button
                    type="button"
                    className="primary"
                    onClick={submitDescription}
                    disabled={canvasDescriptionSaving || canvasDescriptionDraft.trim() === (recap?.description ?? '').trim()}
                  >
                    {canvasDescriptionSaving ? t('canvas.saving') : t('canvas.saveDescription')}
                  </button>
                </div>
              )}
              {infoTab === 'danger' && (
                <>
                  {onClearCanvas && (
                    <div className="canvas-info-modal__danger">
                      <Eraser size={15} aria-hidden />
                      <div>
                        <strong>{t('canvas.clearTitle')}</strong>
                        <p>{t('canvas.clearHelp')}</p>
                      </div>
                      <button
                        type="button"
                        className="danger"
                        title={t('canvas.clearContent')}
                        onClick={() => {
                          setInfoOpen(false)
                          setClearConfirming(true)
                        }}
                      >
                        {t('common.clear')}
                      </button>
                    </div>
                  )}
                  <div className="canvas-info-modal__danger">
                    <Trash2 size={15} aria-hidden />
                    <div>
                      <strong>{t('canvas.deleteTitle')}</strong>
                      <p>{t('canvas.deleteHelp')}</p>
                    </div>
                    <button
                      type="button"
                      className="danger"
                      disabled={activeCanvas.isDefault}
                      title={activeCanvas.isDefault ? t('canvas.cannotDelete') : t('canvas.deleteTitle')}
                      onClick={() => {
                        setInfoOpen(false)
                        setDeleteConfirming(true)
                      }}
                    >
                      {t('common.delete')}
                    </button>
                  </div>
                </>
              )}
            </div>
            <div className="modal-footer">
              <button className="primary" type="button" onClick={() => setInfoOpen(false)}>{t('common.done')}</button>
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
          <div className="modal canvas-confirm-modal" role="dialog" aria-modal="true" aria-label={t('canvas.createTitle')}>
            <div className="modal-header">
              <div className="modal-title">{t('canvas.createTitle')}</div>
              <div className="modal-subtitle">{t('canvas.createSubtitle')}</div>
            </div>
            <div className="modal-body col" style={{ gap: 10 }}>
              <input
                value={canvasNameDraft}
                onChange={(event) => setCanvasNameDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') submitCreate()
                  if (event.key === 'Escape') setCreating(false)
                }}
                placeholder={t('canvas.namePlaceholder')}
                autoFocus
              />
              <div className="canvas-toolbar__scope-toggle" role="group" aria-label={t('canvas.visibilityLabel')}>
                {(['personal', 'team'] as CanvasScope[]).map((scope) => (
                  <button
                    key={scope}
                    type="button"
                    className={canvasScopeDraft === scope ? 'is-selected' : ''}
                    aria-pressed={canvasScopeDraft === scope}
                    onClick={() => setCanvasScopeDraft(scope)}
                  >
                    {scope === 'team' ? t('templates.public') : t('templates.private')}
                  </button>
                ))}
              </div>
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setCreating(false)}>{t('common.cancel')}</button>
              <button
                className="primary"
                type="button"
                onClick={submitCreate}
                disabled={!canvasNameDraft.trim()}
              >
                {t('common.create')}
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
          <div className="modal canvas-confirm-modal" role="dialog" aria-modal="true" aria-label={t('canvas.clearTitle')}>
            <div className="modal-header">
              <div className="modal-title">{t('canvas.clearTitle')}</div>
              <div className="modal-subtitle">{t('canvas.clearConfirmSubtitle')}</div>
            </div>
            <div className="modal-body col" style={{ gap: 8 }}>
              <strong>{activeCanvas.name}</strong>
              <span className="muted" style={{ fontSize: 12, lineHeight: 1.4 }}>
                {t('canvas.clearConfirmBody')}
              </span>
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setClearConfirming(false)}>{t('common.cancel')}</button>
              <button className="danger" type="button" onClick={submitClear}>{t('common.clear')}</button>
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
          <div className="modal canvas-confirm-modal" role="dialog" aria-modal="true" aria-label={t('canvas.deleteTitle')}>
            <div className="modal-header">
              <div className="modal-title">{t('canvas.deleteTitle')}</div>
              <div className="modal-subtitle">{t('canvas.deleteConfirmSubtitle')}</div>
            </div>
            <div className="modal-body col" style={{ gap: 8 }}>
              <strong>{activeCanvas.name}</strong>
              <span className="muted" style={{ fontSize: 12, lineHeight: 1.4 }}>
                {t('canvas.deleteConfirmBody')}
              </span>
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setDeleteConfirming(false)}>{t('common.cancel')}</button>
              <button className="danger" type="button" onClick={submitDelete}>{t('common.delete')}</button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

function visibilityTone(canvas: CanvasInfo): 'private' | 'public' {
  return canvas.scope === 'team' ? 'public' : 'private'
}

function visibilityLabel(canvas: CanvasInfo, t: ReturnType<typeof useI18n>['t']): string {
  return canvas.scope === 'team' ? t('templates.public') : t('templates.private')
}

function displayCanvasName(canvas: CanvasInfo): string {
  return canvas.name === 'Default canvas' ? 'My' : canvas.name
}

function buildCanvasListEntries(
  canvases: CanvasInfo[],
  query: string,
  t: ReturnType<typeof useI18n>['t'],
): Array<{ canvas: CanvasInfo; depth: number }> {
  const originalIndex = new Map(canvases.map((canvas, index) => [canvas.id, index]))
  const byId = new Map(canvases.map((canvas) => [canvas.id, canvas]))
  const childrenByParent = new Map<string, CanvasInfo[]>()
  const roots: CanvasInfo[] = []

  for (const canvas of canvases) {
    const parentId = canvas.parentCanvasId?.trim() || null
    if (parentId && parentId !== canvas.id && byId.has(parentId)) {
      const children = childrenByParent.get(parentId) ?? []
      children.push(canvas)
      childrenByParent.set(parentId, children)
    } else {
      roots.push(canvas)
    }
  }

  const byOriginalOrder = (a: CanvasInfo, b: CanvasInfo) => (originalIndex.get(a.id) ?? 0) - (originalIndex.get(b.id) ?? 0)
  roots.sort(byOriginalOrder)
  for (const children of childrenByParent.values()) {
    children.sort(byOriginalOrder)
  }

  const normalizedQuery = query.trim().toLowerCase()
  const matches = (canvas: CanvasInfo) => {
    if (!normalizedQuery) return true
    return [canvas.name, canvas.id, visibilityLabel(canvas, t)]
      .some((value) => value.toLowerCase().includes(normalizedQuery))
  }

  const result: Array<{ canvas: CanvasInfo; depth: number }> = []
  const visit = (canvas: CanvasInfo, depth: number, path: Set<string>) => {
    if (path.has(canvas.id)) return
    if (matches(canvas)) result.push({ canvas, depth })
    const nextPath = new Set(path).add(canvas.id)
    for (const child of childrenByParent.get(canvas.id) ?? []) {
      visit(child, depth + 1, nextPath)
    }
  }

  for (const canvas of roots) {
    visit(canvas, 0, new Set())
  }

  return result
}

function buildCanvasStatusRecap(state: PlannerGraphState, t: ReturnType<typeof useI18n>['t']): CanvasRecap {
  const recap = buildCoreCanvasStatusRecap(state)
  return {
    ...recap,
    mode: 'ai',
    headline: t('canvas.generatingRecap'),
    statuses: localizeStatusLabels(recap.statuses, t),
  }
}

function buildEmptyCanvasRecap(t: ReturnType<typeof useI18n>['t'], headline = t('canvas.generatingRecap')): CanvasRecap {
  const recap = buildCoreEmptyCanvasRecap(headline)
  return {
    ...recap,
    mode: 'ai',
    headline,
    statuses: localizeStatusLabels(recap.statuses, t),
  }
}

function buildBlankCanvasRecap(state: PlannerGraphState, t: ReturnType<typeof useI18n>['t']): CanvasRecap {
  return {
    ...buildCanvasStatusRecap(state, t),
    mode: 'empty',
    headline: t('canvas.readyToBuild'),
    details: [
      t('canvas.emptyDetailOutcome'),
      t('canvas.emptyDetailReview'),
    ],
    updatedAt: new Date().toISOString(),
  }
}

function isBlankPlannerCanvas(state: PlannerGraphState): boolean {
  const nodes = state.nodes ?? []
  const artifacts = state.artifacts ?? []
  return nodes.length === 0 && artifacts.length === 0
}

function localizeStatusLabels(
  statuses: CoreCanvasStatusRecap['statuses'],
  t: ReturnType<typeof useI18n>['t'],
): CoreCanvasStatusRecap['statuses'] {
  return statuses.map((item) => ({ ...item, label: localizeStatusLabel(item.label, t) }))
}

function localizeStatusLabel(label: string, t: ReturnType<typeof useI18n>['t']): string {
  switch (label) {
  case 'Ready':
    return t('canvas.statusReady')
  case 'Running':
    return t('canvas.statusRunning')
  case 'Attention':
    return t('canvas.statusAttention')
  case 'Done':
    return t('canvas.statusDone')
  case 'Artifacts':
    return t('canvas.statusArtifacts')
  case 'Scheduled':
    return t('canvas.statusScheduled')
  default:
    return label
  }
}

function monitorBadgeFor(monitor: CanvasMonitor | null | undefined, t: ReturnType<typeof useI18n>['t']): {
  label: string
  tone: 'clear' | 'reply' | 'blocked'
} {
  const needsReply = monitor?.counts.needsHumanReply ?? 0
  if (needsReply > 0) {
    return { label: t('canvas.monitorNeedsReply', { count: needsReply }), tone: 'reply' }
  }
  const blocked = (monitor?.counts.blocked ?? 0) + (monitor?.counts.failed ?? 0)
  if (blocked > 0) {
    return { label: t('canvas.monitorBlocked', { count: blocked }), tone: 'blocked' }
  }
  return { label: t('canvas.monitorAllClear'), tone: 'clear' }
}

async function generateAIRecap(
  state: PlannerGraphState,
  canvas: CanvasInfo,
  monitor: CanvasMonitor | null,
): Promise<Pick<CanvasRecap, 'headline' | 'details'>> {
  const llm = readLlmSettings()
  let text = ''
  for await (const ev of streamAssistantChat({
    messages: [{ role: 'user', content: buildAIRecapPrompt({ plannerState: state, monitor }) }],
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

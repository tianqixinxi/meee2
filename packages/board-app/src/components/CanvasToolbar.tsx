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
import { useI18n } from '../lib/i18n'
import type { BoardState, CanvasInfo, CanvasScope, PlannerGraphState } from '../types'
import type { UserProfile } from '../api'
import {
  buildAIRecapPrompt,
  buildCanvasStatusRecap as buildCoreCanvasStatusRecap,
  buildEmptyCanvasRecap as buildCoreEmptyCanvasRecap,
  editableCanvasDescription,
  formatRecapAge,
  parseAIRecap,
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
  onOpenAllSessions,
}: Props) {
  const { t } = useI18n()
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
  // AIRecapDrawer removed (user feedback) — toolbar banner is the single recap surface.

  // UI-simplification — hover a canvas in the dropdown → popover shows that
  // canvas's semantic recap (headline + details). Data source is
  // recapCacheRef which is populated as user views each canvas; missing
  // entries fall back to a "not fetched yet" hint.
  const [hoveredCanvasId, setHoveredCanvasId] = useState<string | null>(null)
  const [hoverAnchor, setHoverAnchor] = useState<{ top: number; right: number } | null>(null)

  const activeCanvas = canvases.find((canvas) => canvas.id === activeCanvasId) ?? canvases[0]
  const filteredCanvases = useMemo(() => canvases.filter((canvas) => {
    const query = canvasQuery.trim().toLowerCase()
    if (!query) return true
    return [canvas.name, canvas.id, visibilityLabel(canvas, t), canvasTypeLabel(canvas, t)]
      .some((value) => value.toLowerCase().includes(query))
  }), [canvasQuery, canvases, t])

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
      const baseRecap = buildCanvasStatusRecap(state, t)
      setRecap(baseRecap)
      if (isBlankPlannerCanvas(state)) {
        const nextRecap = buildBlankCanvasRecap(state, t)
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
    void refreshRecap()
  }, [activeCanvas?.id, refreshRecap, t])

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
    if (!activeCanvas || !onClearCanvas || activeCanvas.kind === 'monitor') return
    Promise.resolve(onClearCanvas(activeCanvas.id)).then(() => {
      setClearConfirming(false)
      setInfoOpen(false)
      setMenuOpen(false)
    })
  }

  if (!activeCanvas) return null
  const canClearCanvas = Boolean(onClearCanvas && activeCanvas.kind !== 'monitor')

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
                    onMouseEnter={(e) => {
                      const rect = e.currentTarget.getBoundingClientRect()
                      setHoveredCanvasId(canvas.id)
                      setHoverAnchor({ top: rect.top, right: rect.right })
                    }}
                    onMouseLeave={() => {
                      setHoveredCanvasId(null)
                      setHoverAnchor(null)
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
                        <span className={`canvas-toolbar__type canvas-toolbar__type--${canvas.kind ?? 'board'}`}>
                          {canvasTypeLabel(canvas, t)}
                        </span>
                      </span>
                  </button>
                )
              })}
              {filteredCanvases.length === 0 && (
                <div className="canvas-toolbar__empty">{t('canvas.noMatch')}</div>
              )}
            </div>
          </div>
        )}
      </div>
      <div className="canvas-toolbar__context" aria-live="polite">
        <div className="canvas-toolbar__recap">
          <div
            className="canvas-toolbar__recap-trigger"
            aria-label={t('canvas.openRecap')}
            title={recap?.headline ?? t('canvas.readingState')}
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
          </div>
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
          {/* UI-simplification — monitor 信息简化版,从老 WorkspaceMonitor / drawer 里
           *  抢救出两条最关键的:failed sessions(boardState.sessions 里 status 异常的)
           *  + 等批 proposals 数。仅在非 0 时显示,不挤占空间。 */}
          {(() => {
            const failedSessions = (boardState?.sessions ?? []).filter((s) =>
              s.status === 'permissionRequired' ||
              s.pendingPermissionTool ||
              s.status === 'failed'
            ).length
            if (failedSessions <= 0) return null
            return (
              <span className="canvas-toolbar__status-pill is-attention" title="Sessions needing attention">
                <strong>{failedSessions}</strong>
                <small>Session attn</small>
              </span>
            )
          })()}
        </div>
      )}

      {/* UI-simplification — hover canvas item in dropdown → semantic recap popover */}
      {hoveredCanvasId && hoverAnchor && (() => {
        const hovered = canvases.find((c) => c.id === hoveredCanvasId)
        if (!hovered) return null
        const cached = recapCacheRef.current[hoveredCanvasId]
        return (
          <div
            className="canvas-toolbar__hover-recap"
            style={{
              position: 'fixed',
              top: hoverAnchor.top,
              left: hoverAnchor.right + 8,
              pointerEvents: 'none',
            }}
          >
            <div className="canvas-toolbar__hover-recap-title">{displayCanvasName(hovered)}</div>
            {cached ? (
              <>
                {cached.headline && (
                  <div className="canvas-toolbar__hover-recap-headline">{cached.headline}</div>
                )}
                {cached.details && cached.details.length > 0 && (
                  <ul className="canvas-toolbar__hover-recap-details">
                    {cached.details.slice(0, 4).map((d, i) => <li key={i}>{d}</li>)}
                  </ul>
                )}
                {cached.updatedAt && (
                  <div className="canvas-toolbar__hover-recap-meta">
                    {formatRecapAge(cached.updatedAt, Date.now())} · {cached.mode}
                  </div>
                )}
              </>
            ) : (
              <div className="canvas-toolbar__hover-recap-empty">
                还没看过这个画板,recap 待生成
              </div>
            )}
          </div>
        )
      })()}

      {/* AIRecapDrawer 已删 — 按 user 反馈,toolbar 自己这条 parseRecapJSON banner
       *  (headline + details + 「刚刚」age + refresh icon)就够用了,drawer 是冗余。
       *  之前 drawer 里独有的 monitor 维度信息(gate-blocked / failed sessions /
       *  recent versions)用 .canvas-toolbar__monitor-strip 简化呈现在 banner 同一区。 */}

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
              <div className="modal-subtitle">{t('canvas.typedCanvas', {
                visibility: visibilityLabel(activeCanvas, t),
                type: canvasTypeLabel(activeCanvas, t),
              })}</div>
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
                    <span>{t('canvas.type')}</span>
                    <strong>{canvasTypeLabel(activeCanvas, t)}</strong>
                  </div>
                  {activeCanvas.kind === 'monitor' && (
                    <div className="canvas-info-modal__row">
                      <span>{t('canvas.aggregation')}</span>
                      <strong>{t('canvas.monitorAggregation')}</strong>
                    </div>
                  )}
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
                  {canClearCanvas && (
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
      {clearConfirming && canClearCanvas && (
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
  return canvas.name === 'Default canvas' ? 'Monitor' : canvas.name
}

function canvasTypeLabel(canvas: CanvasInfo, t: ReturnType<typeof useI18n>['t']): string {
  if (canvas.kind === 'monitor') return t('canvas.type.monitor')
  if (canvas.kind === 'template') return t('canvas.type.template')
  return t('canvas.type.board')
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

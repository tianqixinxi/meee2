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
import {
  fetchTemplateCatalog,
  setPlannerCanvasDescription,
  streamAssistantChat,
  type TemplateMetadataInput,
} from '../api'
import {
  ALLOW_CLOUD_PREFERENCES_CHANGED,
  CANVAS_RECAP_PREFERENCES_CHANGED,
  loadAllowCloud,
  loadCanvasRecapIntervalMinutes,
} from '../preferences'
import { readLlmSettings } from '../lib/llmSettings'
import { useI18n } from '../lib/i18n'
import type { BoardState, CanvasInfo, CanvasKind, CanvasScope, PlannerGraphState } from '../types'
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
  onCreateCanvas: (name: string, scope: CanvasScope, kind?: CanvasKind) => Promise<void> | void
  onRenameCanvas: (canvasId: string, name: string) => Promise<void> | void
  onClearCanvas?: (canvasId: string) => Promise<void> | void
  onDeleteCanvas: (canvasId: string) => Promise<void> | void
  onSaveCanvasAsTemplate?: (canvasId: string, input: TemplateMetadataInput) => Promise<void | string> | void
  onReplaceTemplate?: (
    templateId: string,
    canvasId: string,
    input: { name?: string; description?: string; tags?: string[]; defaultCanvasKind?: Exclude<CanvasKind, 'template'> },
  ) => Promise<void | string> | void
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

const DEFAULT_TEMPLATE_TAGS = ['engineering', 'code-review', 'release', 'monitor', 'workflow', 'recap', 'research', 'design', 'ops', 'demo']

// 用户只能创建 board canvas。
//  - monitor 是系统预置的默认首页(isDefault + 唯一),不暴露给用户创建,否则会
//    出现「我新建一个 monitor,它默认监控所有 canvas」的行为错位
//  - template 是 gallery 里 builtin template 用的,不是工作画板
//  - kanban / inbox / matrix 不是 canvas 类型,是节点级 widget,跟 canvas
//    心智正交(见 PlanningNode.widget,phase 2 落地)
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
  onSaveCanvasAsTemplate,
  onReplaceTemplate,
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
  // 创建路径只产 board kind canvas;视图变化走节点级 widget,见 PlanningNode.widget
  const [clearConfirming, setClearConfirming] = useState(false)
  const [deleteConfirming, setDeleteConfirming] = useState(false)
  const [replaceTemplateConfirming, setReplaceTemplateConfirming] = useState(false)
  const [replaceTemplateSaving, setReplaceTemplateSaving] = useState(false)
  const [replaceTemplateError, setReplaceTemplateError] = useState<string | null>(null)
  const [saveTemplateOpen, setSaveTemplateOpen] = useState(false)
  const [saveTemplateName, setSaveTemplateName] = useState('')
  const [saveTemplateDescription, setSaveTemplateDescription] = useState('')
  const [saveTemplateScope, setSaveTemplateScope] = useState<CanvasScope>('personal')
  const [saveTemplateTags, setSaveTemplateTags] = useState<string[]>([])
  const [saveTemplateAvailableTags, setSaveTemplateAvailableTags] = useState<string[]>(DEFAULT_TEMPLATE_TAGS)
  const [saveTemplateSaving, setSaveTemplateSaving] = useState(false)
  const [saveTemplateError, setSaveTemplateError] = useState<string | null>(null)
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
  const [hoveredCanvasId, setHoveredCanvasId] = useState<string | null>(null)
  const [hoverAnchor, setHoverAnchor] = useState<{ top: number; right: number } | null>(null)
  // ui-simplification §1 — failed/permission-pending sessions 转译成「需关注的
  // 进展」。多条时点击 pill 展开 dropdown 让用户挑一条跳过去。
  const [attentionMenuOpen, setAttentionMenuOpen] = useState(false)
  const attentionRef = useRef<HTMLSpanElement | null>(null)

  useEffect(() => {
    if (!attentionMenuOpen) return
    const onPointerDown = (event: PointerEvent) => {
      const node = attentionRef.current
      if (node && event.target instanceof Node && node.contains(event.target)) return
      setAttentionMenuOpen(false)
    }
    document.addEventListener('pointerdown', onPointerDown, true)
    return () => document.removeEventListener('pointerdown', onPointerDown, true)
  }, [attentionMenuOpen])

  const activeCanvas = canvases.find((canvas) => canvas.id === activeCanvasId) ?? canvases[0]
  const filteredCanvasEntries = useMemo(
    () => buildCanvasListEntries(canvases, canvasQuery, t),
    [canvasQuery, canvases, t],
  )
  // ui-simplification §1: kind 是隐藏词,switcher 不暴露 board/monitor/template
  // 文案。scope (private/team) 不在隐藏词清单里但在单一 scope 列表里纯噪音 —
  // 只有当列表里同时存在 team 和 personal 时才渲染一个 icon 来快速辨识。
  const showScopeIcon = useMemo(() => {
    const hasTeam = canvases.some((c) => c.scope === 'team')
    const hasPersonal = canvases.some((c) => c.scope !== 'team')
    return hasTeam && hasPersonal
  }, [canvases])

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
      // Chunk E (Privacy UI): when cloud calls are disabled, skip the AI
      // overlay entirely and persist the local-only baseRecap.
      if (!loadAllowCloud()) {
        const nextRecap = { ...baseRecap, updatedAt: new Date().toISOString() }
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
    const reload = () => setRecapIntervalMinutes(loadCanvasRecapIntervalMinutes())
    const refreshCloudPreference = () => void refreshRecap()
    window.addEventListener(CANVAS_RECAP_PREFERENCES_CHANGED, reload)
    window.addEventListener(ALLOW_CLOUD_PREFERENCES_CHANGED, refreshCloudPreference)
    window.addEventListener('storage', reload)
    return () => {
      window.removeEventListener(CANVAS_RECAP_PREFERENCES_CHANGED, reload)
      window.removeEventListener(ALLOW_CLOUD_PREFERENCES_CHANGED, refreshCloudPreference)
      window.removeEventListener('storage', reload)
    }
  }, [refreshRecap])

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
    Promise.resolve(onCreateCanvas(name, canvasScopeDraft, 'board')).then(() => {
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

  const openSaveTemplate = () => {
    if (!activeCanvas || activeCanvas.kind === 'template' || activeCanvas.kind === 'monitor') return
    setSaveTemplateName(`${displayCanvasName(activeCanvas)} template`)
    setSaveTemplateDescription(recap?.description ?? '')
    setSaveTemplateScope('personal')
    setSaveTemplateTags([])
    setSaveTemplateError(null)
    setSaveTemplateOpen(true)
    setInfoOpen(false)
    fetchTemplateCatalog()
      .then((catalog) => setSaveTemplateAvailableTags(catalog.tags.length > 0 ? catalog.tags : DEFAULT_TEMPLATE_TAGS))
      .catch(() => setSaveTemplateAvailableTags(DEFAULT_TEMPLATE_TAGS))
  }

  const closeSaveTemplate = () => {
    if (saveTemplateSaving) return
    setSaveTemplateOpen(false)
    setSaveTemplateError(null)
  }

  const submitSaveTemplate = () => {
    if (!activeCanvas || !onSaveCanvasAsTemplate || activeCanvas.kind === 'monitor') return
    const name = saveTemplateName.trim()
    if (!name) {
      setSaveTemplateError('Template name is required')
      return
    }
    setSaveTemplateSaving(true)
    setSaveTemplateError(null)
    Promise.resolve(onSaveCanvasAsTemplate(activeCanvas.id, {
      name,
      description: saveTemplateDescription.trim(),
      scope: saveTemplateScope,
      tags: saveTemplateTags,
      icon: 'sparkles',
      defaultCanvasKind: templateKindForCanvas(activeCanvas),
    }))
      .then(() => {
        setSaveTemplateSaving(false)
        setSaveTemplateOpen(false)
      })
      .catch((err) => {
        setSaveTemplateSaving(false)
        setSaveTemplateError((err as Error).message || 'Failed to save template')
      })
  }

  const submitReplaceTemplate = () => {
    if (!activeCanvas?.draftOfTemplateId || !onReplaceTemplate) return
    setReplaceTemplateSaving(true)
    setReplaceTemplateError(null)
    Promise.resolve(onReplaceTemplate(activeCanvas.draftOfTemplateId, activeCanvas.id, {
      name: activeCanvas.name.replace(/\s+draft$/i, ''),
      defaultCanvasKind: activeCanvas.kind === 'monitor' ? 'monitor' : 'board',
    }))
      .then(() => {
        setReplaceTemplateSaving(false)
        setReplaceTemplateConfirming(false)
      })
      .catch((err) => {
        setReplaceTemplateSaving(false)
        setReplaceTemplateError((err as Error).message || 'Failed to replace template')
      })
  }

  if (!activeCanvas) return null
  const isMonitorCanvas = activeCanvas.kind === 'monitor'
  const monitorBadge = monitorBadgeFor(canvasMonitor, t)
  const canClearCanvas = Boolean(onClearCanvas && activeCanvas.kind !== 'monitor')
  const canSaveActiveCanvasAsTemplate = Boolean(
    onSaveCanvasAsTemplate && activeCanvas.kind !== 'template' && activeCanvas.kind !== 'monitor',
  )

  return (
    <div className={`canvas-toolbar${isMonitorCanvas ? ' canvas-toolbar--monitor' : ''}`} ref={rootRef}>
      {activeCanvas.draftOfTemplateId && (
        <div className="canvas-toolbar__draft-banner">
          <span>
            <strong>Editing template draft</strong>
            <small>Replace the original template when this canvas is tuned.</small>
          </span>
          <button
            type="button"
            className="primary"
            onClick={() => {
              setReplaceTemplateError(null)
              setReplaceTemplateConfirming(true)
            }}
            disabled={!onReplaceTemplate}
          >
            Replace template
          </button>
        </div>
      )}
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
                        {canvas.isDefault && (
                          <span className="canvas-toolbar__default-badge" title={t('canvas.cannotDelete')} aria-label="Default">
                            Default
                          </span>
                        )}
                        {showScopeIcon && (
                          <span
                            className={`canvas-toolbar__visibility canvas-toolbar__visibility--${visibilityTone(canvas)}`}
                            title={visibilityLabel(canvas, t)}
                            aria-label={visibilityLabel(canvas, t)}
                          >
                            {canvas.scope === 'team' ? <Globe2 size={10} aria-hidden /> : <LockKeyhole size={10} aria-hidden />}
                          </span>
                        )}
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
      {!isMonitorCanvas && (
        <div className="canvas-toolbar__context" aria-live="polite">
          <div className="canvas-toolbar__recap">
            <button
              type="button"
              className="canvas-toolbar__recap-trigger"
              aria-label={t('canvas.openRecap')}
              aria-expanded={recapDrawerOpen}
              title={recap?.headline ?? t('canvas.readingState')}
              onClick={() => setRecapDrawerOpen((value) => !value)}
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
      )}
      {!isMonitorCanvas && recap?.mode !== 'empty' && recap?.statuses && (
        <div className="canvas-toolbar__status-strip" aria-label={t('canvas.statusOverview')}>
          {recap.statuses.map((item) => (
            <span key={item.label} className={`canvas-toolbar__status-pill is-${item.tone}`}>
              <strong>{item.value}</strong>
              <small>{item.label}</small>
            </span>
          ))}
          {/* UI-simplification §1 — session 是隐藏词,对外口径统一叫「进展」。
           *  这里把 boardState.sessions 里 status 异常 / 等待权限的条目转译成
           *  「需关注的进展」pill,点击直接跳到对应 session 详情:
           *  - 1 条:直接 dispatch meee2:open-session(切到 SessionsView + 选中)
           *  - 多条:展开 dropdown 列出节点名 + 状态,点一条跳过去
           *  仅在非 0 时显示,不挤占空间。 */}
          {(() => {
            const attentionSessions = (boardState?.sessions ?? []).filter((s) =>
              s.status === 'permissionRequired' ||
              s.pendingPermissionTool ||
              s.status === 'failed'
            )
            if (attentionSessions.length <= 0) return null
            const count = attentionSessions.length
            const openSession = (sessionId: string) => {
              window.dispatchEvent(new CustomEvent('meee2:open-session', {
                detail: { sessionId },
              }))
              setAttentionMenuOpen(false)
            }
            const handlePillClick = () => {
              if (count === 1) {
                openSession(attentionSessions[0].id)
                return
              }
              setAttentionMenuOpen((value) => !value)
            }
            return (
              <span className="canvas-toolbar__attention-wrap" ref={attentionRef}>
                <button
                  type="button"
                  className="canvas-toolbar__status-pill is-attention canvas-toolbar__attention-trigger"
                  title={t('canvas.attentionPillTitle')}
                  aria-label={t('canvas.attentionPill', { count: String(count) })}
                  aria-haspopup={count > 1 ? 'menu' : undefined}
                  aria-expanded={count > 1 ? attentionMenuOpen : undefined}
                  onClick={handlePillClick}
                >
                  <strong>{count}</strong>
                  <small>{t('canvas.attentionPillShort')}</small>
                </button>
                {attentionMenuOpen && count > 1 && (
                  <div className="canvas-toolbar__attention-menu" role="menu">
                    {attentionSessions.map((session) => {
                      const reason = session.pendingPermissionTool
                        ? session.pendingPermissionTool
                        : session.status
                      return (
                        <button
                          key={session.id}
                          type="button"
                          role="menuitem"
                          className="canvas-toolbar__attention-item"
                          onClick={() => openSession(session.id)}
                        >
                          <span className="canvas-toolbar__attention-item-title">
                            {session.title || session.project || session.id.slice(0, 8)}
                          </span>
                          <span className="canvas-toolbar__attention-item-reason">{reason}</span>
                        </button>
                      )
                    })}
                  </div>
                )}
              </span>
            )
          })()}
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
            }}
            onMouseEnter={() => {
              // Cursor entered the popover itself; the underlying row's
              // onMouseLeave already cleared state. Re-pin so the popover
              // stays visible (and scroll/text-select works).
              setHoveredCanvasId(hoveredCanvasId)
              setHoverAnchor(hoverAnchor)
            }}
            onMouseLeave={() => {
              setHoveredCanvasId(null)
              setHoverAnchor(null)
            }}
          >
            <div className="canvas-toolbar__hover-recap-title">{displayCanvasName(hovered)}</div>
            {cached ? (
              <>
                {cached.updatedAt && (
                  <div className="canvas-toolbar__hover-recap-meta" data-mode={cached.mode}>
                    {formatRecapAge(cached.updatedAt, Date.now())}
                  </div>
                )}
              </>
            ) : (
              <div className="canvas-toolbar__hover-recap-empty">
                还没有进展摘要,首次进入画板会自动生成
              </div>
            )}
          </div>
        )
      })()}

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
                  <p>
                    {t('canvas.scopedHelp')}
                  </p>
                  <details className="canvas-info-modal__advanced">
                    <summary>{t('canvas.advanced')}</summary>
                    <div className="canvas-info-modal__row">
                      <span>{t('canvas.id')}</span>
                      <strong className="is-mono">{activeCanvas.id}</strong>
                    </div>
                  </details>
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
                  {canSaveActiveCanvasAsTemplate && (
                    <div className="canvas-info-modal__template-action">
                      <div>
                        <strong>Template</strong>
                        <p>Turn this tuned canvas into a reusable template.</p>
                      </div>
                      <button type="button" className="ghost" onClick={openSaveTemplate}>
                        Save as template
                      </button>
                    </div>
                  )}
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

      {saveTemplateOpen && canSaveActiveCanvasAsTemplate && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) closeSaveTemplate()
          }}
        >
          <div className="modal canvas-confirm-modal" role="dialog" aria-modal="true" aria-label="Save as template">
            <div className="modal-header">
              <div className="modal-title">Save as template</div>
              <div className="modal-subtitle">Creates a reusable template from this canvas after stripping live runtime state.</div>
            </div>
            <div className="modal-body col canvas-toolbar__template-form">
              <input
                value={saveTemplateName}
                onChange={(event) => setSaveTemplateName(event.target.value)}
                placeholder="Template name"
                autoFocus
                disabled={saveTemplateSaving}
              />
              <textarea
                value={saveTemplateDescription}
                onChange={(event) => setSaveTemplateDescription(event.target.value)}
                placeholder="Description"
                rows={3}
                disabled={saveTemplateSaving}
              />
              <div className="canvas-toolbar__scope-toggle" role="group" aria-label="Template visibility">
                {(['personal', 'team'] as CanvasScope[]).map((scope) => (
                  <button
                    key={scope}
                    type="button"
                    className={saveTemplateScope === scope ? 'is-selected' : ''}
                    aria-pressed={saveTemplateScope === scope}
                    disabled={saveTemplateSaving}
                    onClick={() => setSaveTemplateScope(scope)}
                  >
                    {scope === 'team' ? 'Team' : 'Private'}
                  </button>
                ))}
              </div>
              <div className="canvas-toolbar__template-tags" aria-label="Template tags">
                {saveTemplateAvailableTags.map((tag) => {
                  const active = saveTemplateTags.includes(tag)
                  return (
                    <button
                      key={tag}
                      type="button"
                      className={active ? 'is-active' : ''}
                      aria-pressed={active}
                      disabled={saveTemplateSaving}
                      onClick={() => setSaveTemplateTags((current) => (
                        active ? current.filter((item) => item !== tag) : [...current, tag]
                      ))}
                    >
                      {tag}
                    </button>
                  )
                })}
              </div>
              {saveTemplateError && <div className="inline-error">{saveTemplateError}</div>}
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={closeSaveTemplate} disabled={saveTemplateSaving}>{t('common.cancel')}</button>
              <button className="primary" type="button" onClick={submitSaveTemplate} disabled={saveTemplateSaving || !saveTemplateName.trim()}>
                {saveTemplateSaving ? 'Saving...' : 'Save template'}
              </button>
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
              {/* UI-simplification chunk G — 「从模板新建」 是首选 CTA,首屏入口最显眼。
               *  「从空白开始」 仍保留但降级为 secondary,字号小一档颜色淡一档(下方表单 + 按钮)。
               *  Templates view 切换走 window event(App.tsx 已有 meee2:open-settings 同款模式)。 */}
              <button
                type="button"
                className="canvas-toolbar__template-cta"
                onClick={() => {
                  setCreating(false)
                  setMenuOpen(false)
                  window.dispatchEvent(new CustomEvent('meee2:nav-templates'))
                }}
              >
                <Sparkles size={14} aria-hidden />
                <span className="canvas-toolbar__template-cta-main">
                  <strong>从模板新建</strong>
                  <small>挑一个预设画板:看板 / 收件箱 / Owner 矩阵 / Monitor…</small>
                </span>
                <span className="canvas-toolbar__template-cta-arrow" aria-hidden>→</span>
              </button>

              <div className="canvas-toolbar__blank-divider">
                <span>或</span>
              </div>

              <div className="canvas-toolbar__blank-section">
                <div className="canvas-toolbar__blank-label">从空白画板开始</div>
                <input
                  value={canvasNameDraft}
                  onChange={(event) => setCanvasNameDraft(event.target.value)}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter') submitCreate()
                    if (event.key === 'Escape') setCreating(false)
                  }}
                  placeholder={t('canvas.namePlaceholder')}
                />
                {/* Scope toggle 已移除 — ui-simplification §1「藏起来的词」: 创建瞬间用户只面对画板+名字,
                 *  scope 默认 personal,可见性变更走 Canvas Info modal。Kind selector 同样隐藏。 */}
              </div>
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setCreating(false)}>{t('common.cancel')}</button>
              <button
                className="secondary canvas-toolbar__blank-submit"
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
      {replaceTemplateConfirming && activeCanvas.draftOfTemplateId && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget && !replaceTemplateSaving) setReplaceTemplateConfirming(false)
          }}
        >
          <div className="modal canvas-confirm-modal" role="dialog" aria-modal="true" aria-label="Replace template">
            <div className="modal-header">
              <div className="modal-title">Replace template</div>
              <div className="modal-subtitle">
                The original template keeps its id and version history. Live session state from this draft will be stripped.
              </div>
            </div>
            <div className="modal-body col" style={{ gap: 8 }}>
              <strong>{activeCanvas.name}</strong>
              <code>{activeCanvas.draftOfTemplateId}</code>
              {replaceTemplateError && <div className="inline-error">{replaceTemplateError}</div>}
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setReplaceTemplateConfirming(false)} disabled={replaceTemplateSaving}>{t('common.cancel')}</button>
              <button className="primary" type="button" onClick={submitReplaceTemplate} disabled={replaceTemplateSaving}>
                {replaceTemplateSaving ? 'Replacing...' : 'Replace template'}
              </button>
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

function templateKindForCanvas(canvas: CanvasInfo): TemplateMetadataInput['defaultCanvasKind'] {
  return canvas.kind === 'monitor' ? 'monitor' : 'board'
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
    return [canvas.name, canvas.id, visibilityLabel(canvas, t), canvasTypeLabel(canvas, t)]
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
  // Chunk E (Privacy UI): when the user has flipped off "allow cloud / model
  // calls", short-circuit before any LLM fetch. The caller already computed a
  // local `baseRecap` (from `buildCanvasStatusRecap`), so returning an empty
  // overlay just leaves that local-only recap in place.
  if (!loadAllowCloud()) {
    return {
      headline: '',
      details: [],
    }
  }
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

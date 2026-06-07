import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { CSSProperties, PointerEvent as ReactPointerEvent } from 'react'
import {
  AlertTriangle,
  ArrowLeft,
  ArrowRight,
  Check,
  ChevronDown,
  ChevronUp,
  Eraser,
  Info,
  Layers,
  LockKeyhole,
  PanelLeftClose,
  PanelLeftOpen,
  Plus,
  RefreshCw,
  Search,
  Share2,
  Sparkles,
  Trash2,
  UserRound,
} from 'lucide-react'
import {
  fetchTeamMembers,
  fetchTemplateCatalog,
  revealCanvasRenderProfile,
  setPlannerCanvasDescription,
  streamAssistantChat,
  type TemplateMetadataInput,
} from '../api'
import {
  ALLOW_CLOUD_PREFERENCES_CHANGED,
  CANVAS_RECAP_PREFERENCES_CHANGED,
  loadAllowCloud,
  loadCanvasRecapPosition,
  loadCanvasRecapIntervalMinutes,
  saveCanvasRecapPosition,
} from '../preferences'
import { readLlmSettings } from '../lib/llmSettings'
import { useI18n } from '../lib/i18n'
import type { BoardState, CanvasInfo, CanvasKind, CanvasScope, PlannerGraphState } from '../types'
import type { TeamMember, UserProfile } from '../api'
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
  onSetCanvasVisibility?: (canvasId: string, visibility: 'private' | 'public') => Promise<void> | void
  onSaveCanvasAsTemplate?: (canvasId: string, input: TemplateMetadataInput) => Promise<void | string> | void
  onReplaceTemplate?: (
    templateId: string,
    canvasId: string,
    input: { name?: string; description?: string; tags?: string[]; defaultCanvasKind?: CanvasKind },
  ) => Promise<void | string> | void
  onResolveCanvasConflict?: (canvasId: string, choice: 'current' | 'remote') => Promise<void> | void
  userProfile?: UserProfile | null
  boardState?: BoardState | null
  plannerState?: PlannerGraphState | null
  canvasMonitor?: CanvasMonitor | null
  plannerDialogCollapsed?: boolean
  onTogglePlannerDialog?: () => void
}

type CanvasRecap = CoreCanvasStatusRecap & {
  mode: 'ai' | 'empty'
  summary?: string
}

type OwnerIdentity = {
  displayName: string
  avatarUrl: string | null
}

type RecapDragState = {
  pointerId: number
  startClientX: number
  startClientY: number
  originX: number
  originY: number
  width: number
  height: number
}

type CanvasListTab = 'my' | 'team'

const DEFAULT_TEMPLATE_TAGS = ['engineering', 'code-review', 'release', 'monitor', 'workflow', 'recap', 'research', 'design', 'ops', 'demo']

const RECAP_AUTO_COLLAPSE_MS = 3_000

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
  onSetCanvasVisibility,
  onSaveCanvasAsTemplate,
  onReplaceTemplate,
  onResolveCanvasConflict,
  userProfile = null,
  boardState = null,
  plannerState = null,
  canvasMonitor = null,
  plannerDialogCollapsed = false,
  onTogglePlannerDialog,
}: Props) {
  const { t } = useI18n()
  const rootRef = useRef<HTMLDivElement | null>(null)
  const recapContextRef = useRef<HTMLDivElement | null>(null)
  const recapRequestRef = useRef(0)
  const recapCacheRef = useRef<Record<string, CanvasRecap>>({})
  const recapAutoAttemptedRef = useRef<Set<string>>(new Set())
  // Manual/interval recap requests can outlive state churn. Keep one AI recap
  // per canvas in flight so a slow local assistant cannot stack duplicate runs.
  const recapInFlightRef = useRef<Set<string>>(new Set())
  const recapCollapseTimerRef = useRef<number | null>(null)
  const recapHoveringRef = useRef(false)
  const recapDragRef = useRef<RecapDragState | null>(null)
  const plannerStateRef = useRef<PlannerGraphState | null>(plannerState)
  const canvasMonitorRef = useRef<CanvasMonitor | null>(canvasMonitor)
  const hoverHideTimerRef = useRef<number | null>(null)
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
  const [infoError, setInfoError] = useState<string | null>(null)
  const [canvasQuery, setCanvasQuery] = useState('')
  const [canvasNameDraft, setCanvasNameDraft] = useState('')
  const [canvasDescriptionDraft, setCanvasDescriptionDraft] = useState('')
  const [canvasDescriptionSaving, setCanvasDescriptionSaving] = useState(false)
  const [canvasVisibilitySaving, setCanvasVisibilitySaving] = useState(false)
  const [canvasScopeDraft, setCanvasScopeDraft] = useState<CanvasScope>('personal')
  const [recapIntervalMinutes, setRecapIntervalMinutes] = useState(loadCanvasRecapIntervalMinutes)
  const [recap, setRecap] = useState<CanvasRecap | null>(null)
  const [recapLoading, setRecapLoading] = useState(false)
  const [recapError, setRecapError] = useState<string | null>(null)
  const [recapPosition, setRecapPosition] = useState<{ x: number; y: number } | null>(null)
  // recap 收起(默认)/ 展开二态。展开:summary + details + status-strip 全显示;
  // 收起:只留一行 headline,连 details + status-strip 一起收,给悬浮的 session
  // overlay 让出 canvas 空间(overlay 顶部跟随 --canvas-toolbar-bottom 自适应,见下方
  // ResizeObserver;recap 整条 z-index 240 > overlay 70,收起的一行 headline 仍盖其上)。
  const [recapExpanded, setRecapExpanded] = useState(false)
  const [recapAgeNow, setRecapAgeNow] = useState(() => Date.now())
  const [hoveredCanvasId, setHoveredCanvasId] = useState<string | null>(null)
  const [hoverAnchor, setHoverAnchor] = useState<{ top: number; right: number } | null>(null)
  const [ownerDirectory, setOwnerDirectory] = useState<Record<string, OwnerIdentity>>({})
  const [canvasListTab, setCanvasListTab] = useState<CanvasListTab>('my')
  const [resolvingConflictCanvasId, setResolvingConflictCanvasId] = useState<string | null>(null)
  const [conflictResolveError, setConflictResolveError] = useState<string | null>(null)
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
  const shouldShowCanvasTabs = Boolean(userProfile?.connected || canvases.some((canvas) => canvas.scope === 'team'))
  const filteredCanvasEntries = useMemo(
    () => buildCanvasListEntries(canvases, canvasQuery, t),
    [canvasQuery, canvases, t],
  )
  const groupedCanvasEntries = useMemo(
    () => groupCanvasEntries(filteredCanvasEntries, { includeEmptyGroups: shouldShowCanvasTabs }),
    [filteredCanvasEntries, shouldShowCanvasTabs],
  )
  const canvasEntryGroups = useMemo(
    () => groupCanvasEntries(buildCanvasListEntries(canvases, '', t), { includeEmptyGroups: shouldShowCanvasTabs }),
    [canvases, shouldShowCanvasTabs, t],
  )
  const showCanvasTabs = shouldShowCanvasTabs && canvasEntryGroups.length > 1
  const selectedCanvasGroup = groupedCanvasEntries.find((group) => group.id === canvasListTab)
    ?? (showCanvasTabs
      ? { id: canvasListTab, label: canvasListTab === 'my' ? 'My Canvases' : 'Team Canvases', entries: [] }
      : groupedCanvasEntries[0])
  const canManageTeamSharing = Boolean(
    activeCanvas &&
    !activeCanvas.isDefault &&
    ownsCanvas(activeCanvas, userProfile?.userId ?? '') &&
    userProfile?.connected &&
    onSetCanvasVisibility,
  )

  useEffect(() => {
    if (!menuOpen) return
    const activeGroup = canvasEntryGroups.find((group) => group.entries.some((entry) => entry.canvas.id === activeCanvasId))
    if (activeGroup) setCanvasListTab(activeGroup.id)
  }, [activeCanvasId, canvasEntryGroups, menuOpen])

  useEffect(() => {
    setRecapPosition(activeCanvas ? loadCanvasRecapPosition(activeCanvas.id) : null)
  }, [activeCanvas?.id])

  const closePanels = () => {
    setCreating(false)
    setClearConfirming(false)
    setDeleteConfirming(false)
  }

  const cancelHoverHide = () => {
    if (hoverHideTimerRef.current !== null) {
      window.clearTimeout(hoverHideTimerRef.current)
      hoverHideTimerRef.current = null
    }
  }

  const hideCanvasHoverSoon = () => {
    cancelHoverHide()
    hoverHideTimerRef.current = window.setTimeout(() => {
      setHoveredCanvasId(null)
      setHoverAnchor(null)
      hoverHideTimerRef.current = null
    }, 140)
  }

  const showCanvasHover = (canvasId: string, rect: DOMRect) => {
    cancelHoverHide()
    if (canvasId !== hoveredCanvasId) setConflictResolveError(null)
    setHoveredCanvasId(canvasId)
    setHoverAnchor({ top: rect.top, right: rect.right })
  }

  const cancelRecapAutoCollapse = () => {
    if (recapCollapseTimerRef.current !== null) {
      window.clearTimeout(recapCollapseTimerRef.current)
      recapCollapseTimerRef.current = null
    }
  }

  const scheduleRecapAutoCollapse = (expanded = recapExpanded) => {
    cancelRecapAutoCollapse()
    if (!expanded) return
    recapCollapseTimerRef.current = window.setTimeout(() => {
      setRecapExpanded(false)
      recapCollapseTimerRef.current = null
    }, RECAP_AUTO_COLLAPSE_MS)
  }

  const handleRecapMouseEnter = () => {
    recapHoveringRef.current = true
    cancelRecapAutoCollapse()
  }

  const handleRecapMouseLeave = () => {
    recapHoveringRef.current = false
    scheduleRecapAutoCollapse()
  }

  const handleRecapDragPointerDown = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (!activeCanvas) return
    const node = recapContextRef.current
    if (!node) return
    const rect = node.getBoundingClientRect()
    const origin = clampRecapPosition(
      recapPosition?.x ?? rect.left,
      recapPosition?.y ?? rect.top,
      rect.width,
      rect.height,
    )
    event.preventDefault()
    event.stopPropagation()
    cancelRecapAutoCollapse()
    setRecapPosition(origin)
    recapDragRef.current = {
      pointerId: event.pointerId,
      startClientX: event.clientX,
      startClientY: event.clientY,
      originX: origin.x,
      originY: origin.y,
      width: rect.width,
      height: rect.height,
    }
    event.currentTarget.setPointerCapture?.(event.pointerId)
  }

  const handleRecapDragPointerMove = (event: ReactPointerEvent<HTMLButtonElement>) => {
    const drag = recapDragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return
    event.preventDefault()
    const next = clampRecapPosition(
      drag.originX + event.clientX - drag.startClientX,
      drag.originY + event.clientY - drag.startClientY,
      drag.width,
      drag.height,
    )
    setRecapPosition(next)
  }

  const finishRecapDrag = (event: ReactPointerEvent<HTMLButtonElement>) => {
    const drag = recapDragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return
    event.preventDefault()
    event.stopPropagation()
    const next = clampRecapPosition(
      drag.originX + event.clientX - drag.startClientX,
      drag.originY + event.clientY - drag.startClientY,
      drag.width,
      drag.height,
    )
    recapDragRef.current = null
    setRecapPosition(next)
    if (activeCanvas) saveCanvasRecapPosition(activeCanvas.id, next)
    event.currentTarget.releasePointerCapture?.(event.pointerId)
  }

  useEffect(() => {
    return () => {
      cancelRecapAutoCollapse()
      cancelHoverHide()
    }
  }, [])

  useEffect(() => {
    if (!activeCanvas || !recapPosition) return undefined
    const onResize = () => {
      const node = recapContextRef.current
      if (!node) return
      const rect = node.getBoundingClientRect()
      const next = clampRecapPosition(recapPosition.x, recapPosition.y, rect.width, rect.height)
      if (next.x === recapPosition.x && next.y === recapPosition.y) return
      setRecapPosition(next)
      saveCanvasRecapPosition(activeCanvas.id, next)
    }
    window.addEventListener('resize', onResize)
    return () => window.removeEventListener('resize', onResize)
  }, [activeCanvas, recapPosition])

  useEffect(() => {
    plannerStateRef.current = plannerState
  }, [plannerState])

  useEffect(() => {
    if (!recapExpanded) return undefined
    const onPointerDown = (event: PointerEvent) => {
      const node = recapContextRef.current
      if (node && event.target instanceof Node && node.contains(event.target)) return
      setRecapExpanded(false)
      cancelRecapAutoCollapse()
    }
    const onFocusIn = (event: FocusEvent) => {
      const node = recapContextRef.current
      if (node && event.target instanceof Node && node.contains(event.target)) return
      setRecapExpanded(false)
      cancelRecapAutoCollapse()
    }
    document.addEventListener('pointerdown', onPointerDown, true)
    document.addEventListener('focusin', onFocusIn, true)
    return () => {
      document.removeEventListener('pointerdown', onPointerDown, true)
      document.removeEventListener('focusin', onFocusIn, true)
    }
  }, [recapExpanded])

  useEffect(() => {
    canvasMonitorRef.current = canvasMonitor
  }, [canvasMonitor])

  // 2026-06-02 · 上报 toolbar 实际底部(随 recap 折叠/展开变高)到 CSS 变量,
  // 让悬浮的 session overlay 顶部跟随,始终落在 recap 下方、不重叠。
  useEffect(() => {
    const el = rootRef.current
    if (!el) return undefined
    const update = () => {
      const bottom = Math.round(el.getBoundingClientRect().bottom)
      document.documentElement.style.setProperty('--canvas-toolbar-bottom', `${bottom}px`)
    }
    update()
    const observer = new ResizeObserver(update)
    observer.observe(el)
    window.addEventListener('resize', update)
    return () => {
      observer.disconnect()
      window.removeEventListener('resize', update)
      document.documentElement.style.removeProperty('--canvas-toolbar-bottom')
    }
  }, [])

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
    const canvasId = activeCanvas.id
    // Hard guard: never run two recaps for the same canvas concurrently.
    if (recapInFlightRef.current.has(canvasId)) return
    recapInFlightRef.current.add(canvasId)
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
        recapAutoAttemptedRef.current.add(activeCanvas.id)
        recapCacheRef.current[activeCanvas.id] = nextRecap
        setRecap(nextRecap)
        return
      }
      // Chunk E (Privacy UI): when cloud calls are disabled, skip the AI
      // overlay entirely and persist the local-only baseRecap.
      if (!loadAllowCloud()) {
        const nextRecap = { ...baseRecap, updatedAt: new Date().toISOString() }
        recapAutoAttemptedRef.current.add(activeCanvas.id)
        recapCacheRef.current[activeCanvas.id] = nextRecap
        setRecap(nextRecap)
        return
      }
      const aiRecap = await generateAIRecap(state, activeCanvas, canvasMonitorRef.current)
      if (recapRequestRef.current !== requestId) return
      const nextRecap = { ...baseRecap, ...aiRecap, updatedAt: new Date().toISOString() }
      recapAutoAttemptedRef.current.add(activeCanvas.id)
      recapCacheRef.current[activeCanvas.id] = nextRecap
      setRecap(nextRecap)
    } catch (err) {
      if (recapRequestRef.current !== requestId) return
      setRecapError((err as Error).message || 'Recap unavailable')
      setRecap(buildEmptyCanvasRecap(t, t('canvas.recapUnavailable')))
    } finally {
      // Always release the per-canvas in-flight slot, even when this request was
      // superseded (requestId mismatch) — otherwise the slot leaks and the
      // canvas can never auto-recap again.
      recapInFlightRef.current.delete(canvasId)
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
    setRecapExpanded(false)
    const cached = recapCacheRef.current[activeCanvas.id]
    if (cached) {
      setRecap(cached)
      return
    }
    setRecap(buildEmptyCanvasRecap(t))
  }, [activeCanvas?.id, t])

  useEffect(() => {
    if (!activeCanvas) return
    if (plannerState?.canvas.id !== activeCanvas.id) return
    if (recapCacheRef.current[activeCanvas.id]) return
    const localRecap = isBlankPlannerCanvas(plannerState)
      ? buildBlankCanvasRecap(plannerState, t)
      : buildLocalCanvasStatusRecap(plannerState, t)
    setRecap(localRecap)
    if (isBlankPlannerCanvas(plannerState)) {
      recapAutoAttemptedRef.current.add(activeCanvas.id)
      recapCacheRef.current[activeCanvas.id] = localRecap
      return
    }
    if (recapAutoAttemptedRef.current.has(activeCanvas.id)) return
    recapAutoAttemptedRef.current.add(activeCanvas.id)
    void refreshRecap()
  }, [activeCanvas?.id, plannerState, refreshRecap, t])

  useEffect(() => {
    if (!userProfile?.connected) {
      setOwnerDirectory({})
      return
    }
    let cancelled = false
    fetchTeamMembers()
      .then(({ members }) => {
        if (cancelled) return
        setOwnerDirectory(buildOwnerDirectory(members, userProfile))
      })
      .catch(() => {
        if (!cancelled) setOwnerDirectory(buildOwnerDirectory([], userProfile))
      })
    return () => {
      cancelled = true
    }
  }, [userProfile?.connected, userProfile?.teams, userProfile?.userId])

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

  const submitSharing = (visibility: 'private' | 'public') => {
    if (!activeCanvas || !onSetCanvasVisibility) return
    if (canvasVisibilitySaving || visibilityTone(activeCanvas) === visibility) return
    setCanvasVisibilitySaving(true)
    Promise.resolve(onSetCanvasVisibility(activeCanvas.id, visibility))
      .finally(() => setCanvasVisibilitySaving(false))
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
    if (!activeCanvas || activeCanvas.kind === 'monitor') return
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

  const resolveConflict = (canvas: CanvasInfo, choice: 'current' | 'remote') => {
    if (!onResolveCanvasConflict || resolvingConflictCanvasId) return
    setResolvingConflictCanvasId(canvas.id)
    setConflictResolveError(null)
    Promise.resolve(onResolveCanvasConflict(canvas.id, choice))
      .then(() => {
        setHoveredCanvasId(null)
        setHoverAnchor(null)
        if (choice === 'remote' && activeCanvas?.id === canvas.id) void refreshRecap()
      })
      .catch((err) => {
        setConflictResolveError((err as Error).message || 'Failed to resolve sync conflict')
      })
      .finally(() => {
        setResolvingConflictCanvasId(null)
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
  const recapHeadline = recapLoading ? t('canvas.refreshingRecap') : (recap?.headline ?? t('canvas.readingState'))
  const recapSummary = recap?.summary?.trim() || ''
  const recapDetails = recap?.details ?? []
  const canExpandRecap = recapSummary.length > 0 || recapDetails.length > 0
  const isSceneCanvas = Boolean(plannerState?.canvas.id === activeCanvas.id && hasScenePresentation(plannerState))
  const renderProfileStatus = plannerState?.canvas.id === activeCanvas.id ? plannerState.renderProfileStatus : null
  const renderProfileHasError = renderProfileStatus?.state === 'invalid-using-last-valid'
  const canClearCanvas = Boolean(onClearCanvas && activeCanvas.kind !== 'monitor')
  const canSaveActiveCanvasAsTemplate = Boolean(
    onSaveCanvasAsTemplate && activeCanvas.kind !== 'monitor',
  )
  const recapContextStyle: CSSProperties | undefined = recapPosition
    ? { position: 'fixed', left: recapPosition.x, top: recapPosition.y }
    : undefined

  const revealRenderProfile = () => {
    revealCanvasRenderProfile(activeCanvas.id)
      .catch((error) => {
        setInfoError((error as Error).message || 'Failed to reveal render profile')
      })
  }

  return (
    <div
      className={[
        'canvas-toolbar',
        isMonitorCanvas ? 'canvas-toolbar--monitor' : '',
        isSceneCanvas ? 'canvas-toolbar--scene' : '',
      ].filter(Boolean).join(' ')}
      ref={rootRef}
    >
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
        {onTogglePlannerDialog && (
          <button
            type="button"
            className="canvas-toolbar__nav canvas-toolbar__ai-panel-toggle"
            aria-label={plannerDialogCollapsed ? 'Open meee2 AI dialog' : 'Collapse meee2 AI dialog'}
            title={plannerDialogCollapsed ? 'Open meee2 AI dialog' : 'Collapse meee2 AI dialog'}
            onClick={onTogglePlannerDialog}
          >
            {plannerDialogCollapsed ? <PanelLeftOpen size={14} aria-hidden /> : <PanelLeftClose size={14} aria-hidden />}
          </button>
        )}
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
            setInfoError(null)
            setInfoTab('overview')
            setInfoOpen(true)
          }}
        >
          <Info size={14} aria-hidden />
        </button>
        {renderProfileHasError && (
          <button
            type="button"
            className="canvas-toolbar__info"
            aria-label="Render profile has an error"
            title={renderProfileStatus?.error || 'Render profile has an error'}
            onClick={revealRenderProfile}
          >
            <AlertTriangle size={14} aria-hidden />
          </button>
        )}

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
            {showCanvasTabs && (
              <div className="canvas-toolbar__tabs" role="tablist" aria-label="Canvas groups">
                {canvasEntryGroups.map((group) => (
                  <button
                    key={group.id}
                    type="button"
                    role="tab"
                    className={canvasListTab === group.id ? 'is-active' : ''}
                    aria-selected={canvasListTab === group.id}
                    onClick={() => {
                      setCanvasListTab(group.id)
                    }}
                  >
                    <span>{group.id === 'my' ? 'My' : 'Team'}</span>
                    <small>{group.entries.length}</small>
                  </button>
                ))}
              </div>
            )}
            <div className="canvas-toolbar__list">
              {selectedCanvasGroup ? (
                <div className="canvas-toolbar__group" key={selectedCanvasGroup.id}>
                  {selectedCanvasGroup.entries.map(({ canvas, depth }) => {
                    const selected = canvas.id === activeCanvas.id
                    const avatarUrl = ownerAvatarUrl(canvas, userProfile, ownerDirectory)
                    const showOwnerAvatar = selectedCanvasGroup.id === 'team' && canvas.scope === 'team'
                    const showMinePill = selectedCanvasGroup.id === 'team' && ownsCanvas(canvas, userProfile?.userId ?? '')
                    const statusTone = canvasStatusTone(canvas, userProfile?.userId ?? '')
                    const statusLabel = canvasStatusLabel(canvas, userProfile?.userId ?? '')
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
                          showCanvasHover(canvas.id, rect)
                        }}
                        onMouseLeave={hideCanvasHoverSoon}
                      >
                        <span className="canvas-toolbar__check">
                          {selected && <Check size={13} aria-hidden />}
                        </span>
                        <span className="canvas-toolbar__item-main">
                          <span className="canvas-toolbar__item-title-row">
                            <span
                              className={`canvas-toolbar__status-dot canvas-toolbar__status-dot--${statusTone}`}
                              title={statusLabel}
                              aria-label={statusLabel}
                            />
                            <span className="canvas-toolbar__item-title">{displayCanvasName(canvas)}</span>
                          </span>
                          <span className="canvas-toolbar__item-subtitle">
                            {canvasListSubtitle(canvas, selectedCanvasGroup.id, userProfile?.userId ?? '', ownerDirectory)}
                          </span>
                        </span>
                        <span className="canvas-toolbar__item-side">
                          {canvas.isDefault && (
                            <span className="canvas-toolbar__default-badge" title={t('canvas.cannotDelete')} aria-label="Default">
                              Default
                            </span>
                          )}
                          {showMinePill && (
                            <span className="canvas-toolbar__mine-pill">Mine</span>
                          )}
                          {showOwnerAvatar && (
                            <span
                              className={`canvas-toolbar__owner-avatar ${avatarUrl ? 'has-image' : ''}`}
                              style={avatarUrl ? { backgroundImage: `url(${avatarUrl})` } : undefined}
                              title={ownerLabel(canvas, userProfile?.userId ?? '', ownerDirectory)}
                              aria-label={ownerLabel(canvas, userProfile?.userId ?? '', ownerDirectory)}
                            >
                              {avatarUrl ? null : ownerInitials(canvas, userProfile?.userId ?? '', ownerDirectory)}
                            </span>
                          )}
                        </span>
                      </button>
                    )
                  })}
                </div>
              ) : null}
              {(!selectedCanvasGroup || selectedCanvasGroup.entries.length === 0) && (
                <div className="canvas-toolbar__empty">
                  {selectedCanvasGroup?.id === 'team' && canvasQuery.trim().length === 0
                    ? t('canvas.noTeamCanvas')
                    : t('canvas.noMatch')}
                </div>
              )}
            </div>
          </div>
        )}
      </div>
      <div
        className={`canvas-toolbar__context${recapPosition ? ' is-positioned' : ''}`}
        ref={recapContextRef}
        style={recapContextStyle}
        aria-live="polite"
        onMouseEnter={handleRecapMouseEnter}
        onMouseLeave={handleRecapMouseLeave}
      >
        <div className="canvas-toolbar__recap">
          <button
            type="button"
            className="canvas-toolbar__recap-drag"
            aria-label="Move AI recap"
            title="Move AI recap"
            onPointerDown={handleRecapDragPointerDown}
            onPointerMove={handleRecapDragPointerMove}
            onPointerUp={finishRecapDrag}
            onPointerCancel={finishRecapDrag}
          />
          <button
            type="button"
            className="canvas-toolbar__recap-trigger"
            title={recapHeadline}
            aria-expanded={canExpandRecap ? recapExpanded : undefined}
            onClick={() => {
              if (!canExpandRecap) return
              const nextExpanded = !recapExpanded
              setRecapExpanded(nextExpanded)
              if (nextExpanded && !recapHoveringRef.current) {
                scheduleRecapAutoCollapse(true)
              } else if (!nextExpanded) {
                cancelRecapAutoCollapse()
              }
            }}
            disabled={!canExpandRecap}
          >
            <span className="canvas-toolbar__recap-copy">
              <span className="canvas-toolbar__recap-headline-row">
                <strong>{recapHeadline}</strong>
              </span>
              {recapSummary ? (
                <span className="canvas-toolbar__recap-summary">{recapSummary}</span>
              ) : null}
              <span className="canvas-toolbar__recap-meta">
                <span className={`canvas-toolbar__monitor-badge is-${monitorBadge.tone}`}>
                  {monitorBadge.label}
                </span>
                {recapError ? (
                  <small>{recapError}</small>
                ) : recap?.updatedAt ? (
                  <small className="canvas-toolbar__recap-age">{formatRecapAge(recap.updatedAt, recapAgeNow)}</small>
                ) : null}
              </span>
            </span>
            {canExpandRecap ? (
              <span className="canvas-toolbar__recap-chevron" aria-hidden>
                {recapExpanded ? <ChevronUp size={15} /> : <ChevronDown size={15} />}
              </span>
            ) : null}
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
        {recapExpanded && recapDetails.length > 0 && (
          <div className="canvas-toolbar__recap-details">
            {recapDetails.map((line) => (
              <p key={line}>{line}</p>
            ))}
          </div>
        )}
      </div>
      {recapExpanded && !isMonitorCanvas && recap?.mode !== 'empty' && recap?.statuses && (
        <div className="canvas-toolbar__status-strip" aria-label={t('canvas.statusOverview')}>
          {recap.statuses.map((item) => (
            <span key={item.label} className={`canvas-toolbar__status-pill is-${item.tone}`}>
              <strong>{item.value}</strong>
              <small>{item.label}</small>
            </span>
          ))}
          {/* UI-simplification §1 — session 是隐藏词,对外口径统一叫「进展」。
           *  这里把 boardState.sessions 里 status 异常 / 等待权限的条目转译成
           *  「需关注的进展」pill,点击直接在当前 canvas 弹出 session terminal overlay:
           *  - 1 条:直接 dispatch meee2:open-session(带 active canvas)
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
                detail: { sessionId, canvasId: activeCanvas.id },
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

      {/* UI-simplification — hover canvas item in dropdown → semantic recap popover */}
      {hoveredCanvasId && hoverAnchor && (() => {
        const hovered = canvases.find((c) => c.id === hoveredCanvasId)
        if (!hovered) return null
        const userId = userProfile?.userId ?? ''
        const ownerCanResolveConflict = isCanvasConflict(hovered) && ownsCanvas(hovered, userId) && Boolean(onResolveCanvasConflict)
        const resolvingConflict = resolvingConflictCanvasId === hovered.id
        return (
          <div
            className="canvas-toolbar__hover-recap"
            style={{
              position: 'fixed',
              top: hoverAnchor.top,
              left: hoverAnchor.right + 8,
            }}
            onMouseEnter={() => {
              cancelHoverHide()
              setHoveredCanvasId(hoveredCanvasId)
              setHoverAnchor(hoverAnchor)
            }}
            onMouseLeave={hideCanvasHoverSoon}
          >
            <div className="canvas-toolbar__hover-recap-title">{displayCanvasName(hovered)}</div>
            <dl className="canvas-toolbar__hover-meta">
              <div>
                <dt>Owner</dt>
                <dd>{canvasOwnerDisplay(hovered, userProfile?.userId ?? '', ownerDirectory)}</dd>
              </div>
              <div>
                <dt>Access</dt>
                <dd>{canvasAccessLabel(hovered, userId)}</dd>
              </div>
              <div>
                <dt>Sync</dt>
                <dd>{canvasStatusLabel(hovered, userId)}</dd>
              </div>
              {isCanvasConflict(hovered) && ownsCanvas(hovered, userId) && (
                <div>
                  <dt>Versions</dt>
                  <dd>{canvasConflictVersionLabel(hovered)}</dd>
                </div>
              )}
              <div>
                <dt>Updated</dt>
                <dd>{canvasUpdatedLabel(hovered)}</dd>
              </div>
            </dl>
            {ownerCanResolveConflict && (
              <div className="canvas-toolbar__conflict-panel">
                <div className="canvas-toolbar__conflict-copy">
                  <AlertTriangle size={14} aria-hidden />
                  <span>
                    <strong>Sync conflict</strong>
                    <small>{canvasConflictDetail(hovered)}</small>
                  </span>
                </div>
                <div className="canvas-toolbar__conflict-actions">
                  <button
                    type="button"
                    className="ghost"
                    disabled={resolvingConflict}
                    onClick={() => resolveConflict(hovered, 'remote')}
                  >
                    Use team version
                  </button>
                  <button
                    type="button"
                    className="primary"
                    disabled={resolvingConflict}
                    onClick={() => resolveConflict(hovered, 'current')}
                  >
                    Keep local
                  </button>
                </div>
                {conflictResolveError && resolvingConflictCanvasId === null && (
                  <div className="canvas-toolbar__conflict-error">{conflictResolveError}</div>
                )}
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
              {infoError && <div className="templates-error">{infoError}</div>}
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
                  {renderProfileStatus && (
                    <>
                      <div className="canvas-info-modal__row">
                        <span>Render profile</span>
                        <strong>{renderProfileStatus.state}</strong>
                      </div>
                      <div className="canvas-info-modal__row">
                        <span>Profile file</span>
                        <button type="button" className="ghost canvas-info-modal__inline-action" onClick={revealRenderProfile}>Reveal</button>
                      </div>
                      {renderProfileStatus.error && (
                        <div className="canvas-info-modal__row">
                          <span>Error</span>
                          <strong>{renderProfileStatus.error}</strong>
                        </div>
                      )}
                    </>
                  )}
                  <div className="canvas-info-modal__row">
                    <span>{t('canvas.visibility')}</span>
                    <strong>{visibilityLabel(activeCanvas, t)}</strong>
                  </div>
                  {activeCanvas.scope === 'team' && (
                    <div className="canvas-info-modal__row">
                      <span>{t('canvas.owner')}</span>
                      <strong className="is-mono">{ownerLabel(activeCanvas, userProfile?.userId ?? '', ownerDirectory)}</strong>
                    </div>
                  )}
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
                  {canManageTeamSharing && (
                    <div className="canvas-info-modal__visibility">
                      <UserRound size={15} aria-hidden />
                      <div>
                        <strong>{t('canvas.teamSharing')}</strong>
                        <p>{t('canvas.teamSharingHelp')}</p>
                      </div>
                      <div className="canvas-info-modal__visibility-actions">
                        {activeCanvas.scope !== 'team' && (
                          <button
                            type="button"
                            className="primary"
                            onClick={() => submitSharing('public')}
                            disabled={canvasVisibilitySaving}
                          >
                            <Share2 size={13} aria-hidden />
                            {canvasVisibilitySaving ? t('canvas.visibilitySaving') : t('canvas.publishToTeam')}
                          </button>
                        )}
                        {activeCanvas.scope === 'team' && (
                          <button
                            type="button"
                            className="ghost"
                            onClick={() => submitSharing('private')}
                            disabled={canvasVisibilitySaving}
                          >
                            <LockKeyhole size={13} aria-hidden />
                            {t('canvas.removeFromTeam')}
                          </button>
                        )}
                      </div>
                    </div>
                  )}
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
                 *  scope 默认 personal,发布到 Team 走 Canvas Info modal。Kind selector 同样隐藏。 */}
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
  return isTeamReadable(canvas) ? 'public' : 'private'
}

function visibilityLabel(canvas: CanvasInfo, t: ReturnType<typeof useI18n>['t']): string {
  return isTeamReadable(canvas) ? t('canvas.teamCanvas') : t('canvas.ownCanvas')
}

function isTeamReadable(canvas: CanvasInfo): boolean {
  return canvas.scope === 'team'
}

function ownsCanvas(canvas: CanvasInfo, userId: string): boolean {
  if (!userId) return false
  return (canvas.ownerUserId ?? '') === userId
}

function ownerInitials(
  canvas: CanvasInfo,
  userId: string,
  ownerDirectory: Record<string, OwnerIdentity>,
): string {
  const ownerId = (canvas.ownerUserId ?? '').trim()
  if (ownerId && ownerId === userId) return 'ME'
  const displayName = ownerId ? ownerDirectory[ownerId]?.displayName : ''
  if (displayName) return initialsFor(displayName)
  if (!ownerId) return '??'
  const [first, second] = ownerId.replace(/[^a-zA-Z0-9]/g, '').toUpperCase()
  return `${first ?? '?'}${second ?? ''}`.padEnd(2, '?')
}

function ownerLabel(
  canvas: CanvasInfo,
  userId: string,
  ownerDirectory: Record<string, OwnerIdentity>,
): string {
  const ownerId = (canvas.ownerUserId ?? '').trim()
  if (!ownerId) return 'Owner unknown'
  const displayName = ownerDirectory[ownerId]?.displayName
  if (ownerId === userId) return displayName ? `Owner: you (${displayName})` : 'Owner: you'
  return `Owner: ${displayName || ownerId}`
}

function canvasOwnerDisplay(
  canvas: CanvasInfo,
  userId: string,
  ownerDirectory: Record<string, OwnerIdentity>,
): string {
  const ownerId = (canvas.ownerUserId ?? '').trim()
  if (!ownerId) return 'Unknown'
  if (ownerId === userId) return 'You'
  return ownerDirectory[ownerId]?.displayName || ownerId
}

function ownerAvatarUrl(
  canvas: CanvasInfo,
  userProfile: UserProfile | null,
  ownerDirectory: Record<string, OwnerIdentity>,
): string | null {
  const ownerId = (canvas.ownerUserId ?? '').trim()
  if (!ownerId) return null
  if (userProfile?.userId === ownerId) return userProfile.userAvatarUrl || ownerDirectory[ownerId]?.avatarUrl || null
  return ownerDirectory[ownerId]?.avatarUrl || null
}

function buildOwnerDirectory(members: TeamMember[], userProfile: UserProfile | null): Record<string, OwnerIdentity> {
  const directory: Record<string, OwnerIdentity> = {}
  for (const member of members) {
    if (!member.userId) continue
    directory[member.userId] = {
      displayName: member.displayName || member.email || member.userId,
      avatarUrl: member.avatarUrl || null,
    }
  }
  if (userProfile?.userId) {
    directory[userProfile.userId] = {
      displayName: userProfile.displayName || userProfile.userName || userProfile.userEmail || userProfile.userId,
      avatarUrl: userProfile.userAvatarUrl || directory[userProfile.userId]?.avatarUrl || null,
    }
  }
  return directory
}

function initialsFor(value: string): string {
  const parts = value.trim().split(/\s+/).filter(Boolean)
  if (parts.length >= 2) return `${parts[0][0] ?? ''}${parts[1][0] ?? ''}`.toUpperCase()
  return value.replace(/[^a-zA-Z0-9]/g, '').slice(0, 2).toUpperCase().padEnd(2, '?')
}

function isCanvasConflict(canvas: CanvasInfo): boolean {
  const syncStatus = (canvas.syncStatus ?? '').toLowerCase()
  return syncStatus.includes('conflict')
}

function canvasStatusTone(canvas: CanvasInfo, userId = ''): 'local' | 'synced' | 'pending' | 'error' {
  const syncStatus = (canvas.syncStatus ?? '').toLowerCase()
  if (isCanvasConflict(canvas) && canvas.scope === 'team' && !ownsCanvas(canvas, userId)) return 'pending'
  if (syncStatus.includes('conflict') || syncStatus.includes('fail') || syncStatus.includes('error')) return 'error'
  if (canvas.scope !== 'team') return 'local'
  if (
    canvas.dirtySince ||
    syncStatus.includes('pending') ||
    syncStatus.includes('syncing') ||
    syncStatus.includes('refreshing') ||
    syncStatus.includes('force')
  ) return 'pending'
  return 'synced'
}

function canvasStatusLabel(canvas: CanvasInfo, userId = ''): string {
  const syncStatus = (canvas.syncStatus ?? '').toLowerCase()
  if (isCanvasConflict(canvas)) {
    return canvas.scope === 'team' && !ownsCanvas(canvas, userId)
      ? 'Refreshing read-only copy'
      : 'Sync conflict'
  }
  if (syncStatus.includes('syncing')) return 'Syncing to team'
  if (syncStatus.includes('refreshing')) return 'Refreshing read-only copy'
  switch (canvasStatusTone(canvas)) {
    case 'error':
      return 'Sync error'
    case 'pending':
      return 'Sync pending'
    case 'synced':
      return 'Synced to team'
    case 'local':
    default:
      return 'Local only'
  }
}

function canvasConflictVersionLabel(canvas: CanvasInfo): string {
  const localVersion = canvas.remoteVersion ?? 0
  const remoteVersion = canvas.conflictRemoteVersion ?? null
  if (remoteVersion === null) return `local v${localVersion}`
  return `local v${localVersion} / team v${remoteVersion}`
}

function canvasConflictDetail(canvas: CanvasInfo): string {
  if (canvas.conflictRemoteDeleted) {
    return 'The team version was deleted while this local copy still has changes.'
  }
  const localVersion = canvas.remoteVersion ?? 0
  const remoteVersion = canvas.conflictRemoteVersion ?? null
  if (remoteVersion !== null) {
    return `Local changes were made from v${localVersion}, but Team is already v${remoteVersion}.`
  }
  return 'Local changes and the team version both moved forward.'
}

function canvasUpdatedLabel(canvas: CanvasInfo): string {
  const timestamp = canvas.lastRemoteUpdatedAt || canvas.lastSyncedAt || canvas.dirtySince
  if (!timestamp) return canvas.scope === 'team' ? 'No sync timestamp' : 'Local'
  return formatRecapAge(timestamp, Date.now())
}

function canvasAccessLabel(canvas: CanvasInfo, userId: string): string {
  if (canvas.scope !== 'team') return 'Editable'
  return ownsCanvas(canvas, userId) ? 'Editable' : 'View only'
}

function canvasListSubtitle(
  canvas: CanvasInfo,
  groupId: CanvasListTab,
  userId: string,
  ownerDirectory: Record<string, OwnerIdentity>,
): string {
  if (groupId === 'my') return canvas.parentCanvasId ? 'Local subcanvas' : 'Local canvas'
  const owner = canvasOwnerDisplay(canvas, userId, ownerDirectory)
  if (canvas.parentCanvasId && ownsCanvas(canvas, userId)) return 'Assigned to you'
  if (ownsCanvas(canvas, userId)) return 'Owned by you'
  return owner
}

function groupCanvasEntries(
  entries: Array<{ canvas: CanvasInfo; depth: number }>,
  options: { includeEmptyGroups?: boolean } = {},
): Array<{ id: CanvasListTab; label: string; entries: Array<{ canvas: CanvasInfo; depth: number }> }> {
  const myEntries: Array<{ canvas: CanvasInfo; depth: number }> = []
  const teamEntries: Array<{ canvas: CanvasInfo; depth: number }> = []
  for (const entry of entries) {
    if (entry.canvas.scope === 'team') {
      teamEntries.push(entry)
    } else {
      myEntries.push(entry)
    }
  }
  return [
    { id: 'my' as const, label: 'My Canvases', entries: myEntries },
    { id: 'team' as const, label: 'Team Canvases', entries: teamEntries },
  ].filter((group) => options.includeEmptyGroups || group.entries.length > 0)
}

function displayCanvasName(canvas: CanvasInfo): string {
  return canvas.name === 'Default canvas' ? 'Monitor' : canvas.name
}

function canvasTypeLabel(canvas: CanvasInfo, t: ReturnType<typeof useI18n>['t']): string {
  if (canvas.kind === 'monitor') return t('canvas.type.monitor')
  return t('canvas.type.board')
}

function templateKindForCanvas(canvas: CanvasInfo): TemplateMetadataInput['defaultCanvasKind'] {
  return canvas.kind === 'monitor' ? 'monitor' : 'board'
}

function hasScenePresentation(state: PlannerGraphState | null | undefined): boolean {
  if (!state) return false
  if (state.canvas.sceneSpec) return true
  return state.renderProfile?.logic.layout === 'spatial'
    && (state.renderObjects ?? []).some((object) => object.renderOnly?.kind === 'background')
}

function clampRecapPosition(x: number, y: number, width: number, height: number): { x: number; y: number } {
  const margin = 12
  const safeX = Number.isFinite(x) ? x : margin
  const safeY = Number.isFinite(y) ? y : margin
  const safeWidth = Number.isFinite(width) && width > 0 ? width : 240
  const safeHeight = Number.isFinite(height) && height > 0 ? height : 64
  const maxX = Math.max(margin, window.innerWidth - Math.max(safeWidth, 240) - margin)
  const maxY = Math.max(margin, window.innerHeight - Math.max(safeHeight, 64) - margin)
  return {
    x: Math.round(Math.min(Math.max(safeX, margin), maxX)),
    y: Math.round(Math.min(Math.max(safeY, margin), maxY)),
  }
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

function buildLocalCanvasStatusRecap(state: PlannerGraphState, t: ReturnType<typeof useI18n>['t']): CanvasRecap {
  return {
    ...buildCanvasStatusRecap(state, t),
    headline: t('canvas.statusOverview'),
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
): Promise<Pick<CanvasRecap, 'headline' | 'summary' | 'details'>> {
  // Chunk E (Privacy UI): when the user has flipped off "allow cloud / model
  // calls", short-circuit before any LLM fetch. The caller already computed a
  // local `baseRecap` (from `buildCanvasStatusRecap`), so returning an empty
  // overlay just leaves that local-only recap in place.
  if (!loadAllowCloud()) {
    return {
      headline: '',
      summary: '',
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
      localRunPurpose: 'recap',
    },
  })) {
    if (ev.type === 'delta') text += ev.text
    if (ev.type === 'error') throw new Error(ev.message)
  }
  return parseAIRecap(text)
}

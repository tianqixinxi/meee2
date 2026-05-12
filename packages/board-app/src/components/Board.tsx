import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { PointerEvent as ReactPointerEvent } from 'react'
import { createPortal } from 'react-dom'
import {
  Excalidraw,
  MainMenu,
  convertToExcalidrawElements,
} from '@excalidraw/excalidraw'
import type {
  ExcalidrawImperativeAPI,
  AppState,
} from '@excalidraw/excalidraw/types'
import type { ExcalidrawElement } from '@excalidraw/excalidraw/element/types'

import type {
  BoardState,
  CanvasPatchOperation,
  CanvasPatchRequest,
  CanvasRelationStylePreset,
  CoordinationGroup,
  SelectedCanvasElementContext,
  Selection,
  Session,
} from '../types'
import {
  buildChannelHub,
  buildScene,
  buildSessionEmbeddable,
  channelHubId,
  panToChannelHub,
  modeStrokeColor,
  modeStrokeStyle,
  RECT_W,
  RECT_H,
  CHANNEL_FRAME_W,
  CHANNEL_FRAME_H,
  isManagedElementId,
  parseChannelFromElement,
  parseSessionLink,
  parseSessionFromElement,
  resolveChannelFromElementId,
  sessionRectId,
  debounce,
  ensurePositions,
  ensureChannelPositions,
  dmChannelName,
  isDmChannelName,
  DM_LINE_STROKE_COLOR,
  DM_LINE_STROKE_WIDTH_BASE,
  DM_LINE_STROKE_WIDTH_PENDING,
  type LayoutMap,
  type CanvasPersistence,
} from '@meee1/board-core'
import {
  activateSession,
  addSessionToCanvas,
  addMember,
  createChannel,
  deleteChannel,
  askCoordinator,
  pauseCoordination,
  removeCoordinationMember,
  removeSessionFromCanvas,
  removeMember,
  resumeCoordination,
  syncCoordinationGroup,
} from '../api'
import { SessionOverlay } from './SessionOverlay'
import { Tooltip } from './Tooltip'

/**
 * Derive a deterministic channel alias from a session's title + id so each
 * session gets a unique, stable alias when a user draws an arrow from the
 * session to a channel hub. Alias rules (backend): `[a-z0-9_-]{1,64}`.
 * Shape: `<kebab-title><-6char-shortid>` so two sessions with identical
 * titles still collide-free.
 */
function aliasFromSession(title: string, sid: string): string {
  const short = sid.replace(/-/g, '').slice(0, 6)
  const base = (title || 'session')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 30)
  return base ? `${base}-${short}` : `session-${short}`
}

function selectedElementTextPreview(el: ExcalidrawElement): string | undefined {
  const text = typeof (el as any).text === 'string'
    ? (el as any).text.trim()
    : ''
  if (!text) return undefined
  return text.length <= 120 ? text : `${text.slice(0, 119)}...`
}

function labelForSelectedElement(
  el: ExcalidrawElement,
  state: BoardState,
  sessionId?: string,
  channelName?: string,
  textPreview?: string,
): string {
  if (sessionId) {
    const session = state.sessions.find((s) => s.id === sessionId)
    return `Session: ${session?.title || sessionId.slice(0, 8)}`
  }
  if (channelName) {
    const channel = state.channels.find((ch) => ch.name === channelName)
    return `Channel: ${channel?.displayName || channelName}`
  }
  if (el.type === 'text' && textPreview) return `Text: ${textPreview}`
  return el.type.charAt(0).toUpperCase() + el.type.slice(1)
}

function selectedElementsContext(
  elements: readonly ExcalidrawElement[],
  selectedIds: string[],
  state: BoardState,
): SelectedCanvasElementContext[] {
  if (selectedIds.length === 0) return []
  const selectedIdSet = new Set(selectedIds)
  return elements
    .filter((el) => selectedIdSet.has(el.id) && !(el as any).isDeleted)
    .slice(0, 12)
    .map((el) => {
      const sessionId = el.type === 'rectangle' ? parseSessionFromElement(el) ?? undefined : undefined
      const channelName =
        el.type === 'ellipse'
          ? parseChannelFromElement(el) ?? undefined
          : el.id.startsWith('channel-')
          ? resolveChannelFromElementId(el.id, state.channels)?.name ?? undefined
          : undefined
      const textPreview = selectedElementTextPreview(el)
      return {
        id: el.id,
        type: el.type,
        label: labelForSelectedElement(el, state, sessionId, channelName, textPreview),
        textPreview,
        sessionId,
        channelName,
        x: Math.round(el.x ?? 0),
        y: Math.round(el.y ?? 0),
        width: Math.round(el.width ?? 0),
        height: Math.round(el.height ?? 0),
      }
    })
}

// Inline feather-style icons used by MainMenu / Footer. 16px, stroke=1.75.
function RefreshIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
      <path d="M21 12a9 9 0 1 1-3-6.7" />
      <polyline points="21 3 21 9 15 9" />
    </svg>
  )
}
function TerminalIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="4 17 10 11 4 5" />
      <line x1="12" y1="19" x2="20" y2="19" />
    </svg>
  )
}
function PlusSquareIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
      <rect x="3" y="3" width="18" height="18" rx="2" />
      <line x1="12" y1="8" x2="12" y2="16" />
      <line x1="8" y1="12" x2="16" y2="12" />
    </svg>
  )
}
function ExternalLinkIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
      <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
      <polyline points="15 3 21 3 21 9" />
      <line x1="10" y1="14" x2="21" y2="3" />
    </svg>
  )
}
function FitIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="4 14 10 14 10 20" />
      <polyline points="20 10 14 10 14 4" />
      <line x1="14" y1="10" x2="21" y2="3" />
      <line x1="3" y1="21" x2="10" y2="14" />
    </svg>
  )
}
function GridIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
      <rect x="4" y="4" width="16" height="16" rx="2" />
      <path d="M4 10h16M4 16h16M10 4v16M16 4v16" />
    </svg>
  )
}

const SIDEBAR_FOCUS_ZOOM = 1.25
const SESSION_GRID_COLS = 4
const SESSION_GRID_GAP_X = 40
const SESSION_GRID_GAP_Y = 40
const SESSION_GRID_COL_W = RECT_W + SESSION_GRID_GAP_X
const SESSION_GRID_ROW_H = RECT_H + SESSION_GRID_GAP_Y

function CoordinationPanel({
  group,
  selectedSessionId,
  state,
  onRefresh,
}: {
  group: CoordinationGroup
  selectedSessionId: string
  state: BoardState
  onRefresh: () => void
}) {
  const [busy, setBusy] = useState<string | null>(null)
  const selectedIsMember = group.memberSessionIds.includes(selectedSessionId)
  const selectedIsCoordinator = group.coordinatorSessionId === selectedSessionId
  const latestEvent = group.events[group.events.length - 1]
  const blockerCount = Object.values(group.memberDigests).reduce((sum, digest) => sum + digest.blockers.length, 0)
  const members = group.memberSessionIds
    .map((sid) => state.sessions.find((s) => s.id === sid)?.title || sid.slice(0, 8))
    .slice(0, 3)
    .join(', ')

  const run = async (label: string, action: () => Promise<unknown>) => {
    setBusy(label)
    try {
      await action()
      onRefresh()
    } catch (error) {
      console.warn('[Board] coordination action failed', error)
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="coordination-panel">
      <div className="coordination-panel__head">
        <div>
          <div className="coordination-panel__title">Coordination</div>
          <div className="coordination-panel__meta">
            {group.paused ? 'Paused' : 'Hybrid'} · {group.memberSessionIds.length} members
          </div>
        </div>
        {blockerCount > 0 && <span className="coordination-panel__badge">{blockerCount} blocker</span>}
      </div>
      <div className="coordination-panel__goal">{group.goal}</div>
      <div className="coordination-panel__row">Members: {members || 'none'}</div>
      {latestEvent && (
        <div className="coordination-panel__row">Last: {latestEvent.kind} · {latestEvent.reason}</div>
      )}
      {group.lastRoutedAction && (
        <div className="coordination-panel__row">Action: {group.lastRoutedAction}</div>
      )}
      <div className="coordination-panel__actions">
        <button type="button" onClick={() => run('sync', () => syncCoordinationGroup(group.id))} disabled={busy !== null}>
          {busy === 'sync' ? 'Syncing' : 'Sync now'}
        </button>
        <button type="button" onClick={() => run('ask', () => askCoordinator(group.id, 'manual Ask coordinator'))} disabled={busy !== null || !group.coordinatorSessionId}>
          {busy === 'ask' ? 'Asking' : 'Ask coordinator'}
        </button>
        <button
          type="button"
          onClick={() => run('pause', () => group.paused ? resumeCoordination(group.id) : pauseCoordination(group.id))}
          disabled={busy !== null}
        >
          {group.paused ? 'Resume' : 'Pause'}
        </button>
        {selectedIsMember && !selectedIsCoordinator && (
          <button
            type="button"
            className="danger"
            onClick={() => run('remove', () => removeCoordinationMember(group.id, selectedSessionId))}
            disabled={busy !== null}
          >
            Remove member
          </button>
        )}
      </div>
    </div>
  )
}

/** Annotation written into a card-to-card arrow's customData so we can
 *  recognise it as a "DM line" across refreshes -- Excalidraw can briefly
 *  drop bindings on load (user shapes restore before managed rects rebuild),
 *  and without a persisted hint the arrow temporarily looks like a vanilla
 *  shape. */
const DM_ARROW_META_KEY = 'dmArrow'
const RELATION_KIND_KEY = 'meee2Kind'
const RELATION_ELEMENT_KINDS = new Set([
  'relationFrame',
  'relationConnector',
  'relationShape',
  'relationLabel',
])

const RELATION_STYLES: Record<CanvasRelationStylePreset, {
  strokeColor: string
  backgroundColor: string
  strokeStyle: 'solid' | 'dashed' | 'dotted'
  strokeWidth: number
}> = {
  coordination: { strokeColor: '#64748B', backgroundColor: 'transparent', strokeStyle: 'solid', strokeWidth: 2 },
  review: { strokeColor: '#8B5CF6', backgroundColor: 'transparent', strokeStyle: 'dashed', strokeWidth: 2 },
  dependency: { strokeColor: '#F59E0B', backgroundColor: 'transparent', strokeStyle: 'solid', strokeWidth: 2 },
  handoff: { strokeColor: '#06B6D4', backgroundColor: 'transparent', strokeStyle: 'solid', strokeWidth: 2 },
  group: { strokeColor: '#64748B', backgroundColor: 'transparent', strokeStyle: 'dashed', strokeWidth: 2 },
}

function relationStylePreset(raw?: string): CanvasRelationStylePreset {
  return raw === 'coordination' ||
    raw === 'review' ||
    raw === 'dependency' ||
    raw === 'handoff' ||
    raw === 'group'
    ? raw
    : 'group'
}

function relationStyle(raw?: string) {
  return RELATION_STYLES[relationStylePreset(raw)]
}

function relationCustomData(kind: string, extra: Record<string, unknown> = {}) {
  return { [RELATION_KIND_KEY]: kind, ...extra }
}

function isAssistantRelationElement(el: ExcalidrawElement): boolean {
  const kind = (el as any).customData?.[RELATION_KIND_KEY]
  return typeof kind === 'string' && RELATION_ELEMENT_KINDS.has(kind)
}

function appStateFromViewport(
  viewport: { scrollX: number; scrollY: number; zoom: number } | null,
): any {
  return viewport
    ? {
        scrollX: viewport.scrollX,
        scrollY: viewport.scrollY,
        zoom: { value: viewport.zoom },
      }
    : undefined
}

function sortSessionsForCanvas(
  sessions: readonly Session[],
  currentCanvasSessionIds: ReadonlySet<string>,
): Session[] {
  return sessions.filter((s) => currentCanvasSessionIds.has(s.id)).sort((a, b) => {
    const aCurrent = currentCanvasSessionIds.has(a.id)
    const bCurrent = currentCanvasSessionIds.has(b.id)
    if (aCurrent !== bCurrent) return aCurrent ? -1 : 1
    const aTime = Date.parse(a.lastActivity || '')
    const bTime = Date.parse(b.lastActivity || '')
    return (Number.isFinite(bTime) ? bTime : 0) - (Number.isFinite(aTime) ? aTime : 0)
  })
}

function gridPointAt(origin: { x: number; y: number }, index: number): { x: number; y: number } {
  return {
    x: origin.x + (index % SESSION_GRID_COLS) * SESSION_GRID_COL_W,
    y: origin.y + Math.floor(index / SESSION_GRID_COLS) * SESSION_GRID_ROW_H,
  }
}

function sameLayoutMap(a: LayoutMap, b: LayoutMap): boolean {
  const keys = new Set([...Object.keys(a), ...Object.keys(b)])
  for (const key of keys) {
    const left = a[key]
    const right = b[key]
    if (!left || !right) return false
    if (Math.abs((left.x ?? 0) - (right.x ?? 0)) >= 0.5) return false
    if (Math.abs((left.y ?? 0) - (right.y ?? 0)) >= 0.5) return false
    if (Math.abs((left.width ?? 0) - (right.width ?? 0)) >= 0.5) return false
    if (Math.abs((left.height ?? 0) - (right.height ?? 0)) >= 0.5) return false
  }
  return true
}

function layoutMapSignature(map: LayoutMap): string {
  return Object.keys(map).sort().map((key) => {
    const item = map[key]
    if (!item) return `${key}:nil`
    const x = Math.round((item.x ?? 0) * 10)
    const y = Math.round((item.y ?? 0) * 10)
    const w = Math.round((item.width ?? 0) * 10)
    const h = Math.round((item.height ?? 0) * 10)
    return `${key}:${x},${y},${w},${h}`
  }).join('|')
}

function viewportSignature(viewport: { scrollX: number; scrollY: number; zoom: number } | null): string {
  if (!viewport) return 'nil'
  return [
    Math.round(viewport.scrollX * 10),
    Math.round(viewport.scrollY * 10),
    Math.round(viewport.zoom * 1000),
  ].join(',')
}

function bindingSignature(binding: any): unknown {
  if (!binding) return null
  return {
    elementId: binding.elementId ?? null,
    focus: binding.focus ?? null,
    gap: binding.gap ?? null,
  }
}

function sceneElementSignature(el: ExcalidrawElement): unknown {
  const anyEl = el as any
  return {
    id: el.id,
    type: el.type,
    isDeleted: Boolean(anyEl.isDeleted),
    x: Math.round((anyEl.x ?? 0) * 10) / 10,
    y: Math.round((anyEl.y ?? 0) * 10) / 10,
    width: Math.round((anyEl.width ?? 0) * 10) / 10,
    height: Math.round((anyEl.height ?? 0) * 10) / 10,
    angle: anyEl.angle ?? 0,
    strokeColor: anyEl.strokeColor ?? null,
    backgroundColor: anyEl.backgroundColor ?? null,
    fillStyle: anyEl.fillStyle ?? null,
    strokeWidth: anyEl.strokeWidth ?? null,
    strokeStyle: anyEl.strokeStyle ?? null,
    roughness: anyEl.roughness ?? null,
    roundness: anyEl.roundness ?? null,
    opacity: anyEl.opacity ?? null,
    frameId: anyEl.frameId ?? null,
    name: anyEl.name ?? null,
    text: anyEl.text ?? null,
    link: anyEl.link ?? null,
    startArrowhead: anyEl.startArrowhead ?? null,
    endArrowhead: anyEl.endArrowhead ?? null,
    points: anyEl.points ?? null,
    startBinding: bindingSignature(anyEl.startBinding),
    endBinding: bindingSignature(anyEl.endBinding),
    customData: anyEl.customData ?? null,
  }
}

function sceneElementsNeedUpdate(
  current: readonly ExcalidrawElement[],
  next: readonly ExcalidrawElement[],
): boolean {
  if (current.length !== next.length) return true
  for (let i = 0; i < next.length; i += 1) {
    if (JSON.stringify(sceneElementSignature(current[i])) !== JSON.stringify(sceneElementSignature(next[i]))) {
      return true
    }
  }
  return false
}

function interactiveElementsSignature(elements: readonly ExcalidrawElement[]): string {
  let out = ''
  for (const el of elements) {
    const anyEl = el as any
    out += el.id
    out += '|'
    out += el.type
    out += '|'
    out += anyEl.isDeleted ? '1' : '0'
    out += '|'
    out += Math.round((anyEl.x ?? 0) * 10)
    out += ','
    out += Math.round((anyEl.y ?? 0) * 10)
    out += ','
    out += Math.round((anyEl.width ?? 0) * 10)
    out += ','
    out += Math.round((anyEl.height ?? 0) * 10)
    out += '|'
    out += anyEl.frameId ?? ''
    out += '|'
    out += parseSessionFromElement(el) ?? parseChannelFromElement(el) ?? ''
    out += ';'
  }
  return out
}

function sessionCountSignature(
  elements: readonly ExcalidrawElement[],
  currentCanvasSessionIds: ReadonlySet<string>,
): string {
  const counts: Record<string, number> = {}
  for (const el of elements) {
    if (el.type !== 'rectangle') continue
    if ((el as any).isDeleted) continue
    const sid = parseSessionFromElement(el)
    if (!sid || !currentCanvasSessionIds.has(sid)) continue
    counts[sid] = (counts[sid] ?? 0) + 1
  }
  return Object.keys(counts).sort().map((sid) => `${sid}:${counts[sid]}`).join('|')
}

function frameMembershipSignature(elements: readonly ExcalidrawElement[]): string {
  let out = ''
  for (const el of elements) {
    const anyEl = el as any
    if (el.type === 'rectangle') {
      const sid = parseSessionFromElement(el)
      if (!sid) continue
      out += `r:${sid}:${anyEl.isDeleted ? 1 : 0}:${anyEl.frameId ?? ''};`
      continue
    }
    if (anyEl.type === 'frame') {
      const name = parseChannelFromElement(el)
      if (!name) continue
      out += `f:${el.id}:${name}:${anyEl.isDeleted ? 1 : 0};`
    }
  }
  return out
}

function dmStructureSignature(elements: readonly ExcalidrawElement[]): string {
  let out = ''
  for (const el of elements) {
    if (el.type !== 'arrow') continue
    if (isAssistantRelationElement(el)) continue
    const anyEl = el as any
    const start = anyEl.startBinding?.elementId ?? ''
    const end = anyEl.endBinding?.elementId ?? ''
    const meta = anyEl.customData?.dmArrow?.channel ?? ''
    out += `${el.id}:${anyEl.isDeleted ? 1 : 0}:${start}:${end}:${meta};`
  }
  return out
}

function persistedUserElementsSignature(elements: readonly ExcalidrawElement[]): string {
  let out = ''
  for (const el of elements) {
    if (el.type === 'rectangle' && parseSessionFromElement(el)) continue
    const anyEl = el as any
    out += el.id
    out += '|'
    out += el.type
    out += '|'
    out += anyEl.isDeleted ? '1' : '0'
    out += '|'
    out += Math.round((anyEl.x ?? 0) * 10)
    out += ','
    out += Math.round((anyEl.y ?? 0) * 10)
    out += ','
    out += Math.round((anyEl.width ?? 0) * 10)
    out += ','
    out += Math.round((anyEl.height ?? 0) * 10)
    out += '|'
    out += anyEl.frameId ?? ''
    out += '|'
    out += anyEl.text ?? ''
    out += '|'
    out += JSON.stringify(anyEl.customData ?? null)
    out += ';'
  }
  return out
}

function rectsIntersect(
  a: { x: number; y: number; width?: number; height?: number },
  b: { x: number; y: number; width?: number; height?: number },
): boolean {
  const aw = a.width ?? RECT_W
  const ah = a.height ?? RECT_H
  const bw = b.width ?? RECT_W
  const bh = b.height ?? RECT_H
  return a.x < b.x + bw && a.x + aw > b.x && a.y < b.y + bh && a.y + ah > b.y
}

function liveSessionRectElements(elements: readonly ExcalidrawElement[]): ExcalidrawElement[] {
  return elements.filter((el) =>
    el.type === 'rectangle' &&
    !(el as any).isDeleted &&
    Boolean(parseSessionFromElement(el)),
  )
}

function sessionLayoutFromRect(el: ExcalidrawElement): LayoutMap[string] {
  return {
    x: el.x,
    y: el.y,
    width: typeof el.width === 'number' && el.width > 0 ? el.width : undefined,
    height: typeof el.height === 'number' && el.height > 0 ? el.height : undefined,
  }
}

function applyStoredSessionSize<T extends ExcalidrawElement>(
  el: T,
  stored: LayoutMap[string] | null | undefined,
): T {
  if (!stored) return el
  const width = typeof stored.width === 'number' && stored.width > 0 ? stored.width : undefined
  const height = typeof stored.height === 'number' && stored.height > 0 ? stored.height : undefined
  if (!width && !height) return el
  return {
    ...el,
    width: width ?? el.width,
    height: height ?? el.height,
  } as T
}

function enforceSingleSessionCard(
  elements: readonly ExcalidrawElement[],
): { elements: readonly ExcalidrawElement[]; changed: boolean } {
  const seen = new Set<string>()
  let changed = false
  const next = elements.map((el) => {
    if (el.type !== 'rectangle' || (el as any).isDeleted) return el
    const sid = parseSessionFromElement(el)
    if (!sid) return el
    if (!seen.has(sid)) {
      seen.add(sid)
      return el
    }
    changed = true
    return { ...el, isDeleted: true } as ExcalidrawElement
  })
  return changed ? { elements: next, changed } : { elements, changed: false }
}

function originFromRectsOrViewport(
  rects: readonly ExcalidrawElement[],
  api: ExcalidrawImperativeAPI,
): { x: number; y: number } {
  if (rects.length > 0) {
    return {
      x: Math.round(Math.min(...rects.map((el) => el.x))),
      y: Math.round(Math.min(...rects.map((el) => el.y))),
    }
  }
  const appState = api.getAppState()
  const viewW = appState.width ?? 800
  const viewH = appState.height ?? 600
  const zoom = appState.zoom.value || 1
  return {
    x: Math.round(-appState.scrollX + viewW / zoom / 2 - RECT_W / 2),
    y: Math.round(-appState.scrollY + viewH / zoom / 2 - RECT_H / 2),
  }
}

function findOpenSessionGridPoint(
  api: ExcalidrawImperativeAPI,
  elements: readonly ExcalidrawElement[],
  preferred?: { x: number; y: number } | null,
): { x: number; y: number } {
  const rects = liveSessionRectElements(elements)
  const isOpen = (point: { x: number; y: number }) =>
    !rects.some((rect) => rectsIntersect(point, rect))
  if (preferred && isOpen(preferred)) return preferred

  const origin = originFromRectsOrViewport(rects, api)
  for (let index = 0; index < 400; index += 1) {
    const point = gridPointAt(origin, index)
    if (isOpen(point)) return point
  }
  return preferred ?? gridPointAt(origin, rects.length)
}

interface DmMeta {
  channel: string
  sidA: string
  sidB: string
}

function readDmMeta(el: any): DmMeta | null {
  const meta = el?.customData?.[DM_ARROW_META_KEY]
  if (!meta || typeof meta !== 'object') return null
  const channel = typeof meta.channel === 'string' ? meta.channel : null
  const sidA = typeof meta.sidA === 'string' ? meta.sidA : null
  const sidB = typeof meta.sidB === 'string' ? meta.sidB : null
  if (!channel || !sidA || !sidB) return null
  return { channel, sidA, sidB }
}

function withDmMeta(el: any, meta: DmMeta): any {
  const customData = {
    ...(el.customData ?? {}),
    [DM_ARROW_META_KEY]: meta,
  }
  return { ...el, customData }
}

function liveSessionRects(
  elements: readonly ExcalidrawElement[],
  sid: string,
): ExcalidrawElement[] {
  return elements.filter(
    (el) =>
      el.type === 'rectangle' &&
      !(el as any).isDeleted &&
      parseSessionFromElement(el) === sid,
  )
}

function focusSceneElement(
  api: ExcalidrawImperativeAPI,
  el: ExcalidrawElement,
): void {
  const appState = api.getAppState()
  const currentZoom = appState.zoom?.value ?? 1
  const zoom = Math.max(currentZoom, SIDEBAR_FOCUS_ZOOM)
  const viewW = appState.width ?? window.innerWidth
  const viewH = appState.height ?? window.innerHeight
  const centerX = (el.x ?? 0) + ((el.width ?? RECT_W) / 2)
  const centerY = (el.y ?? 0) + ((el.height ?? RECT_H) / 2)
  const scrollX = -centerX + viewW / zoom / 2
  const scrollY = -centerY + viewH / zoom / 2

  api.updateScene({
    appState: {
      scrollX,
      scrollY,
      zoom: { value: zoom },
      selectedElementIds: { [el.id]: true },
    } as any,
  })
}

/** Resolve a session sid from an Excalidraw element id of the form
 *  `session-<sid>` or `session-<sid>-<copyId>`. Greedy longest-match so a
 *  copy id with hyphens doesn't accidentally swallow a real sid. */
function resolveSessionIdFromElementId(
  id: string,
  sessionIds: readonly string[],
): string | null {
  if (!id.startsWith('session-')) return null
  const rest = id.slice('session-'.length)
  let best: string | null = null
  for (const sid of sessionIds) {
    if (rest === sid || rest.startsWith(`${sid}-`)) {
      if (!best || sid.length > best.length) best = sid
    }
  }
  return best
}

/** Read a binding endpoint and return the session sid it points to (or
 *  null). Tolerates the brief tick where Excalidraw drops bindings during
 *  scene rebuild by falling back to the element id pattern. */
function endpointSid(
  endpointElementId: string | undefined,
  elementsById: ReadonlyMap<string, ExcalidrawElement>,
  sessionIds: readonly string[],
): string | null {
  if (!endpointElementId) return null
  const el = elementsById.get(endpointElementId)
  if (el && !(el as any).isDeleted) {
    const sid = parseSessionFromElement(el)
    if (sid && sessionIds.includes(sid)) return sid
  }
  return resolveSessionIdFromElementId(endpointElementId, sessionIds)
}

/** Identify a card-to-card arrow, i.e. one whose start AND end bindings both
 *  resolve to (different) session rects -- that's the gesture for creating a
 *  1-on-1 DM channel. Falls back to persisted DM meta so a refreshed arrow
 *  remains classified even if Excalidraw dropped its bindings. */
function classifyDmArrow(
  el: any,
  elementsById: ReadonlyMap<string, ExcalidrawElement>,
  sessionIds: readonly string[],
): { sidA: string; sidB: string } | null {
  if (!el || el.type !== 'arrow' || el.isDeleted) return null
  if (isAssistantRelationElement(el as ExcalidrawElement)) return null
  const sStart = endpointSid(el.startBinding?.elementId, elementsById, sessionIds)
  const sEnd = endpointSid(el.endBinding?.elementId, elementsById, sessionIds)
  if (sStart && sEnd && sStart !== sEnd) {
    return { sidA: sStart, sidB: sEnd }
  }
  const meta = readDmMeta(el)
  if (meta && sessionIds.includes(meta.sidA) && sessionIds.includes(meta.sidB)) {
    return { sidA: meta.sidA, sidB: meta.sidB }
  }
  return null
}

/** Match a frameId on a session rect to its channel name, if any. The frame
 *  id is the deterministic `channel-<name>` string we put on every channel
 *  frame. */
function frameIdToChannelName(
  frameId: string | null | undefined,
  channelNames: readonly string[],
): string | null {
  if (!frameId || !frameId.startsWith('channel-')) return null
  const rest = frameId.slice('channel-'.length)
  // Greedy longest-match; channels named e.g. `foo` and `foo-bar` both match
  // an id of `channel-foo-bar`, prefer the longer.
  let best: string | null = null
  for (const name of channelNames) {
    if (rest === name) {
      if (!best || name.length > best.length) best = name
    }
  }
  return best
}


interface Props {
  canvasId: string
  canvasLoading: boolean
  gridModeEnabled: boolean
  currentCanvasSessionIds: Set<string>
  state: BoardState | null
  selection: Selection
  onSelectionChange: (s: Selection) => void
  onSelectedElementsContextChange: (items: SelectedCanvasElementContext[]) => void
  /** Increments each time Fit button is pressed. */
  fitSignal: number
  /** Increments each time Arrange sessions is requested outside Board. */
  arrangeSignal: number
  /**
   * Requests inserting a new embeddable for the given session id. The bump
   * counter changes on each request so the same session id can be inserted
   * multiple times back-to-back.
   */
  addToCanvasRequest: { sessionId: string; bump: number } | null
  /**
   * Requests removing all rects for the given session id. The bump counter
   * changes on each request so repeat clicks can re-trigger.
   */
  hideFromCanvasRequest: { sessionId: string; bump: number } | null
  /**
   * Bulk "show all" / "hide all" sessions at once. Sidebar fires this; Board
   * handles the batch in a single effect so the requests don't race through
   * React's setState batching the way per-sid calls would.
   */
  bulkVisibilityRequest: { mode: 'show' | 'hide'; bump: number; sids?: string[] } | null
  /** Sidebar session click: select, center, and zoom onto the matching card. */
  focusSessionRequest: { sessionId: string; bump: number } | null
  /** Assistant-generated canvas patch proposal. Consumed after the user clicks Apply. */
  canvasPatchRequest: CanvasPatchRequest | null
  /** Emits a toast-level result after applying an assistant canvas patch. */
  onCanvasPatchApplied: (result: { ok: boolean; message: string }) => void
  /**
   * Reports how many embeddable instances exist per sessionId on the canvas.
   * Used by the sidebar to show "on canvas / off canvas" indicators.
   */
  onCountsChange: (counts: Record<string, number>) => void
  onSceneSnapshotChange: (snapshot: {
    canvasId: string
    sessionLayout: LayoutMap
    channelLayout: LayoutMap
    viewport: { scrollX: number; scrollY: number; zoom: number } | null
    userElements: any[]
    dismissed: Set<string>
    unreadSids: Set<string>
  }) => void
  /** templateId → raw TSX source. App-level cache. */
  templateCache: Record<string, string>
  /** Fires on first render for a pluginId we haven't fetched yet. */
  onNeedTemplate: (pluginId: string) => void
  /** Invoked from the <Footer> refresh button. */
  onRefresh: () => void
  /** Invoked from the <MainMenu> "New channel" item. */
  onNewChannel: () => void
  /**
   * Requests placing a newly created channel's hub at the current viewport
   * center. Bumped once per create; the request is consumed in an effect that
   * writes the position into `channelLayoutRef` + persists. We can't just
   * compute the position in App.tsx because viewport math needs the imperative
   * Excalidraw API, which only Board owns.
   */
  placeChannelRequest: { channelName: string; bump: number } | null
  /** Invoked from the <MainMenu> "Ask AI to spawn…" item (claude -p driven). */
  onAskAndSpawn: () => void
  /** Invoked from the <MainMenu> "Preferences…" item. */
  onPreferences: () => void
  /** Invoked from the <MainMenu> "Fit to content" item. */
  onFit: () => void
  /** 未读通知的 session id 集合（Claude 刚回复完、用户还没点） */
  unreadSids: Set<string>
  /** Async storage interface (HTTP + localStorage in meee2; Supabase in meee2). */
  persistence: CanvasPersistence
  /** Hydrated initial values for every persisted slot — App.tsx has already
   *  resolved these via persistence.loadXxx() so Board can take them in
   *  useRef synchronously at first render. */
  initial: {
    sessionLayout: LayoutMap
    channelLayout: LayoutMap
    viewport: { scrollX: number; scrollY: number; zoom: number } | null
    userElements: any[]
    dismissed: Set<string>
  }
}

export default function Board({
  canvasId,
  canvasLoading,
  gridModeEnabled,
  currentCanvasSessionIds,
  state,
  selection,
  onSelectionChange,
  onSelectedElementsContextChange,
  fitSignal,
  arrangeSignal,
  addToCanvasRequest,
  hideFromCanvasRequest,
  bulkVisibilityRequest,
  focusSessionRequest,
  canvasPatchRequest,
  onCanvasPatchApplied,
  onCountsChange,
  onSceneSnapshotChange,
  templateCache,
  onNeedTemplate,
  onRefresh,
  onNewChannel,
  placeChannelRequest,
  onAskAndSpawn,
  onPreferences,
  onFit,
  unreadSids,
  persistence,
  initial,
}: Props) {
  const [api, setApi] = useState<ExcalidrawImperativeAPI | null>(null)
  const [arrangeConfirmOpen, setArrangeConfirmOpen] = useState(false)
  const [sceneRevision, setSceneRevision] = useState(0)
  const [saveStatus, setSaveStatus] = useState<'idle' | 'saving' | 'saved'>('idle')
  const pendingSaveCountRef = useRef(0)
  const saveIdleTimerRef = useRef<number | null>(null)
  const persistenceRef = useRef(persistence)
  persistenceRef.current = persistence
  // 把 Create channel / DM line 两个按钮 portal 到 Excalidraw 自己的
  // 横向 shape tool 行 (`.App-toolbar .Stack_horizontal`) 里 ——
  // Excalidraw 不暴露添加 shape tool 的公开 API（issue #7583 / #6697 已
  // 确认），所以走 React Portal 直接 attach 到那个 flex 行的 DOM 节点。
  // 必须挂到 .Stack_horizontal 而不是 .App-toolbar 本身，否则会成为
  // toolbar 的另一行子元素，被 wrap 到第二行去（实测过）。
  const [toolbarRowEl, setToolbarRowEl] = useState<HTMLElement | null>(null)
  const [zoomActionsEl, setZoomActionsEl] = useState<HTMLElement | null>(null)
  useEffect(() => {
    const find = () => {
      const toolbarEl = document.querySelector('.excalidraw .App-toolbar .Stack_horizontal') as HTMLElement | null
      const zoomEl = document.querySelector('.excalidraw .zoom-actions > .Stack_horizontal') as HTMLElement | null
      setToolbarRowEl((prev) => (prev === toolbarEl ? prev : toolbarEl))
      setZoomActionsEl((prev) => (prev === zoomEl ? prev : zoomEl))
    }
    find()
    const obs = new MutationObserver(find)
    obs.observe(document.body, { childList: true, subtree: true })
    return () => obs.disconnect()
  }, [])
  // Persistence is fully async via CanvasPersistence. App.tsx hydrates all
  // slots up-front (Promise.all of loadXxx) and passes them in as `initial`,
  // so these useRefs can take values synchronously at first render — same
  // semantics the old loadLayout()/loadChannelLayout() had, just hoisted up.
  const layoutRef = useRef<LayoutMap>(initial.sessionLayout)
  const channelLayoutRef = useRef<LayoutMap>(initial.channelLayout)
  // Save wrappers fire-and-forget the async persistence call; debounce coalesces
  // bursty drag updates. 400ms matches the old layout.ts / channelLayout.ts
  // debounce, so PUT traffic during a drag stays bounded.
  const trackCanvasSave = useCallback((label: string, action: () => Promise<unknown> | unknown): Promise<void> => {
    if (saveIdleTimerRef.current !== null) {
      window.clearTimeout(saveIdleTimerRef.current)
      saveIdleTimerRef.current = null
    }
    pendingSaveCountRef.current += 1
    setSaveStatus('saving')
    let result: Promise<unknown> | unknown
    try {
      result = action()
    } catch (error) {
      result = Promise.reject(error)
    }
    return Promise.resolve(result)
      .catch((error) => {
        console.warn(`[Board] ${label} autosave failed`, error)
      })
      .finally(() => {
        pendingSaveCountRef.current = Math.max(0, pendingSaveCountRef.current - 1)
        if (pendingSaveCountRef.current > 0) return
        setSaveStatus('saved')
        saveIdleTimerRef.current = window.setTimeout(() => {
          saveIdleTimerRef.current = null
          setSaveStatus('idle')
        }, 1800)
      })
      .then(() => undefined)
  }, [])

  useEffect(() => {
    return () => {
      if (saveIdleTimerRef.current !== null) {
        window.clearTimeout(saveIdleTimerRef.current)
        saveIdleTimerRef.current = null
      }
    }
  }, [])

  const saveLayoutDebounced = useMemo(
    () => debounce((m: LayoutMap) => {
      trackCanvasSave('session layout', () => persistence.saveSessionLayout(m))
    }, 400),
    [persistence, trackCanvasSave],
  )
  const saveChannelLayoutDebounced = useMemo(
    () => debounce((m: LayoutMap) => {
      trackCanvasSave('channel layout', () => persistence.saveChannelLayout(m))
    }, 400),
    [persistence, trackCanvasSave],
  )

  // Persisted Excalidraw appState + user-drawn shapes.
  // 只读一次 —— Excalidraw 的 initialData 只在首次挂载生效。
  const initialDataRef = useRef<{ elements: any[]; appState: any }>({
    elements: initial.userElements,
    appState: appStateFromViewport(initial.viewport),
  })
  const saveAppStateDebounced = useMemo(
    () => debounce((s: { scrollX: number; scrollY: number; zoom: number }) => {
      void persistence.saveViewport(s)
    }, 400),
    [persistence],
  )
  const saveShapesDebounced = useMemo(
    () => debounce((els: readonly any[]) => {
      trackCanvasSave('user elements', () => persistence.saveUserElements(els))
    }, 400),
    [persistence, trackCanvasSave],
  )
  const canvasSessionIdSignature = useMemo(
    () => [...currentCanvasSessionIds].sort().join('|'),
    [currentCanvasSessionIds],
  )
  const flushCanvasWrites = useCallback(() => {
    saveAppStateDebounced.flush()
    saveLayoutDebounced.flush()
    saveChannelLayoutDebounced.flush()
    saveShapesDebounced.flush()
    void persistence.flushPendingWrites?.()
  }, [
    persistence,
    saveAppStateDebounced,
    saveChannelLayoutDebounced,
    saveLayoutDebounced,
    saveShapesDebounced,
  ])
  // Sids the user has explicitly removed from canvas (last copy deleted).
  // Persisted via persistence.saveDismissed so auto-re-add doesn't fight the
  // user across WS ticks / reloads.
  const dismissedRef = useRef<Set<string>>(initial.dismissed)
  const currentCanvasSessionIdsRef = useRef(currentCanvasSessionIds)
  currentCanvasSessionIdsRef.current = currentCanvasSessionIds
  // Previous per-sid card count, used to detect >0 → 0 transitions in onChange.
  const prevCountsRef = useRef<Record<string, number>>({})
  const lastAddBumpRef = useRef<number>(-1)
  const lastHideBumpRef = useRef<number>(-1)
  const lastBulkBumpRef = useRef<number>(-1)
  const lastFocusSessionBumpRef = useRef<number>(-1)
  const lastCanvasPatchBumpRef = useRef<number>(-1)
  // Frame-membership snapshot from the previous tick: sid -> channel name.
  // Used to detect a card moving between frames so we can issue the right
  // addMember/removeMember pair against the backend.
  const knownFrameMembershipsRef = useRef<Map<string, string>>(new Map())
  // DM channels we know exist on the canvas this tick: channel name -> sids.
  // Diff against state.channels to detect new lines (createChannel +
  // addMember x2) and removed lines (deleteChannel).
  const knownDmChannelsRef = useRef<Map<string, { sidA: string; sidB: string }>>(new Map())
  // 上一次 onChange 看到的非-DM channel frame 名集合。当用户在画板上选中
  // channel frame 并按 Delete 后，本 tick 这个 frame 没了但 state.channels
  // 还有该 channel —— 触发 deleteChannel(...) 让 backend 也删掉，否则下一
  // 次 scene rebuild 又会把 frame 补回来（"删了又冒"），用户感知就是删不掉。
  const knownChannelFramesRef = useRef<Set<string>>(new Set())
  // In-flight DM channel mutations, keyed by channel name. Prevents the same
  // line being created or deleted twice while the network round-trip is
  // pending.
  const pendingDmOpsRef = useRef<Set<string>>(new Set())
  // In-flight frame-membership mutations, keyed by `${channel}|${sid}`.
  const pendingFrameOpsRef = useRef<Set<string>>(new Set())
  const lastPlaceChannelBumpRef = useRef<number>(-1)
  const initialFitDoneRef = useRef(false)
  // Last Excalidraw selection signature we processed. Used to skip re-firing
  // sidebar updates on WS ticks where selection didn't actually change.
  const prevSelSigRef = useRef<string>('')
  const prevInteractiveElementsSigRef = useRef<string>('')
  const prevCountSigRef = useRef<string>('')
  const prevFrameMembershipSigRef = useRef<string>('')
  const prevDmStructureSigRef = useRef<string>('')
  const prevPersistedUserElementsSigRef = useRef<string>('')
  const prevSceneSnapshotSigRef = useRef<string>('')
  // Tracks the last embeddable id we saw `activeEmbeddable.state === 'active'`
  // for. Prevents re-firing `activateSession` every frame while the embeddable
  // stays active.
  const lastActivatedElementIdRef = useRef<string | null>(null)

  // Reports per-session embeddable counts to the parent. Wrapped in a ref so
  // our effects don't capture stale callbacks across React re-renders.
  const onCountsChangeRef = useRef(onCountsChange)
  onCountsChangeRef.current = onCountsChange
  const onSceneSnapshotChangeRef = useRef(onSceneSnapshotChange)
  onSceneSnapshotChangeRef.current = onSceneSnapshotChange
  const publishSceneSnapshotDebounced = useMemo(
    () => debounce((snapshot: {
      canvasId: string
      sessionLayout: LayoutMap
      channelLayout: LayoutMap
      viewport: { scrollX: number; scrollY: number; zoom: number } | null
      userElements: any[]
      dismissed: Set<string>
      unreadSids: Set<string>
    }) => {
      onSceneSnapshotChangeRef.current(snapshot)
    }, 120),
    [],
  )
  const reportCountsRef = useRef(
    (elements: readonly ExcalidrawElement[]) => {
      const counts: Record<string, number> = {}
      for (const el of elements) {
        // Session cards are plain rectangles with customData.sessionId.
        if (el.type !== 'rectangle') continue
        if ((el as any).isDeleted) continue
        const sid = parseSessionFromElement(el)
        if (!sid) continue
        if (!currentCanvasSessionIdsRef.current.has(sid)) continue
        counts[sid] = (counts[sid] ?? 0) + 1
      }

      // Detect last-card deletion: sid was present last tick, gone now →
      // remember user intent so next WS tick doesn't auto-re-add.
      const prev = prevCountsRef.current
      const dropped: string[] = []
      const appeared: string[] = []
      let dismissedChanged = false
      for (const sid of Object.keys(prev)) {
        if ((prev[sid] ?? 0) > 0 && !(sid in counts)) {
          dropped.push(sid)
          if (!dismissedRef.current.has(sid)) {
            dismissedRef.current.add(sid)
            dismissedChanged = true
          }
        }
      }
      // Reverse: sid that re-appears on canvas (e.g. via Add-to-canvas or Undo)
      // clears its dismissal. Only clear when sid was ABSENT before (transition
      // 0 → >0), not on every tick where the sid is present — otherwise the
      // forward pass would re-dismiss it next tick, then this reverse pass
      // would undo it, and we'd oscillate. On a plain "rect still there" tick
      // both prev and counts have the sid, so no transition, no touch.
      for (const sid of Object.keys(counts)) {
        if (counts[sid] > 0 && !(sid in prev)) {
          appeared.push(sid)
          if (dismissedRef.current.delete(sid)) {
            dismissedChanged = true
          }
        }
      }
      // if (dropped.length || appeared.length) {
      //   console.log(
      //     '[Board.counts]',
      //     'dropped=', dropped.map(s => s.slice(0, 8)),
      //     'appeared=', appeared.map(s => s.slice(0, 8)),
      //     'dismissed=', [...dismissedRef.current].map(s => s.slice(0, 8)),
      //   )
      // }
      if (dismissedChanged) {
        void persistenceRef.current.saveDismissed(dismissedRef.current)
      }
      prevCountsRef.current = counts

      onCountsChangeRef.current(counts)
    },
  )

  useEffect(() => {
    const appState = appStateFromViewport(initial.viewport)
    initialDataRef.current = {
      elements: initial.userElements,
      appState,
    }
    layoutRef.current = initial.sessionLayout
    channelLayoutRef.current = initial.channelLayout
    dismissedRef.current = initial.dismissed
    prevCountsRef.current = {}
    knownFrameMembershipsRef.current = new Map()
    knownDmChannelsRef.current = new Map()
    knownChannelFramesRef.current = new Set()
    pendingDmOpsRef.current.clear()
    pendingFrameOpsRef.current.clear()
    initialFitDoneRef.current = false
    prevSelSigRef.current = ''
    prevInteractiveElementsSigRef.current = ''
    prevCountSigRef.current = ''
    prevFrameMembershipSigRef.current = ''
    prevDmStructureSigRef.current = ''
    prevPersistedUserElementsSigRef.current = ''
    prevSceneSnapshotSigRef.current = ''
    lastActivatedElementIdRef.current = null
    onSelectionChange({ kind: 'none' })
    if (!api) return
    api.updateScene({
      elements: initial.userElements as any,
      appState: {
        ...(appState ?? {}),
        selectedElementIds: {},
      } as any,
    })
    setSceneRevision((x) => (x + 1) & 0x7fffffff)
    reportCountsRef.current(initial.userElements as any)
  }, [api, canvasId, initial, onSelectionChange])

  useEffect(() => {
    const flush = () => flushCanvasWrites()
    const onVisibilityChange = () => {
      if (document.visibilityState === 'hidden') flush()
    }
    window.addEventListener('pagehide', flush)
    window.addEventListener('beforeunload', flush)
    document.addEventListener('visibilitychange', onVisibilityChange)
    return () => {
      window.removeEventListener('pagehide', flush)
      window.removeEventListener('beforeunload', flush)
      document.removeEventListener('visibilitychange', onVisibilityChange)
      flush()
    }
  }, [flushCanvasWrites])

  // -- Always-allow validator for our custom link scheme ------------------
  // Excalidraw normally checks embeddable links against an allowlist (known
  // hosts like YouTube, Figma, ...). Our `meee2://session/<id>` links don't
  // match, and the embeddable would render blank. Returning `true` lets our
  // `renderEmbeddable` callback own the render surface.
  const validateEmbeddable = useMemo(
    () => (_link: string) => true,
    [],
  )

  // -- Scene rebuild on state change -------------------------------------
  // Reconciles Excalidraw scene with backend state. Two managed shapes:
  //   - session rectangles (one or more per session; the DOM overlay paints
  //     the live card on top)
  //   - channel frames (one per non-DM channel; cards inside the frame =
  //     channel members; Excalidraw assigns frameId on drag-into-frame)
  // DM channels are visualised as user-drawn arrows between two session
  // rects -- they don't get their own managed shape; styling is normalised
  // here so a refreshed DM arrow keeps the violet/dashed look.
  useEffect(() => {
    if (!api || !state || canvasLoading) return

    const sceneState: BoardState = {
      ...state,
      sessions: sortSessionsForCanvas(state.sessions, currentCanvasSessionIds),
    }

    const ids = sceneState.sessions.map((s) => s.id)
    const nextLayout = ensurePositions(ids, layoutRef.current)
    if (!sameLayoutMap(layoutRef.current, nextLayout)) {
      layoutRef.current = nextLayout
      saveLayoutDebounced(nextLayout)
    }

    // Channel names (filter out operator '__…' defensively; backend already
    // strips them but guard anyway). DM channels get filtered separately
    // below: they don't render as frames.
    const channelNames = state.channels
      .map((c) => c.name)
      .filter((n) => !n.startsWith('__'))
    const frameChannelNames = channelNames.filter((n) => !isDmChannelName(n))
    const nextChannelLayout = ensureChannelPositions(
      frameChannelNames,
      channelLayoutRef.current,
    )
    if (!sameLayoutMap(channelLayoutRef.current, nextChannelLayout)) {
      channelLayoutRef.current = nextChannelLayout
      saveChannelLayoutDebounced(nextChannelLayout)
    }

    const sessionById = new Map(
      sceneState.sessions.map((s) => [s.id, { id: s.id, title: s.title }]),
    )
    const liveChannelByName = new Map(
      state.channels
        .filter((c) => !c.name.startsWith('__'))
        .map((c) => [c.name, c]),
    )
    const sessionIdsArr = sceneState.sessions.map((s) => s.id)

    // -- Bucket existing elements --------------------------------------
    const existing = api.getSceneElements()
    const elementsById = new Map(existing.map((el) => [el.id, el]))

    // userShapes: anything not on the managed-id allowlist (sessions and
    // channel-* shapes). Filters out orphaned channel-text labels so they
    // don't accumulate one-per-refresh.
    const userShapesRaw = existing.filter((e) => {
      if (isManagedElementId(e.id)) return false
      if (e.type === 'text') {
        const cid = (e as any).containerId as string | undefined
        if (cid && cid.startsWith('channel-') && !e.id.startsWith('channel-')) {
          return false
        }
      }
      return true
    })
    // Restyle DM arrows: any user-drawn arrow whose start AND end bind to
    // session rects is a DM line. Apply distinctive violet/dashed style and
    // persist DM meta into customData so the next rebuild can keep it
    // recognised even if Excalidraw drops bindings.
    const dmStyleStrokeWidth = (channel: string) => {
      const ch = liveChannelByName.get(channel)
      return ch && ch.pendingCount > 0
        ? DM_LINE_STROKE_WIDTH_PENDING
        : DM_LINE_STROKE_WIDTH_BASE
    }
    const userShapes = userShapesRaw.map((el: any) => {
      if (el.type !== 'arrow') return el
      const sb = el.startBinding ? { ...el.startBinding } : null
      const eb = el.endBinding ? { ...el.endBinding } : null
      let touched = false
      if (sb && sb.elementId && sb.gap == null) { sb.gap = 1; touched = true }
      if (sb && sb.elementId && sb.focus == null) { sb.focus = 0; touched = true }
      if (eb && eb.elementId && eb.gap == null) { eb.gap = 1; touched = true }
      if (eb && eb.elementId && eb.focus == null) { eb.focus = 0; touched = true }

      const dm = classifyDmArrow(el, elementsById, sessionIdsArr)
      if (dm) {
        const channel = dmChannelName(dm.sidA, dm.sidB)
        return withDmMeta({
          ...el,
          startBinding: sb,
          endBinding: eb,
          strokeColor: DM_LINE_STROKE_COLOR,
          strokeWidth: dmStyleStrokeWidth(channel),
          strokeStyle: 'dashed',
          startArrowhead: null,
          endArrowhead: null,
        }, { channel, sidA: dm.sidA, sidB: dm.sidB })
      }
      if (!touched) return el
      return { ...el, startBinding: sb, endBinding: eb }
    })

    // Session rects.
    const existingEmbeddablesRaw = existing.filter(
      (e) =>
        e.type === 'rectangle' &&
        !(e as any).isDeleted &&
        parseSessionFromElement(e) !== null,
    )
    const existingEmbeddables: ExcalidrawElement[] = []
    const duplicateEmbeddables: ExcalidrawElement[] = []
    {
      const seenSessionRects = new Set<string>()
      for (const el of existingEmbeddablesRaw) {
        const sid = parseSessionFromElement(el)
        if (!sid || !seenSessionRects.has(sid)) {
          if (sid) seenSessionRects.add(sid)
          existingEmbeddables.push(el)
        } else {
          duplicateEmbeddables.push({ ...el, isDeleted: true } as ExcalidrawElement)
        }
      }
    }

    // Current channel frames (the new shape) + legacy hubs/labels/spokes
    // that we tombstone on this rebuild.
    const existingChannelFrames = existing.filter(
      (e) =>
        (e as any).type === 'frame' &&
        !(e as any).isDeleted &&
        parseChannelFromElement(e) !== null,
    )
    const legacyHubEllipses = existing.filter(
      (e) =>
        e.type === 'ellipse' &&
        !(e as any).isDeleted &&
        parseChannelFromElement(e) !== null,
    )
    const legacyHubLabels = existing.filter(
      (e) =>
        e.type === 'text' &&
        !(e as any).isDeleted &&
        typeof e.id === 'string' &&
        e.id.startsWith('channel-') &&
        e.id.endsWith('-label'),
    )
    const legacySpokes = existing.filter(
      (e) =>
        e.type === 'arrow' &&
        !(e as any).isDeleted &&
        typeof e.id === 'string' &&
        e.id.startsWith('channel-') &&
        e.id.includes('-spoke-'),
    )
    const legacySpokeLabels = existing.filter((e) => {
      if (e.type !== 'text') return false
      if ((e as any).isDeleted) return true
      const cid = (e as any).containerId as string | undefined
      if (!cid) return false
      return cid.startsWith('channel-') && cid.includes('-spoke-')
    })

    const knownSessionIds = new Set<string>()
    for (const e of existingEmbeddables) {
      const sid = parseSessionFromElement(e)
      if (sid) knownSessionIds.add(sid)
    }
    const knownFrameChannelNames = new Set<string>()
    for (const e of existingChannelFrames) {
      const name = parseChannelFromElement(e)
      if (name) knownFrameChannelNames.add(name)
    }

    // The active canvas membership is now the visibility source of truth.
    // Clear legacy local dismissal tombstones for sessions App.tsx has already
    // admitted into this canvas, otherwise a checked canvas membership can
    // still render as a hidden row/card after older local state is restored.
    let clearedMembershipDismissal = false
    for (const s of sceneState.sessions) {
      if (!currentCanvasSessionIds.has(s.id)) continue
      if (dismissedRef.current.delete(s.id)) clearedMembershipDismissal = true
    }
    if (clearedMembershipDismissal) {
      void persistence.saveDismissed(dismissedRef.current)
    }

    const newSessionIds: string[] = []
    for (const s of sceneState.sessions) {
      // In multi-canvas mode, App.tsx already filters state.sessions to the
      // active canvas membership. Membership means visible on this canvas, so
      // older sessions must still get a card instead of being silently hidden.
      if (knownSessionIds.has(s.id)) continue
      newSessionIds.push(s.id)
    }
    // if (newSessionIds.length > 0 || dismissedRef.current.size > 0) {
    //   console.log(
    //     '[Board.scene] new=%d dismissed=%d',
    //     newSessionIds.length,
    //     dismissedRef.current.size,
    //   )
    // }

    // Channels needing a fresh frame: every non-DM channel that hasn't been
    // built yet.
    const newChannelNames = frameChannelNames.filter(
      (n) => !knownFrameChannelNames.has(n),
    )
    // if (newChannelNames.length > 0) {
    //   console.log(
    //     '[Board] rebuilding missing channel frames:',
    //     newChannelNames,
    //     '(known:',
    //     Array.from(knownFrameChannelNames),
    //     ')',
    //   )
    // }

    const { newEmbeddables, newChannelHubs } = buildScene(
      sceneState,
      layoutRef.current,
      channelLayoutRef.current,
      {
        newSessionIds,
        newChannelNames,
      },
    )

    const converted = convertToExcalidrawElements(
      [...newEmbeddables, ...newChannelHubs] as any,
      { regenerateIds: false },
    )

    // -- Normalize existing rects --------------------------------------
    // Force the meee2 background colors so legacy rects don't leak grey
    // halos around the DOM overlay; tombstone rects whose session is gone.
    // Also sync `frameId` from backend state: every session that's a
    // member of a (non-DM) frame channel should have its rects belong to
    // that frame visually. This is essential for the upgrade path where
    // pre-existing channel memberships load before the user has dragged
    // anything -- without it, handleChange's frame-membership diff would
    // see "no frameId on rects" vs "memberships in state" and start
    // removing those memberships. We skip the sync for sessions whose
    // frame ops are currently in-flight to preserve the user's drag intent
    // while the network round-trip is pending.
    const liveSids = new Set(ids)
    const stateFrameMembershipBySid = new Map<string, string>()
    for (const ch of state.channels) {
      if (ch.name.startsWith('__')) continue
      if (isDmChannelName(ch.name)) continue
      for (const m of ch.members) {
        stateFrameMembershipBySid.set(m.sessionId, ch.name)
      }
    }
    const sidHasPendingFrameOp = (sid: string): boolean => {
      for (const opKey of pendingFrameOpsRef.current) {
        if (opKey.endsWith(`|${sid}`)) return true
      }
      return false
    }
    const normalizedExisting = existingEmbeddables.map((el: any) => {
      const sid = parseSessionFromElement(el)
      if (sid && !liveSids.has(sid)) {
        return { ...el, isDeleted: true }
      }
      const next: any = {
        ...el,
        strokeColor: 'transparent',
        backgroundColor: 'transparent',
        fillStyle: 'solid',
        strokeWidth: 0,
        roughness: 0,
        roundness: null,
      }
      if (sid && !sidHasPendingFrameOp(sid)) {
        const expectedChannel = stateFrameMembershipBySid.get(sid) ?? null
        const expectedFrameId = expectedChannel ? channelHubId(expectedChannel) : null
        next.frameId = expectedFrameId
      }
      return next
    })

    // -- Normalize existing channel frames -----------------------------
    // Preserve user-positioned x/y/width/height (frame is a user-resizable
    // container) but re-sync stroke color / strokeStyle based on mode +
    // pending. Tombstone if its channel was deleted.
    const normalizedChannelFrames = existingChannelFrames.map((el: any) => {
      const name = parseChannelFromElement(el)
      const ch = name ? liveChannelByName.get(name) : null
      if (!ch) {
        return { ...el, isDeleted: true }
      }
      return {
        ...el,
        type: 'frame',
        name: `#${ch.name}`,
        strokeColor: modeStrokeColor(ch.mode),
        backgroundColor: 'transparent',
        fillStyle: 'solid',
        strokeWidth: 2,
        strokeStyle: modeStrokeStyle(ch),
        roundness: null,
        opacity: 100,
        locked: false,
        customData: { channelName: ch.name },
      }
    })

    // -- Tombstone legacy ellipse hubs / labels / spokes ---------------
    const tombstone = (el: any) => ({ ...el, isDeleted: true })
    const tombstonedLegacyHubs = legacyHubEllipses.map(tombstone)
    const tombstonedLegacyHubLabels = legacyHubLabels.map(tombstone)
    const tombstonedLegacySpokes = legacySpokes.map(tombstone)
    const tombstonedLegacySpokeLabels = legacySpokeLabels.map(tombstone)

    const preservedExisting = [
      ...userShapes,
      ...normalizedExisting,
      ...duplicateEmbeddables,
      ...normalizedChannelFrames,
      ...tombstonedLegacyHubs,
      ...tombstonedLegacyHubLabels,
      ...tombstonedLegacySpokes,
      ...tombstonedLegacySpokeLabels,
    ]

    const finalElements = [...preservedExisting, ...converted]
    if (sceneElementsNeedUpdate(existing, finalElements)) {
      api.updateScene({
        elements: finalElements as any,
      })
      setSceneRevision((x) => (x + 1) & 0x7fffffff)
    }
    reportCountsRef.current(finalElements)
    if (!initialFitDoneRef.current) {
      const visibleContent = finalElements.filter((el) => !(el as any).isDeleted)
      if (visibleContent.length > 0) {
        initialFitDoneRef.current = true
        requestAnimationFrame(() => {
          try {
            api.scrollToContent(visibleContent, { fitToContent: true, animate: false })
          } catch (e) {
            console.warn('[Board] initial fit-to-content failed', e)
          }
        })
      }
    }
  }, [api, state, canvasId, canvasLoading, canvasSessionIdSignature, currentCanvasSessionIds, persistence, saveLayoutDebounced, saveChannelLayoutDebounced, trackCanvasSave])

  // -- Fit-to-content --------------------------------------------------
  useEffect(() => {
    if (!api || fitSignal === 0) return
    const elements = api.getSceneElements().filter((el) => !(el as any).isDeleted)
    if (elements.length > 0) {
      api.scrollToContent(elements, { fitToContent: true, animate: true })
    }
  }, [api, fitSignal])

  useEffect(() => {
    if (arrangeSignal === 0) return
    setArrangeConfirmOpen(true)
  }, [arrangeSignal])

  // -- Keep Excalidraw library free of session cards -------------------
  // Session cards are one-per-session on a canvas. Leaving managed cards in
  // Excalidraw's library would let drag/drop bypass that invariant.
  useEffect(() => {
    if (!api) return
    api.updateLibrary({ libraryItems: [], merge: false }).catch((e) => {
      console.warn('[Board] updateLibrary failed', e)
    })
  }, [api])

  // -- Add-to-canvas from sidebar -------------------------------------
  useEffect(() => {
    if (!api || !state || !addToCanvasRequest) return
    if (addToCanvasRequest.bump === lastAddBumpRef.current) return
    lastAddBumpRef.current = addToCanvasRequest.bump

    const session = state.sessions.find(
      (s) => s.id === addToCanvasRequest.sessionId,
    )
    if (!session) return

    const visible = liveSessionRects(api.getSceneElements(), session.id)[0]
    if (visible) {
      api.scrollToContent([visible], { fitToContent: false, animate: true })
      return
    }

    // User explicitly brought this session back — undo any prior dismissal.
    if (dismissedRef.current.delete(session.id)) {
      void persistence.saveDismissed(dismissedRef.current)
    }

    // 优先级 1：如果 hide 留下的 `isDeleted:true` rect 还在（通常都在——
    // Excalidraw 保留 deleted 元素供 Undo），把它 undelete 回来。这样位置、
    // 连着的 arrow、element id 全部保持；用户的视觉直觉是"把刚才藏起来的
    // 那张卡拿回来"，而不是"凭空又多了一张"。
    const all = (api.getSceneElementsIncludingDeleted?.() ?? api.getSceneElements()) as readonly ExcalidrawElement[]
    const prior = all.find(
      (el) =>
        el.type === 'rectangle' &&
        (el as any).isDeleted === true &&
        parseSessionFromElement(el) === session.id,
    )
    if (prior) {
      const point = findOpenSessionGridPoint(api, all.filter((el) => el !== prior), prior)
      const restored = {
        ...prior,
        x: point.x,
        y: point.y,
        isDeleted: false,
      } as ExcalidrawElement
      const nextAll = all.map((el) => (el === prior ? restored : el))
      layoutRef.current = {
        ...layoutRef.current,
        [session.id]: sessionLayoutFromRect(restored),
      }
      saveLayoutDebounced(layoutRef.current)
      api.updateScene({ elements: nextAll as any })
      setSceneRevision((x) => (x + 1) & 0x7fffffff)
      reportCountsRef.current(nextAll)
      api.scrollToContent([restored], { fitToContent: false, animate: true })
      return
    }

    // 优先级 2：layoutRef 里有上次记录的位置（用户之前移动过 / scene rebuild
    // 曾给它分过格子）→ 复用那个位置。否则才落到 viewport center + jitter。
    const saved = layoutRef.current[session.id]
    const point = findOpenSessionGridPoint(api, api.getSceneElements(), saved ?? null)
    const { x, y } = point
    layoutRef.current = {
      ...layoutRef.current,
      [session.id]: {
        x,
        y,
        width: saved?.width,
        height: saved?.height,
      },
    }
    saveLayoutDebounced(layoutRef.current)

    // Generate a collision-free id; the scene-level invariant still keeps
    // only one live card per session.
    const newId = `session-${session.id}-${Date.now().toString(36)}`
    const skeleton = buildSessionEmbeddable(session, x, y, newId)
    const [built] = convertToExcalidrawElements([skeleton] as any, {
      regenerateIds: false,
    })
    if (!built) return
    const sized = applyStoredSessionSize(built as ExcalidrawElement, layoutRef.current[session.id])

    const next = [...api.getSceneElements(), sized]
    api.updateScene({ elements: next as any })
    setSceneRevision((x) => (x + 1) & 0x7fffffff)
    reportCountsRef.current(next)

    // Scroll the new element into view.
    api.scrollToContent([sized], { fitToContent: false, animate: true })
  }, [api, state, addToCanvasRequest, persistence, saveLayoutDebounced, trackCanvasSave])

  // -- Hide-from-canvas from sidebar (eye 👁 toggle off) ---------------
  // Deletes all rects with customData.sessionId === sid. The
  // reportCountsRef's >0→0 detection will add sid to dismissed so next WS
  // tick doesn't auto-re-add.
  useEffect(() => {
    if (!api || !hideFromCanvasRequest) return
    if (hideFromCanvasRequest.bump === lastHideBumpRef.current) return
    lastHideBumpRef.current = hideFromCanvasRequest.bump

    const sid = hideFromCanvasRequest.sessionId
    const existing = api.getSceneElements()
    // Mark matching rects as deleted. Keeping them in the array (with
    // isDeleted: true) rather than splicing out preserves Excalidraw's Undo.
    const next = existing.map((el) => {
      if (el.type !== 'rectangle') return el
      if (parseSessionFromElement(el) !== sid) return el
      return { ...el, isDeleted: true }
    })
    api.updateScene({ elements: next as any })
    setSceneRevision((x) => (x + 1) & 0x7fffffff)
    reportCountsRef.current(next)
  }, [api, hideFromCanvasRequest])

  // -- Bulk show/hide from sidebar "Show all" / "Hide all" ------------
  // Walks every session, hides all rects (mark isDeleted:true) or ensures
  // each session has a visible rect (undelete existing or create new at the
  // saved layout position). Dismissed-set is cleaned up on "show" so the
  // scene-rebuild branch doesn't immediately hide them again.
  useEffect(() => {
    if (!api || !state || !bulkVisibilityRequest) return
    if (bulkVisibilityRequest.bump === lastBulkBumpRef.current) return
    lastBulkBumpRef.current = bulkVisibilityRequest.bump

    const all = (api.getSceneElementsIncludingDeleted?.() ?? api.getSceneElements()) as readonly ExcalidrawElement[]

    // Optional sid scope — when present, the operation only affects the
    // listed session ids (sidebar's per-category toggle). Absent / empty =
    // operate on every session (top-level "Hide all" / "Show all").
    const scope = bulkVisibilityRequest.sids
    const inScope = scope && scope.length > 0
      ? (sid: string | null) => sid != null && scope.includes(sid)
      : (sid: string | null) => sid != null

    if (bulkVisibilityRequest.mode === 'hide') {
      // 全部隐藏（或 scope 内的全部）：标 isDeleted:true。reportCountsRef 在
      // 一次调用里算每个 sid 的 >0→0 transition，把对应 sid 加入 dismissedRef +
      // 持久化（scope 外的 session 不受影响）。
      const next = all.map((el) => {
        if (el.type !== 'rectangle') return el
        const sid = parseSessionFromElement(el)
        if (!inScope(sid)) return el
        if ((el as any).isDeleted) return el
        return { ...el, isDeleted: true }
      })
      api.updateScene({ elements: next as any })
      setSceneRevision((x) => (x + 1) & 0x7fffffff)
      reportCountsRef.current(next)
      return
    }

    // show：对每个 session
    //   (a) 如果画布上已经有一张非 deleted 的 rect → 什么都不做
    //   (b) 有 isDeleted:true 的 rect → undelete 它（保留位置 + 连着的 arrow）
    //   (c) 完全没 rect（dismissedRef 里彻底清过） → buildSessionEmbeddable 新建
    //       一张到 layoutRef 里记住的位置，没记录就走 ensurePositions 的默认网格
    const hasVisible = new Set<string>()
    const firstDeleted = new Map<string, ExcalidrawElement>()
    for (const el of all) {
      if (el.type !== 'rectangle') continue
      const sid = parseSessionFromElement(el)
      if (!sid) continue
      if (!(el as any).isDeleted) {
        hasVisible.add(sid)
      } else if (!firstDeleted.has(sid)) {
        firstDeleted.set(sid, el)
      }
    }

    // pass 1：undelete 存在的 deleted rect
    const undeleted = new Set<string>()
    const next = all.map((el) => {
      if (el.type !== 'rectangle') return el
      const sid = parseSessionFromElement(el)
      if (!sid) return el
      if (hasVisible.has(sid) || undeleted.has(sid)) return el
      const dup = firstDeleted.get(sid)
      if (dup && el === dup && (el as any).isDeleted) {
        undeleted.add(sid)
        return { ...el, isDeleted: false }
      }
      return el
    })

    // pass 2：完全没 rect 的新建（scope 外的 session 不受影响）
    const needCreate: string[] = []
    for (const s of state.sessions) {
      if (!inScope(s.id)) continue
      if (!hasVisible.has(s.id) && !undeleted.has(s.id)) {
        needCreate.push(s.id)
      }
    }
    if (needCreate.length > 0) {
      layoutRef.current = ensurePositions(state.sessions.map((s) => s.id), layoutRef.current)
      for (const sid of needCreate) {
        const sess = state.sessions.find((x) => x.id === sid)
        if (!sess) continue
        const saved = layoutRef.current[sid]
        const point = findOpenSessionGridPoint(api, next, saved ?? null)
        layoutRef.current[sid] = {
          x: point.x,
          y: point.y,
          width: saved?.width,
          height: saved?.height,
        }
        const newId = `session-${sid}-${Date.now().toString(36)}`
        const skeleton = buildSessionEmbeddable(sess, point.x, point.y, newId)
        const [built] = convertToExcalidrawElements([skeleton] as any, { regenerateIds: false })
        if (built) next.push(applyStoredSessionSize(built as ExcalidrawElement, layoutRef.current[sid]))
      }
      saveLayoutDebounced(layoutRef.current)
    }

    // 清 dismissed 标记 —— 仅 scope 内的，scope 外的 session 保持原 dismiss 状态
    let dismissedChanged = false
    for (const s of state.sessions) {
      if (!inScope(s.id)) continue
      if (dismissedRef.current.delete(s.id)) dismissedChanged = true
    }
    if (dismissedChanged) {
      void persistence.saveDismissed(dismissedRef.current)
    }

    api.updateScene({ elements: next as any })
    setSceneRevision((x) => (x + 1) & 0x7fffffff)
    reportCountsRef.current(next)
  }, [api, state, bulkVisibilityRequest, persistence, saveLayoutDebounced, trackCanvasSave])

  // -- Place a freshly-created channel frame at the current viewport center --
  // The dialog calls onCreated(name) in App.tsx, which sets
  // placeChannelRequest. We consume it here: compute viewport center (same
  // math as add-to-canvas), write into channelLayoutRef + persist, then
  // schedule a scene rebuild so the frame materialises at that point. The
  // scene-rebuild effect above sees a new-channel-name and builds the frame
  // from channelLayoutRef[name]. DM channels skip this path -- they're
  // visualised as arrows and don't get a managed frame.
  useEffect(() => {
    if (!api || !state || !placeChannelRequest) return
    if (placeChannelRequest.bump === lastPlaceChannelBumpRef.current) return
    lastPlaceChannelBumpRef.current = placeChannelRequest.bump

    const name = placeChannelRequest.channelName
    if (!name || name.startsWith('__')) return
    if (isDmChannelName(name)) return

    const appState = api.getAppState()
    const viewW = appState.width ?? 800
    const viewH = appState.height ?? 600
    const zoom = appState.zoom.value || 1
    const cx = -appState.scrollX + viewW / zoom / 2
    const cy = -appState.scrollY + viewH / zoom / 2
    // Center the frame on viewport center.
    const x = Math.round(cx - CHANNEL_FRAME_W / 2)
    const y = Math.round(cy - CHANNEL_FRAME_H / 2)

    channelLayoutRef.current = {
      ...channelLayoutRef.current,
      [name]: { x, y },
    }
    saveChannelLayoutDebounced(channelLayoutRef.current)

    // If the frame already exists (e.g. the channel was re-created with the
    // same name after a short delete), move it and re-scroll into view.
    const frameEl = api.getSceneElements().find(
      (el) => el.id === channelHubId(name) && (el as any).type === 'frame',
    ) as any
    if (frameEl) {
      const next = api.getSceneElements().map((el) => {
        if (el.id === channelHubId(name) && (el as any).type === 'frame') {
          return { ...el, x, y } as any
        }
        return el
      })
      api.updateScene({ elements: next as any })
      setSceneRevision((x) => (x + 1) & 0x7fffffff)
      api.scrollToContent([frameEl], { fitToContent: false, animate: true })
    } else {
      // Build and insert immediately using whatever channel snapshot we
      // have; the scene-rebuild effect will normalise it once state updates.
      const ch = state.channels.find((c) => c.name === name)
      if (ch) {
        const skeletons = buildChannelHub(ch, x, y)
        const built = convertToExcalidrawElements(skeletons as any, {
          regenerateIds: false,
        })
        if (built.length > 0) {
          const next = [...api.getSceneElements(), ...built]
          api.updateScene({ elements: next as any })
          setSceneRevision((x) => (x + 1) & 0x7fffffff)
          api.scrollToContent([built[0]], { fitToContent: false, animate: true })
        }
      }
    }
  }, [api, state, placeChannelRequest, saveChannelLayoutDebounced])

  // -- Focus session card from sidebar click -----------------------------
  useEffect(() => {
    if (!api || !state || !focusSessionRequest) return
    if (focusSessionRequest.bump === lastFocusSessionBumpRef.current) return
    lastFocusSessionBumpRef.current = focusSessionRequest.bump

    const sid = focusSessionRequest.sessionId
    let target = liveSessionRects(api.getSceneElements(), sid)[0]

    if (!target) {
      const all = (api.getSceneElementsIncludingDeleted?.() ?? api.getSceneElements()) as readonly ExcalidrawElement[]
      const prior = all.find(
        (el) =>
          el.type === 'rectangle' &&
          (el as any).isDeleted === true &&
          parseSessionFromElement(el) === sid,
      )

      if (prior) {
        const restored = { ...prior, isDeleted: false } as ExcalidrawElement
        const nextAll = all.map((el) => (el === prior ? restored : el))
        layoutRef.current = {
          ...layoutRef.current,
          [sid]: sessionLayoutFromRect(restored),
        }
        saveLayoutDebounced(layoutRef.current)
        api.updateScene({ elements: nextAll as any })
        setSceneRevision((x) => (x + 1) & 0x7fffffff)
        reportCountsRef.current(nextAll)
        target = restored
      } else {
        const session = state.sessions.find((s) => s.id === sid)
        if (!session) return

        const saved = layoutRef.current[sid]
        const point = findOpenSessionGridPoint(api, api.getSceneElements(), saved ?? null)
        const { x, y } = point
        layoutRef.current = {
          ...layoutRef.current,
          [sid]: {
            x,
            y,
            width: saved?.width,
            height: saved?.height,
          },
        }
        saveLayoutDebounced(layoutRef.current)

        const allIds = new Set(
          (api.getSceneElementsIncludingDeleted?.() ?? api.getSceneElements()).map((el) => el.id),
        )
        const preferredId = sessionRectId(session.id)
        const id = allIds.has(preferredId)
          ? `session-${session.id}-${Date.now().toString(36)}`
          : preferredId
        const skeleton = buildSessionEmbeddable(session, x, y, id)
        const [built] = convertToExcalidrawElements([skeleton] as any, {
          regenerateIds: false,
        })
        if (!built) return

        target = applyStoredSessionSize(built as ExcalidrawElement, layoutRef.current[sid])
        const next = [...api.getSceneElements(), target]
        api.updateScene({ elements: next as any })
        setSceneRevision((x) => (x + 1) & 0x7fffffff)
        reportCountsRef.current(next)
      }
    }

    if (dismissedRef.current.delete(sid)) {
      void persistence.saveDismissed(dismissedRef.current)
    }
    // 关键：focusSceneElement 推到下一帧。否则跟下面 multi-select push-back
    // effect 在同一同步批里跑，Excalidraw 处理 selectedElementIds 时偶发会
    // 把 scroll/zoom 一起重算，导致 focus 改的 scrollX/scrollY 立刻被覆盖
    // —— 用户感受到的"点很多次才切过去"就是这个 race。延后一帧让 focus
    // 单独成 batch，scroll/zoom 改动稳稳生效。
    const targetEl = target
    requestAnimationFrame(() => {
      focusSceneElement(api, targetEl)
    })
  }, [api, state, focusSessionRequest, persistence, saveLayoutDebounced, trackCanvasSave])

  // -- Assistant canvas patch Apply -----------------------------------
  // Chatbox proposals are intentionally preview-only. Once the user clicks
  // Apply, Board owns the live Excalidraw scene update so the visible canvas,
  // localStorage shadow cache, and Swift JSON persistence stay in sync.
  useEffect(() => {
    if (!api || !state || !canvasPatchRequest) return
    if (canvasPatchRequest.bump === lastCanvasPatchBumpRef.current) return
    lastCanvasPatchBumpRef.current = canvasPatchRequest.bump

    const { proposal } = canvasPatchRequest
    const sessionById = new Map(state.sessions.map((s) => [s.id, s]))
    const channelNames = new Set(
      state.channels
        .map((c) => c.name)
        .filter((name) => !name.startsWith('__')),
    )

    try {
      const all = (api.getSceneElementsIncludingDeleted?.() ?? api.getSceneElements()) as readonly ExcalidrawElement[]
      let nextElements: ExcalidrawElement[] = [...all]
      let nextLayout: LayoutMap = { ...layoutRef.current }
      let nextChannelLayout: LayoutMap = { ...channelLayoutRef.current }
      let sessionLayoutChanged = false
      let channelLayoutChanged = false
      let userElementsChanged = false
      let dismissedChanged = false
      const membershipOps: Array<Promise<unknown>> = []
      const persistenceOps: Array<Promise<unknown>> = []
      const elementAliases = new Map<string, string>()

      const requireSession = (sid: string) => {
        const session = sessionById.get(sid)
        if (!session) throw new Error(`Session is not on this canvas: ${sid.slice(0, 8)}`)
        return session
      }
      const requireChannel = (name: string) => {
        if (!channelNames.has(name)) throw new Error(`Channel is not on this canvas: ${name}`)
      }
      const visibleSessionRectIndex = (sid: string) =>
        nextElements.findIndex((el) =>
          el.type === 'rectangle' &&
          !(el as any).isDeleted &&
          parseSessionFromElement(el) === sid,
        )
      const deletedSessionRectIndex = (sid: string) =>
        nextElements.findIndex((el) =>
          el.type === 'rectangle' &&
          (el as any).isDeleted === true &&
          parseSessionFromElement(el) === sid,
        )
      const viewportCenter = () => {
        const appState = api.getAppState()
        const viewW = appState.width ?? 800
        const viewH = appState.height ?? 600
        const zoom = appState.zoom.value || 1
        return {
          x: -appState.scrollX + viewW / zoom / 2,
          y: -appState.scrollY + viewH / zoom / 2,
        }
      }
      const sessionPosition = (sid: string, op: Partial<{ x: number; y: number }>) => {
        const saved = nextLayout[sid]
        if (typeof op.x === 'number' && typeof op.y === 'number') return { x: op.x, y: op.y }
        if (saved) {
          return {
            x: typeof op.x === 'number' ? op.x : saved.x,
            y: typeof op.y === 'number' ? op.y : saved.y,
          }
        }
        const center = viewportCenter()
        return {
          x: typeof op.x === 'number' ? op.x : Math.round(center.x - RECT_W / 2),
          y: typeof op.y === 'number' ? op.y : Math.round(center.y - RECT_H / 2),
        }
      }
      const createSessionRect = (op: Extract<CanvasPatchOperation, { type: 'show_session' }>) => {
        const session = requireSession(op.sessionId)
        const pos = sessionPosition(op.sessionId, op)
        const id = `session-${op.sessionId}-${Date.now().toString(36)}-${nextElements.length}`
        const skeleton = buildSessionEmbeddable(session, pos.x, pos.y, id)
        const [built] = convertToExcalidrawElements([skeleton] as any, {
          regenerateIds: false,
        })
        if (!built) throw new Error(`Could not create session card: ${op.sessionId.slice(0, 8)}`)
        const sized = applyStoredSessionSize(built as ExcalidrawElement, nextLayout[op.sessionId])
        nextLayout = { ...nextLayout, [op.sessionId]: sessionLayoutFromRect(sized) }
        sessionLayoutChanged = true
        nextElements = [...nextElements, sized]
      }
      const addTextNote = (op: Extract<CanvasPatchOperation, { type: 'add_note' }>) => {
        const id = `canvas-note-${Date.now().toString(36)}-${nextElements.length}`
        const [built] = convertToExcalidrawElements([{
          id,
          type: 'text',
          x: op.x,
          y: op.y,
          text: op.text,
          originalText: op.text,
          fontSize: 20,
          fontFamily: 1,
          textAlign: 'left',
          verticalAlign: 'top',
          strokeColor: '#E5E7EB',
          backgroundColor: 'transparent',
          customData: { meee2Kind: 'note' },
        }] as any, { regenerateIds: false })
        if (!built) throw new Error('Could not create note')
        nextElements = [...nextElements, built as ExcalidrawElement]
        userElementsChanged = true
      }
      const sessionRect = (sid: string): ExcalidrawElement => {
        requireSession(sid)
        const idx = visibleSessionRectIndex(sid)
        if (idx < 0) throw new Error(`Session card is hidden: ${sid.slice(0, 8)}`)
        return nextElements[idx]
      }
      const elementBounds = (el: ExcalidrawElement) => ({
        x: el.x,
        y: el.y,
        width: Math.max((el as any).width ?? RECT_W, 1),
        height: Math.max((el as any).height ?? RECT_H, 1),
      })
      const boundsForSessions = (sessionIds: string[], padding: number) => {
        if (sessionIds.length === 0) throw new Error('add_frame requires sessionIds or explicit bounds')
        const rects = sessionIds.map((sid) => elementBounds(sessionRect(sid)))
        const minX = Math.min(...rects.map((r) => r.x))
        const minY = Math.min(...rects.map((r) => r.y))
        const maxX = Math.max(...rects.map((r) => r.x + r.width))
        const maxY = Math.max(...rects.map((r) => r.y + r.height))
        return {
          x: Math.round(minX - padding),
          y: Math.round(minY - padding),
          width: Math.round(maxX - minX + padding * 2),
          height: Math.round(maxY - minY + padding * 2),
        }
      }
      const buildText = (
        text: string,
        x: number,
        y: number,
        customData: Record<string, unknown>,
        fontSize = 18,
        elementId?: string,
      ) => {
        const requestedId = elementId || `relation-label-${Date.now().toString(36)}-${nextElements.length}`
        const built = convertToExcalidrawElements([{
          id: requestedId,
          type: 'text',
          x,
          y,
          text,
          originalText: text,
          fontSize,
          fontFamily: 1,
          textAlign: 'left',
          verticalAlign: 'top',
          strokeColor: '#E5E7EB',
          backgroundColor: 'transparent',
          customData,
        }] as any, { regenerateIds: false })[0] as ExcalidrawElement | undefined
        if (built) elementAliases.set(requestedId, built.id)
        return built
      }
      const elementById = (id: string | undefined): ExcalidrawElement | null => {
        if (!id) return null
        const resolvedId = elementAliases.get(id) ?? id
        return nextElements.find((el) => el.id === resolvedId && !(el as any).isDeleted) ?? null
      }
      const addFrame = (op: Extract<CanvasPatchOperation, { type: 'add_frame' }>) => {
        const style = relationStyle(op.stylePreset)
        const padding = typeof op.padding === 'number' ? op.padding : 36
        const bounds = Array.isArray(op.sessionIds) && op.sessionIds.length > 0
          ? boundsForSessions(op.sessionIds, padding)
          : {
              x: typeof op.x === 'number' ? op.x : viewportCenter().x - 260,
              y: typeof op.y === 'number' ? op.y : viewportCenter().y - 180,
              width: typeof op.width === 'number' ? op.width : 520,
              height: typeof op.height === 'number' ? op.height : 360,
            }
        const id = op.elementId || `relation-frame-${Date.now().toString(36)}-${nextElements.length}`
        const [built] = convertToExcalidrawElements([{
          id,
          type: 'frame',
          x: bounds.x,
          y: bounds.y,
          width: Math.max(bounds.width, 120),
          height: Math.max(bounds.height, 90),
          name: op.title || 'Group',
          children: [],
          strokeColor: style.strokeColor,
          backgroundColor: style.backgroundColor,
          fillStyle: 'solid',
          strokeWidth: style.strokeWidth,
          strokeStyle: style.strokeStyle,
          roundness: null,
          locked: false,
          groupIds: [],
          opacity: 100,
          customData: relationCustomData('relationFrame', {
            stylePreset: relationStylePreset(op.stylePreset),
            sessionIds: op.sessionIds ?? [],
          }),
        }] as any, { regenerateIds: false })
        if (!built) throw new Error('Could not create frame')
        elementAliases.set(id, built.id)
        nextElements = [...nextElements, built as ExcalidrawElement]
        userElementsChanged = true
      }
      const centerOf = (el: ExcalidrawElement) => {
        const b = elementBounds(el)
        return { x: b.x + b.width / 2, y: b.y + b.height / 2 }
      }
      const addConnector = (op: Extract<CanvasPatchOperation, { type: 'add_connector' }>) => {
        const from = op.fromSessionId
          ? sessionRect(op.fromSessionId)
          : elementById(op.fromElementId)
        const to = op.toSessionId
          ? sessionRect(op.toSessionId)
          : elementById(op.toElementId)
        if (!from || !to) throw new Error('add_connector requires existing from/to endpoints')
        const style = relationStyle(op.stylePreset)
        const a = centerOf(from)
        const b = centerOf(to)
        const id = `relation-connector-${Date.now().toString(36)}-${nextElements.length}`
        const direction = op.direction ?? 'forward'
        const [built] = convertToExcalidrawElements([{
          id,
          type: 'arrow',
          x: a.x,
          y: a.y,
          points: [[0, 0], [Math.round(b.x - a.x), Math.round(b.y - a.y)]],
          strokeColor: style.strokeColor,
          backgroundColor: 'transparent',
          strokeWidth: style.strokeWidth,
          strokeStyle: style.strokeStyle,
          startArrowhead: direction === 'backward' ? 'arrow' : null,
          endArrowhead: direction === 'none' || direction === 'backward' ? null : 'arrow',
          startBinding: { elementId: from.id, focus: 0, gap: 8 },
          endBinding: { elementId: to.id, focus: 0, gap: 8 },
          roundness: { type: 2 },
          customData: relationCustomData('relationConnector', {
            stylePreset: relationStylePreset(op.stylePreset),
            fromSessionId: op.fromSessionId,
            toSessionId: op.toSessionId,
            label: op.label,
          }),
        }] as any, { regenerateIds: false })
        if (!built) throw new Error('Could not create connector')
        nextElements = [...nextElements, built as ExcalidrawElement]
        if (op.label && op.label.trim()) {
          const label = buildText(op.label.trim(), Math.round((a.x + b.x) / 2 + 8), Math.round((a.y + b.y) / 2 - 12), relationCustomData('relationLabel', { connectorId: id }), 14)
          if (label) nextElements = [...nextElements, label]
        }
        userElementsChanged = true
      }
      const addShape = (op: Extract<CanvasPatchOperation, { type: 'add_shape' }>) => {
        const style = relationStyle(op.stylePreset)
        const id = op.elementId || `relation-shape-${Date.now().toString(36)}-${nextElements.length}`
        const width = Math.max(op.width ?? 180, 48)
        const height = Math.max(op.height ?? 96, 36)
        const [built] = convertToExcalidrawElements([{
          id,
          type: op.shape,
          x: op.x,
          y: op.y,
          width,
          height,
          strokeColor: style.strokeColor,
          backgroundColor: style.backgroundColor,
          fillStyle: 'solid',
          strokeWidth: style.strokeWidth,
          strokeStyle: style.strokeStyle,
          roughness: 0,
          roundness: op.shape === 'rectangle' ? { type: 3 } : null,
          customData: relationCustomData('relationShape', { stylePreset: relationStylePreset(op.stylePreset) }),
        }] as any, { regenerateIds: false })
        if (!built) throw new Error('Could not create shape')
        elementAliases.set(id, built.id)
        nextElements = [...nextElements, built as ExcalidrawElement]
        if (op.text && op.text.trim()) {
          const label = buildText(op.text.trim(), op.x + 14, op.y + Math.max(12, height / 2 - 10), relationCustomData('relationLabel', { shapeId: id }), 16)
          if (label) nextElements = [...nextElements, label]
        }
        userElementsChanged = true
      }
      const addLabel = (op: Extract<CanvasPatchOperation, { type: 'add_label' }>) => {
        const built = buildText(op.text, op.x, op.y, relationCustomData('relationLabel', { stylePreset: relationStylePreset(op.stylePreset) }), 16, op.elementId)
        if (!built) throw new Error('Could not create label')
        nextElements = [...nextElements, built]
        userElementsChanged = true
      }
      const updateElement = (op: Extract<CanvasPatchOperation, { type: 'update_element' }>) => {
        let found = false
        nextElements = nextElements.map((el) => {
          if (el.id !== op.elementId || (el as any).isDeleted) return el
          if (!isAssistantRelationElement(el)) throw new Error(`Element is not assistant-created: ${op.elementId.slice(0, 8)}`)
          found = true
          const text = typeof op.text === 'string' && el.type === 'text' ? op.text : (el as any).text
          const style = op.stylePreset ? relationStyle(op.stylePreset) : null
          return {
            ...el,
            x: typeof op.x === 'number' ? op.x : el.x,
            y: typeof op.y === 'number' ? op.y : el.y,
            width: typeof op.width === 'number' ? op.width : (el as any).width,
            height: typeof op.height === 'number' ? op.height : (el as any).height,
            text,
            originalText: text,
            ...(style ? {
              strokeColor: style.strokeColor,
              backgroundColor: style.backgroundColor,
              strokeStyle: style.strokeStyle,
              strokeWidth: style.strokeWidth,
            } : {}),
          } as ExcalidrawElement
        })
        if (!found) throw new Error(`Element not found: ${op.elementId.slice(0, 8)}`)
        userElementsChanged = true
      }

      for (const op of proposal.operations) {
        switch (op.type) {
          case 'move_session': {
            requireSession(op.sessionId)
            const idx = visibleSessionRectIndex(op.sessionId)
            if (idx < 0) throw new Error(`Session card is hidden: ${op.sessionId.slice(0, 8)}`)
            nextElements = nextElements.map((el, i) =>
              i === idx ? ({ ...el, x: op.x, y: op.y } as ExcalidrawElement) : el,
            )
            const moved = nextElements[idx]
            nextLayout = {
              ...nextLayout,
              [op.sessionId]: moved ? sessionLayoutFromRect(moved) : { x: op.x, y: op.y },
            }
            sessionLayoutChanged = true
            break
          }
          case 'move_channel': {
            requireChannel(op.channelName)
            let moved = false
            nextElements = nextElements.map((el) => {
              const name = parseChannelFromElement(el)
              if (name !== op.channelName) return el
              if ((el as any).isDeleted) return el
              if ((el as any).type !== 'frame' && el.type !== 'ellipse') return el
              moved = true
              return { ...el, x: op.x, y: op.y } as ExcalidrawElement
            })
            if (!moved) throw new Error(`Channel frame is hidden: ${op.channelName}`)
            nextChannelLayout = { ...nextChannelLayout, [op.channelName]: { x: op.x, y: op.y } }
            channelLayoutChanged = true
            break
          }
          case 'show_session': {
            requireSession(op.sessionId)
            const pos = sessionPosition(op.sessionId, op)
            const visibleIdx = visibleSessionRectIndex(op.sessionId)
            if (visibleIdx >= 0) {
              nextElements = nextElements.map((el, i) =>
                i === visibleIdx ? ({ ...el, x: pos.x, y: pos.y } as ExcalidrawElement) : el,
              )
            } else {
              const deletedIdx = deletedSessionRectIndex(op.sessionId)
              if (deletedIdx >= 0) {
                nextElements = nextElements.map((el, i) =>
                  i === deletedIdx ? ({ ...el, isDeleted: false, x: pos.x, y: pos.y } as ExcalidrawElement) : el,
                )
              } else {
                createSessionRect(op)
              }
            }
            const visibleIdxAfter = visibleSessionRectIndex(op.sessionId)
            const visibleRect = visibleIdxAfter >= 0 ? nextElements[visibleIdxAfter] : null
            nextLayout = {
              ...nextLayout,
              [op.sessionId]: visibleRect ? sessionLayoutFromRect(visibleRect) : {
                x: pos.x,
                y: pos.y,
                width: nextLayout[op.sessionId]?.width,
                height: nextLayout[op.sessionId]?.height,
              },
            }
            sessionLayoutChanged = true
            if (dismissedRef.current.delete(op.sessionId)) dismissedChanged = true
            membershipOps.push(addSessionToCanvas(proposal.canvasId, op.sessionId))
            break
          }
          case 'hide_session': {
            requireSession(op.sessionId)
            nextElements = nextElements.map((el) => {
              if (el.type !== 'rectangle') return el
              if (parseSessionFromElement(el) !== op.sessionId) return el
              if ((el as any).isDeleted) return el
              return { ...el, isDeleted: true } as ExcalidrawElement
            })
            if (!dismissedRef.current.has(op.sessionId)) {
              dismissedRef.current.add(op.sessionId)
              dismissedChanged = true
            }
            const { [op.sessionId]: _removed, ...restLayout } = nextLayout
            nextLayout = restLayout
            sessionLayoutChanged = true
            membershipOps.push(removeSessionFromCanvas(proposal.canvasId, op.sessionId))
            break
          }
          case 'add_note': {
            addTextNote(op)
            break
          }
          case 'update_note': {
            let found = false
            nextElements = nextElements.map((el) => {
              if (el.id !== op.elementId || el.type !== 'text' || (el as any).isDeleted) return el
              found = true
              const text = typeof op.text === 'string' ? op.text : (el as any).text
              return {
                ...el,
                x: typeof op.x === 'number' ? op.x : el.x,
                y: typeof op.y === 'number' ? op.y : el.y,
                text,
                originalText: text,
              } as ExcalidrawElement
            })
            if (!found) throw new Error(`Note not found: ${op.elementId.slice(0, 8)}`)
            userElementsChanged = true
            break
          }
          case 'add_frame': {
            addFrame(op)
            break
          }
          case 'add_connector': {
            addConnector(op)
            break
          }
          case 'add_shape': {
            addShape(op)
            break
          }
          case 'add_label': {
            addLabel(op)
            break
          }
          case 'update_element': {
            updateElement(op)
            break
          }
        }
      }

      api.updateScene({ elements: nextElements as any })
      setSceneRevision((x) => (x + 1) & 0x7fffffff)
      reportCountsRef.current(nextElements)
      if (sessionLayoutChanged) {
        layoutRef.current = nextLayout
        saveLayoutDebounced.cancel()
        persistenceOps.push(trackCanvasSave('session layout', () => persistence.saveSessionLayout(nextLayout)))
      }
      if (channelLayoutChanged) {
        channelLayoutRef.current = nextChannelLayout
        saveChannelLayoutDebounced.cancel()
        persistenceOps.push(trackCanvasSave('channel layout', () => persistence.saveChannelLayout(nextChannelLayout)))
      }
      if (dismissedChanged) {
        persistenceOps.push(trackCanvasSave('dismissed sessions', () => persistence.saveDismissed(dismissedRef.current)))
      }
      if (userElementsChanged) {
        saveShapesDebounced.cancel()
        persistenceOps.push(trackCanvasSave('user elements', () => persistence.saveUserElements(nextElements)))
      }

      Promise.all([...membershipOps, ...persistenceOps])
        .then(() => onCanvasPatchApplied({
          ok: true,
          message: `Applied ${proposal.operations.length} canvas change${proposal.operations.length === 1 ? '' : 's'}`,
        }))
        .catch((err) => onCanvasPatchApplied({
          ok: false,
          message: (err as Error).message || 'Canvas changed locally, but membership sync failed',
        }))
    } catch (err) {
      onCanvasPatchApplied({
        ok: false,
        message: (err as Error).message || 'Failed to apply canvas changes',
      })
    }
  }, [
    api,
    state,
    canvasPatchRequest,
    onCanvasPatchApplied,
    persistence,
    saveChannelLayoutDebounced,
    saveLayoutDebounced,
    saveShapesDebounced,
    trackCanvasSave,
  ])

  // -- Multi-select all cards for the sidebar-selected session --------
  // When sidebar selects a session, highlight every rect on canvas with
  // that sessionId. Only runs when selection or state changes (not every
  // frame) to avoid fighting user's own click-selection.
  useEffect(() => {
    if (!api) return
    if (selection.kind !== 'session') return
    const sid = selection.sessionId
    const elements = api.getSceneElements()
    const matchIds: string[] = []
    for (const el of elements) {
      if (el.type !== 'rectangle') continue
      if ((el as any).isDeleted) continue
      if (parseSessionFromElement(el) !== sid) continue
      matchIds.push(el.id)
    }
    // console.log(
    //   '[SelectionTrace] push-back effect sid=%s matchIds=%o stateTick=%s',
    //   sid.slice(0, 8),
    //   matchIds,
    //   !!state,
    // )
    if (matchIds.length === 0) return
    const selected: Record<string, true> = {}
    for (const id of matchIds) selected[id] = true
    try {
      api.updateScene({
        appState: { selectedElementIds: selected } as any,
      })
    } catch (e) {
      console.warn('[Board] multi-select update failed', e)
    }
  }, [api, selection, state])

  // -- Pan board to the channel hub when sidebar selects a channel ----
  // The hub element may not exist on the very first state delivery; depending
  // on `state` re-runs the effect after the scene-rebuild adds the ellipse.
  // The helper itself is in @meee1/board-core so meee2 can wire the
  // identical effect against its own Sidebar selection.
  useEffect(() => {
    if (!api) return
    if (selection.kind !== 'channel') return
    panToChannelHub(api, selection.channelName)
  }, [api, selection, state])

  // -- onChange: capture movement + selection --------------------------
  const handleChange = useMemo(() => {
    return (elements: readonly ExcalidrawElement[], appState: AppState) => {
      if (!state) return
      if (canvasLoading) return

      const viewport = {
        scrollX: appState.scrollX ?? 0,
        scrollY: appState.scrollY ?? 0,
        zoom: appState.zoom?.value ?? 1,
      }
      const publishSnapshotIfNeeded = (
        snapshotElements: readonly ExcalidrawElement[],
        currentViewport: { scrollX: number; scrollY: number; zoom: number },
      ) => {
        const userElementsSig = persistedUserElementsSignature(snapshotElements)
        if (userElementsSig !== prevPersistedUserElementsSigRef.current) {
          prevPersistedUserElementsSigRef.current = userElementsSig
          saveShapesDebounced(snapshotElements)
        }

        const snapshotSig = [
          layoutMapSignature(layoutRef.current),
          layoutMapSignature(channelLayoutRef.current),
          viewportSignature(currentViewport),
          userElementsSig,
          [...dismissedRef.current].sort().join(','),
          [...unreadSids].sort().join(','),
        ].join('||')
        if (snapshotSig === prevSceneSnapshotSigRef.current) return
        prevSceneSnapshotSigRef.current = snapshotSig

        publishSceneSnapshotDebounced({
          canvasId,
          sessionLayout: { ...layoutRef.current },
          channelLayout: { ...channelLayoutRef.current },
          viewport: {
            scrollX: currentViewport.scrollX,
            scrollY: currentViewport.scrollY,
            zoom: currentViewport.zoom,
          },
          userElements: [...snapshotElements] as any[],
          dismissed: new Set(dismissedRef.current),
          unreadSids: new Set(unreadSids),
        })
      }
      const selIds = Object.keys(appState.selectedElementIds ?? {})
      const selSig = selIds.slice().sort().join(',')
      const selectionChanged = selSig !== prevSelSigRef.current
      const elementsSig = interactiveElementsSignature(elements)
      const elementsChanged = elementsSig !== prevInteractiveElementsSigRef.current
      prevInteractiveElementsSigRef.current = elementsSig

      // Pan / zoom floods onChange while scene elements stay untouched. Keep
      // viewport persistence, but skip the expensive scene diff, membership
      // reconciliation, counts, shape snapshots, and channel checks.
      if (!elementsChanged && !selectionChanged) {
        saveAppStateDebounced(viewport)
        publishSnapshotIfNeeded(elements, viewport)
        return
      }

      const singleCardScene = enforceSingleSessionCard(elements)
      if (singleCardScene.changed && api) {
        api.updateScene({ elements: singleCardScene.elements as any })
        setSceneRevision((x) => (x + 1) & 0x7fffffff)
        reportCountsRef.current(singleCardScene.elements)
        return
      }

      let elementsForPersistence: readonly ExcalidrawElement[] = elements

      // -- Double-click → activate (terminal jump) --------------------------
      // Excalidraw sets `appState.activeEmbeddable` when the user double-clicks
      // an embeddable. We never actually want an "active" embeddable (we don't
      // render a native iframe), so we use that signal purely as an activation
      // gesture: call activateSession for the mapped sid and then clear the
      // active state on the next tick so the user can activate the same card
      // again.
      const active = (appState as any).activeEmbeddable as
        | { element: { id: string }; state: string }
        | null
        | undefined
      if (
        active &&
        active.state === 'active' &&
        active.element &&
        active.element.id !== lastActivatedElementIdRef.current
      ) {
        const activeElId = active.element.id
        const el = elements.find((e) => e.id === activeElId)
        const sid = el ? parseSessionFromElement(el) : null
        if (sid) {
          lastActivatedElementIdRef.current = activeElId
          // console.log('[Board] activateSession via embeddable double-click', sid.slice(0, 8))
          void activateSession(sid)
          // Clear active state so the same card can be re-activated, and so
          // Excalidraw doesn't keep a no-op "activated" embeddable in memory.
          setTimeout(() => {
            if (!api) return
            try {
              api.updateScene({
                appState: { activeEmbeddable: null } as any,
              })
            } catch (e) {
              console.warn('[Board] clear activeEmbeddable failed', e)
            }
            lastActivatedElementIdRef.current = null
          }, 50)
        }
      } else if (!active || active.state !== 'active') {
        lastActivatedElementIdRef.current = null
      }

      // selection tracking — sidebar shows:
      //   • 1 rect of single session (or N rects all same session) → session detail
      //   • 1 channel arrow                                         → channel detail
      //   • 0 rects, or rects spanning 2+ sessions, or any mix     → session list
      //
      // We guard with a signature ref so WS ticks that don't actually change
      // the selection don't thrash the sidebar (see prevSelSigRef init).
      if (selectionChanged) {
        prevSelSigRef.current = selSig
        onSelectedElementsContextChange(selectedElementsContext(elements, selIds, state))

        // Classify selection
        const uniqueSids = new Set<string>()
        let channelName: string | null = null
        let hasNonSessionNonChannel = false
        for (const id of selIds) {
          const el = elements.find((e) => e.id === id)
          if (!el) continue
          if (el.type === 'rectangle') {
            const sid = parseSessionFromElement(el)
            if (sid) {
              uniqueSids.add(sid)
              continue
            }
          }
          if (el.type === 'ellipse') {
            const name = parseChannelFromElement(el)
            if (name) {
              channelName = channelName ?? name
              continue
            }
          }
          if (el.id.startsWith('channel-')) {
            const ch = resolveChannelFromElementId(el.id, state.channels)
            if (ch) {
              channelName = channelName ?? ch.name
              continue
            }
          }
          hasNonSessionNonChannel = true
        }

        let next: Selection = { kind: 'none' }
        if (
          !hasNonSessionNonChannel &&
          channelName === null &&
          uniqueSids.size === 1
        ) {
          const [sid] = [...uniqueSids]
          next = { kind: 'session', sessionId: sid }
        } else if (
          !hasNonSessionNonChannel &&
          uniqueSids.size === 0 &&
          channelName !== null &&
          selIds.length === 1
        ) {
          next = { kind: 'channel', channelName }
        }

        const cur = selection
        const same =
          (cur.kind === 'none' && next.kind === 'none') ||
          (cur.kind === 'session' && next.kind === 'session' && cur.sessionId === next.sessionId) ||
          (cur.kind === 'channel' && next.kind === 'channel' && cur.channelName === next.channelName)
        // console.log(
        //   '[SelectionTrace] onChange selIds=%s selSig=%s cur=%o next=%o same=%s',
        //   selIds.length,
        //   selSig || '(empty)',
        //   cur,
        //   next,
        //   same,
        // )
        if (!same) {
          // console.log('[SelectionTrace] → firing onSelectionChange to', next)
          onSelectionChange(next)
        }
      }

      // 隐藏 Excalidraw 的 "选中样式面板" 仅当只选了我们托管的 session/channel
      // 元素（embeddable/channel-*）——不影响用户选自己 shape 的情况。
      const onlyManaged =
        selIds.length > 0 &&
        selIds.every((id) => {
          const el = elements.find((e) => e.id === id)
          if (!el) return false
          if (el.type === 'rectangle' && parseSessionFromElement(el)) {
            return true
          }
          return id.startsWith('channel-')
        })
      const host = document.querySelector('.excalidraw')
      if (host) {
        host.classList.toggle('board--hide-shape-actions', onlyManaged)
      }

      if (!elementsChanged) {
        saveAppStateDebounced(viewport)
        publishSnapshotIfNeeded(elements, viewport)
        return
      }

      // Movement tracking. For layout persistence we save position *per
      // session id*, keyed to the first embeddable we see for that sid.
      //
      // 之前靠 `appState.draggingElement` 触发 —— 这个字段在新版 Excalidraw
      // 里常为 undefined，导致 drag 结束后根本没 trigger 保存，位置刷新即丢。
      // 改成：每次 onChange 里都 diff 对比 layoutRef，发现 x/y 变了就 save。
      // debounce 400ms 会把连续拖动合并掉。
      {
        let changed = false
        const next: LayoutMap = { ...layoutRef.current }
        // First rect per session → canonical position.
        const seen = new Set<string>()
        for (const el of elements) {
          if (el.type !== 'rectangle') continue
          if ((el as any).isDeleted) continue
          const sid = parseSessionFromElement(el)
          if (!sid || seen.has(sid)) continue
          if (!currentCanvasSessionIdsRef.current.has(sid)) continue
          seen.add(sid)
          const prev = next[sid]
          const current = sessionLayoutFromRect(el)
          if (
            !prev ||
            prev.x !== current.x ||
            prev.y !== current.y ||
            prev.width !== current.width ||
            prev.height !== current.height
          ) {
            next[sid] = current
            changed = true
          }
        }
        if (changed) {
          layoutRef.current = next
          saveLayoutDebounced(next)
        }
      }
      // Same diff-and-save pattern for channel hubs (ellipses with
      // customData.channelName). Keeps hub positions sticky across reloads
      // just like session cards.
      {
        let changed = false
        const next: LayoutMap = { ...channelLayoutRef.current }
        for (const el of elements) {
          if (el.type !== 'ellipse') continue
          if ((el as any).isDeleted) continue
          const name = parseChannelFromElement(el)
          if (!name) continue
          const prev = next[name]
          if (!prev || prev.x !== el.x || prev.y !== el.y) {
            next[name] = { x: el.x, y: el.y }
            changed = true
          }
        }
        if (changed) {
          channelLayoutRef.current = next
          saveChannelLayoutDebounced(next)
        }
      }
      // -- Frame channel membership via Excalidraw frameId --------------
      // Excalidraw assigns frameId on every element when its bbox lands
      // inside a frame's bbox (drag-into-frame gesture). We treat that as
      // an addMember; frameId becoming null (drag-out) as removeMember.
      // Per the user's spec each session card belongs to at most ONE frame
      // channel: if a session has multiple rects spread across different
      // frames, the lexically smallest channel name wins so the choice is
      // deterministic.
      {
        const frameSig = frameMembershipSignature(elements)
        const frameMembershipChanged = frameSig !== prevFrameMembershipSigRef.current
        prevFrameMembershipSigRef.current = frameSig
        if (!frameMembershipChanged) {
          // Plain card moves update layout above; membership only matters when
          // frameId/frame structure changes.
        } else {
        const channelNamesLocal = state.channels
          .map((c) => c.name)
          .filter((n) => !n.startsWith('__') && !isDmChannelName(n))
        const frameChannelByFrameId = new Map<string, string>()
        for (const el of elements) {
          if ((el as any).type !== 'frame' || (el as any).isDeleted) continue
          const name = parseChannelFromElement(el)
          if (name && channelNamesLocal.includes(name)) {
            frameChannelByFrameId.set(el.id, name)
          }
        }
        // sid -> channel currently expressed by frameId on at least one rect
        const desiredFrameMembership = new Map<string, string>()
        for (const el of elements) {
          if (el.type !== 'rectangle' || (el as any).isDeleted) continue
          const sid = parseSessionFromElement(el)
          if (!sid) continue
          const fid = (el as any).frameId as string | null | undefined
          const channel = fid ? frameChannelByFrameId.get(fid) : null
          if (!channel) continue
          const prior = desiredFrameMembership.get(sid)
          if (!prior || channel < prior) desiredFrameMembership.set(sid, channel)
        }
        // Diff against state: each session has at most one frame-channel
        // membership in our world. Channels not in desired -> leave; new
        // -> join.
        const currentFrameMembership = new Map<string, string>()
        for (const ch of state.channels) {
          if (ch.name.startsWith('__')) continue
          if (isDmChannelName(ch.name)) continue
          for (const m of ch.members) {
            currentFrameMembership.set(m.sessionId, ch.name)
          }
        }
        const allSids = new Set<string>([
          ...desiredFrameMembership.keys(),
          ...currentFrameMembership.keys(),
        ])
        for (const sid of allSids) {
          const want = desiredFrameMembership.get(sid) ?? null
          const have = currentFrameMembership.get(sid) ?? null
          if (want === have) continue
          const session = state.sessions.find((s) => s.id === sid)
          const alias = session ? aliasFromSession(session.title, session.id) : null
          if (!alias) continue
          if (have && have !== want) {
            const opKey = `leave|${have}|${sid}`
            if (!pendingFrameOpsRef.current.has(opKey)) {
              pendingFrameOpsRef.current.add(opKey)
              const ch = state.channels.find((c) => c.name === have)
              const aliases = ch
                ? ch.members.filter((m) => m.sessionId === sid).map((m) => m.alias)
                : [alias]
              // console.log('[Board.frame] removeMember', { channel: have, sid, aliases })
              void Promise.all(aliases.map((a) => removeMember(have, a)))
                .then(() => {
                  pendingFrameOpsRef.current.delete(opKey)
                  onRefresh()
                })
                .catch((e) => {
                  pendingFrameOpsRef.current.delete(opKey)
                  console.warn('[Board.frame] removeMember failed:', (e as Error).message)
                })
            }
          }
          if (want && want !== have) {
            const opKey = `join|${want}|${sid}`
            if (!pendingFrameOpsRef.current.has(opKey)) {
              pendingFrameOpsRef.current.add(opKey)
              // console.log('[Board.frame] addMember', { channel: want, sid, alias })
              void addMember(want, alias, sid)
                .then(() => {
                  pendingFrameOpsRef.current.delete(opKey)
                  onRefresh()
                })
                .catch((e) => {
                  pendingFrameOpsRef.current.delete(opKey)
                  console.warn('[Board.frame] addMember failed:', (e as Error).message)
                })
            }
          }
        }
        knownFrameMembershipsRef.current = desiredFrameMembership
        }
      }

      // -- DM channel via card-to-card arrow ------------------------------
      // Detect every user-drawn arrow whose start AND end bind to session
      // rects -> ensure a `dm-<a>-<b>` channel exists with those two
      // members. When the arrow is deleted, delete the channel.
      {
        const dmSig = dmStructureSignature(elements)
        const dmStructureChanged = dmSig !== prevDmStructureSigRef.current
        prevDmStructureSigRef.current = dmSig
        if (!dmStructureChanged) {
          // Card position changes do not alter DM membership. Bound arrows can
          // move visually without changing their start/end binding ids.
        } else {
        const elementsByIdLocal = new Map(elements.map((el) => [el.id, el]))
        const sessionIdsLocal = state.sessions.map((s) => s.id)
        const presentDmChannels = new Map<string, { sidA: string; sidB: string }>()
        const dmAnnotations = new Map<string, DmMeta>()
        for (const el of elements) {
          if (el.type !== 'arrow' || (el as any).isDeleted) continue
          const dm = classifyDmArrow(el, elementsByIdLocal, sessionIdsLocal)
          if (!dm) continue
          const channel = dmChannelName(dm.sidA, dm.sidB)
          presentDmChannels.set(channel, dm)
          dmAnnotations.set(el.id, { channel, sidA: dm.sidA, sidB: dm.sidB })
        }

        if (dmAnnotations.size > 0) {
          elementsForPersistence = elements.map((el) => {
            if (el.type !== 'arrow') return el
            const meta = dmAnnotations.get(el.id)
            return meta ? withDmMeta(el, meta) : el
          }) as readonly ExcalidrawElement[]
        }

        const stateDmChannels = new Set<string>(
          state.channels.filter((c) => isDmChannelName(c.name)).map((c) => c.name),
        )

        // Additions: arrow exists on canvas but channel doesn't.
        for (const [channel, info] of presentDmChannels) {
          if (stateDmChannels.has(channel)) continue
          if (pendingDmOpsRef.current.has(channel)) continue
          const sessionA = state.sessions.find((s) => s.id === info.sidA)
          const sessionB = state.sessions.find((s) => s.id === info.sidB)
          if (!sessionA || !sessionB) continue
          const aliasA = aliasFromSession(sessionA.title, sessionA.id)
          const aliasB = aliasFromSession(sessionB.title, sessionB.id)
          pendingDmOpsRef.current.add(channel)
          // console.log('[Board.dm] createChannel', channel, info)
          void createChannel({ name: channel })
            .then(() =>
              Promise.all([
                addMember(channel, aliasA, info.sidA),
                addMember(channel, aliasB, info.sidB),
              ]),
            )
            .then(() => {
              pendingDmOpsRef.current.delete(channel)
              onRefresh()
            })
            .catch((e) => {
              pendingDmOpsRef.current.delete(channel)
              console.warn('[Board.dm] createChannel failed:', (e as Error).message)
            })
        }

        // Removals: channel exists but arrow gone.
        for (const channel of knownDmChannelsRef.current.keys()) {
          if (presentDmChannels.has(channel)) continue
          if (!stateDmChannels.has(channel)) continue
          if (pendingDmOpsRef.current.has(channel)) continue
          pendingDmOpsRef.current.add(channel)
          // console.log('[Board.dm] deleteChannel', channel)
          void deleteChannel(channel)
            .then(() => {
              pendingDmOpsRef.current.delete(channel)
              onRefresh()
            })
            .catch((e) => {
              pendingDmOpsRef.current.delete(channel)
              console.warn('[Board.dm] deleteChannel failed:', (e as Error).message)
            })
        }
        knownDmChannelsRef.current = presentDmChannels
        }
      }

      // -- 非-DM channel frames：用户在画板上删 frame ⇔ 删 channel ----
      // 与 DM 段对齐的逻辑：本 tick 看到的非-DM channel frame 名集合，对比
      // 上一 tick 的 known 集合 + 当前 state.channels。
      //   - frame 出现且 channel 也存在 → 不动（创建路径走 NewChannelDialog）
      //   - frame 消失但 channel 还在 → 用户按 Delete 删掉了 frame → 调
      //     deleteChannel 让 backend 同步删，否则下一次 scene 重建又冒回来
      {
        const presentChannelFrames = new Set<string>()
        for (const el of elements) {
          if ((el as any).type !== 'frame' || (el as any).isDeleted) continue
          const name = parseChannelFromElement(el)
          if (!name) continue
          if (isDmChannelName(name)) continue
          presentChannelFrames.add(name)
        }
        const stateChannelNames = new Set<string>(
          state.channels.filter((c) => !isDmChannelName(c.name)).map((c) => c.name),
        )
        for (const name of knownChannelFramesRef.current) {
          if (presentChannelFrames.has(name)) continue
          if (!stateChannelNames.has(name)) continue
          if (pendingDmOpsRef.current.has(name)) continue
          pendingDmOpsRef.current.add(name)
          // console.log('[Board.channelFrame] deleteChannel', name)
          void deleteChannel(name)
            .then(() => {
              pendingDmOpsRef.current.delete(name)
              onRefresh()
            })
            .catch((e) => {
              pendingDmOpsRef.current.delete(name)
              console.warn('[Board.channelFrame] deleteChannel failed:', (e as Error).message)
            })
        }
        knownChannelFramesRef.current = presentChannelFrames
      }

      // Report counts on every change so sidebar stays in sync with
      // copy/paste/delete performed natively by Excalidraw.
      {
        const countSig = sessionCountSignature(elements, currentCanvasSessionIdsRef.current)
        if (countSig !== prevCountSigRef.current) {
          prevCountSigRef.current = countSig
          reportCountsRef.current(elements)
        }
      }

      // 强制等比例缩放：session card 的 aspect ratio 锁成 RECT_W:RECT_H。
      // 用户拖任意 handle 时 Excalidraw 会允许宽高独立变，这里检测到比例偏离
      // 就把 width/height 纠正回来（以较大的那一维为准，让用户"拉大"的意图
      // 更直观）。feedback 循环由"发现已经对就不更新"天然避免。
      const RATIO = RECT_W / RECT_H
      let aspectNeedsFix = false
      const fixedElements = elements.map((el) => {
        if (el.type !== 'rectangle') return el
        if (!parseSessionFromElement(el)) return el
        const w = el.width
        const h = el.height
        if (!w || !h) return el
        const actual = w / h
        if (Math.abs(actual - RATIO) < 0.01) return el // 已经比例正确
        aspectNeedsFix = true
        // 以较大的那一维为基准
        const newW = Math.max(w, h * RATIO)
        const newH = newW / RATIO
        return { ...el, width: newW, height: newH } as ExcalidrawElement
      })
      if (aspectNeedsFix && api) {
        try {
          api.updateScene({ elements: fixedElements as any })
          setSceneRevision((x) => (x + 1) & 0x7fffffff)
        } catch (e) {
          console.warn('[Board] aspect-ratio clamp updateScene failed', e)
        }
      }

      // 持久化 viewport + 用户画的非 session 元素
      saveAppStateDebounced({
        scrollX: viewport.scrollX,
        scrollY: viewport.scrollY,
        zoom: viewport.zoom,
      })
      const snapshotElements = aspectNeedsFix ? fixedElements : elementsForPersistence
      publishSnapshotIfNeeded(snapshotElements, viewport)
    }
  }, [state, canvasId, canvasLoading, selection, onSelectionChange, onSelectedElementsContextChange, saveLayoutDebounced, saveChannelLayoutDebounced, api, saveAppStateDebounced, saveShapesDebounced, publishSceneSnapshotDebounced, unreadSids, onRefresh])

  // -- Minimal UI options --------------------------------------------
  const uiOptions = useMemo(
    () => ({
      canvasActions: {
        loadScene: false,
        saveToActiveFile: false,
        export: false,
        toggleTheme: false,
        clearCanvas: false,
        changeViewBackgroundColor: false,
      },
      tools: { image: false },
    }),
    [],
  )

  const arrangeCurrentCanvasSessions = () => {
    if (!api || !state) return
    const currentIds = new Set(currentCanvasSessionIds)
    const sessionOrder = new Map(
      sortSessionsForCanvas(state.sessions, currentIds).map((session, index) => [session.id, index]),
    )
    const elements = api.getSceneElements()
    const sessionRects = elements
      .filter((el) => {
        if (el.type !== 'rectangle') return false
        if ((el as any).isDeleted) return false
        const sid = parseSessionFromElement(el)
        return Boolean(sid && currentIds.has(sid))
      })
      .sort((a, b) => {
        const sidA = parseSessionFromElement(a) ?? ''
        const sidB = parseSessionFromElement(b) ?? ''
        const orderA = sessionOrder.get(sidA) ?? Number.MAX_SAFE_INTEGER
        const orderB = sessionOrder.get(sidB) ?? Number.MAX_SAFE_INTEGER
        return orderA - orderB || a.y - b.y || a.x - b.x
      })

    if (sessionRects.length === 0) {
      setArrangeConfirmOpen(false)
      return
    }

    const origin = originFromRectsOrViewport(sessionRects, api)
    const positionByElementId = new Map(
      sessionRects.map((el, index) => [el.id, gridPointAt(origin, index)]),
    )
    const firstSeenForSession = new Set<string>()
    const nextLayout: LayoutMap = { ...layoutRef.current }
    const next = elements.map((el) => {
      const point = positionByElementId.get(el.id)
      if (!point) return el
      const sid = parseSessionFromElement(el)
      if (sid && !firstSeenForSession.has(sid)) {
        firstSeenForSession.add(sid)
        nextLayout[sid] = {
          ...sessionLayoutFromRect(el),
          x: point.x,
          y: point.y,
        }
      }
      return { ...el, x: point.x, y: point.y }
    })

    layoutRef.current = nextLayout
    saveLayoutDebounced.cancel()
    trackCanvasSave('arranged session layout', async () => {
      await persistence.saveSessionLayout(nextLayout)
      await persistence.flushPendingWrites?.()
    })
    api.updateScene({ elements: next as any })
    setSceneRevision((x) => (x + 1) & 0x7fffffff)
    reportCountsRef.current(next)
    requestAnimationFrame(() => {
      api.scrollToContent(sessionRects.map((el) => ({
        ...el,
        ...(positionByElementId.get(el.id) ?? {}),
      })) as any, { fitToContent: true, animate: true })
    })
    setArrangeConfirmOpen(false)
  }

  const handleSessionOverlayPointerDown = useCallback((
    event: ReactPointerEvent<HTMLDivElement>,
    elementId: string,
    sessionId: string,
  ) => {
    if (!api || !state) return
    if (event.button !== 0) return
    const startElements = api.getSceneElements()
    const startEl = startElements.find((el) => el.id === elementId)
    if (!startEl || startEl.type !== 'rectangle' || parseSessionFromElement(startEl) !== sessionId) return

    event.preventDefault()
    event.stopPropagation()
    try {
      event.currentTarget.setPointerCapture(event.pointerId)
    } catch {
      // Window-level listeners below are the durable capture path.
    }

    onSelectionChange({ kind: 'session', sessionId })
    onSelectedElementsContextChange(selectedElementsContext(startElements, [elementId], state))
    api.updateScene({
      appState: {
        selectedElementIds: { [elementId]: true },
      } as any,
    })

    const startClientX = event.clientX
    const startClientY = event.clientY
    const startX = startEl.x
    const startY = startEl.y
    const zoom = api.getAppState().zoom?.value || 1
    let moved = false
    let latest: PointerEvent | null = null
    let raf: number | null = null

    const applyMove = () => {
      raf = null
      if (!latest) return
      const dx = (latest.clientX - startClientX) / zoom
      const dy = (latest.clientY - startClientY) / zoom
      if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) return
      moved = true
      const nextX = startX + dx
      const nextY = startY + dy
      let updated: ExcalidrawElement | null = null
      const nextElements = api.getSceneElements().map((el) => {
        if (el.id !== elementId) return el
        updated = { ...el, x: nextX, y: nextY } as ExcalidrawElement
        return updated
      })
      if (!updated) return
      layoutRef.current = {
        ...layoutRef.current,
        [sessionId]: sessionLayoutFromRect(updated),
      }
      saveLayoutDebounced(layoutRef.current)
      api.updateScene({
        elements: nextElements as any,
        appState: {
          selectedElementIds: { [elementId]: true },
        } as any,
      })
      setSceneRevision((x) => (x + 1) & 0x7fffffff)
    }

    const applyPendingMoveNow = () => {
      if (raf !== null) {
        window.cancelAnimationFrame(raf)
        raf = null
      }
      applyMove()
    }
    const cleanup = () => {
      window.removeEventListener('pointermove', onMove, true)
      window.removeEventListener('pointerup', onUp, true)
      window.removeEventListener('pointercancel', onCancel, true)
      if (raf !== null) {
        window.cancelAnimationFrame(raf)
        raf = null
      }
    }
    const flushMove = () => {
      if (!moved) return
      saveLayoutDebounced.flush()
      void persistence.flushPendingWrites?.()
    }
    const onMove = (moveEvent: PointerEvent) => {
      latest = moveEvent
      if (raf !== null) return
      raf = window.requestAnimationFrame(applyMove)
    }
    const onUp = (upEvent: PointerEvent) => {
      latest = upEvent
      applyPendingMoveNow()
      cleanup()
      flushMove()
    }
    const onCancel = (cancelEvent: PointerEvent) => {
      latest = cancelEvent
      applyPendingMoveNow()
      cleanup()
      flushMove()
    }

    window.addEventListener('pointermove', onMove, true)
    window.addEventListener('pointerup', onUp, true)
    window.addEventListener('pointercancel', onCancel, true)
  }, [
    api,
    onSelectedElementsContextChange,
    onSelectionChange,
    persistence,
    saveLayoutDebounced,
    state,
  ])

  // -- renderEmbeddable: Wave 18 — the real card is rendered by
  // `<SessionOverlay>` (a sibling overlay div). We still need to pass
  // `renderEmbeddable` so Excalidraw doesn't attempt its default link-fetch
  // iframe behavior. Returning `null` keeps the embeddable in the scene
  // (for selection/copy/delete/library) but paints nothing in the hidden
  // native container.
  const renderEmbeddable = useMemo(
    () => (_element: unknown, _appState: AppState) => null,
    [],
  )

  const selectedCoordinationSessionId = selection.kind === 'session' ? selection.sessionId : ''
  const selectedCoordinationGroup = selectedCoordinationSessionId && state
    ? state.coordinationGroups.find((group) =>
        group.coordinatorSessionId === selectedCoordinationSessionId ||
        group.memberSessionIds.includes(selectedCoordinationSessionId),
      )
    : undefined

  return (
    <div style={{ width: '100%', height: '100%', position: 'relative' }}>
      <Excalidraw
        theme="dark"
        initialData={initialDataRef.current as any}
        excalidrawAPI={(a) => setApi(a)}
        onChange={handleChange}
        UIOptions={uiOptions as any}
        viewModeEnabled={false}
        gridModeEnabled={gridModeEnabled}
      >
        <MainMenu>
          <MainMenu.Item onSelect={onAskAndSpawn} icon={<TerminalIcon />}>
            Ask AI to spawn…
          </MainMenu.Item>
          <MainMenu.Item onSelect={onPreferences} icon={<PlusSquareIcon />}>
            Board Settings…
          </MainMenu.Item>
          <MainMenu.Item onSelect={onNewChannel} icon={<PlusSquareIcon />}>
            New channel
          </MainMenu.Item>
          <MainMenu.Item onSelect={onFit} icon={<FitIcon />}>
            Fit to content
          </MainMenu.Item>
          <MainMenu.Item onSelect={() => setArrangeConfirmOpen(true)} icon={<GridIcon />}>
            Arrange sessions
          </MainMenu.Item>
          <MainMenu.Item onSelect={onRefresh} icon={<RefreshIcon />}>
            Refresh
          </MainMenu.Item>
          <MainMenu.Separator />
          <MainMenu.ItemLink
            href="https://two.meee1.com"
            icon={<ExternalLinkIcon />}
          >
            meee2 homepage
          </MainMenu.ItemLink>
          <MainMenu.ItemLink
            href="https://github.com/meee1/meee2"
            icon={<ExternalLinkIcon />}
          >
            GitHub
          </MainMenu.ItemLink>
          <MainMenu.Separator />
          <MainMenu.DefaultItems.Help />
        </MainMenu>
        {/* 之前 Footer 里有个手动 Refresh 按钮（贴 Excalidraw 原生 zoom/
            undo/redo 旁边）。WS state.changed 已经把状态推到位，按用户
            要求去掉了。MainMenu 里的 "Refresh" 入口保留作为兜底。 */}
      </Excalidraw>
      {arrangeConfirmOpen && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setArrangeConfirmOpen(false)
          }}
        >
          <div className="modal arrange-confirm-modal" role="dialog" aria-modal="true" aria-label="Arrange sessions">
            <div className="modal-header">
              <div className="modal-title">Arrange sessions</div>
              <div className="modal-subtitle">Reflow cards into the saved grid.</div>
            </div>
            <div className="modal-body col" style={{ gap: 8 }}>
              <strong>Arrange current canvas sessions into a grid?</strong>
              <span className="muted" style={{ fontSize: 12, lineHeight: 1.4 }}>
                Session cards on this canvas will be aligned to a grid with 4 cards per row. This updates their saved positions.
              </span>
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setArrangeConfirmOpen(false)}>Cancel</button>
              <button className="primary" type="button" onClick={arrangeCurrentCanvasSessions}>Arrange</button>
            </div>
          </div>
        </div>
      )}
      {/* Channel actions —— portal 进 Excalidraw 自己的 .App-toolbar，
          作为 shape tool 旁边的两个图标按钮，视觉上完全融合。
          Excalidraw 没暴露 shape tool 注册 API（社区 issue #7583 / #6697
          确认只有 MainMenu/Footer/renderTopRightUI 三个公开口子），所以
          走 React Portal 直接 attach 到 toolbar DOM 节点，是目前唯一
          能做到"加一个图标按钮跟 rectangle/ellipse 同列"的办法。 */}
      {toolbarRowEl && createPortal(
        <>
          {/* className 跟 native shape tool 一致：`ToolIcon ToolIcon_size_medium`。
              不加 `ToolIcon_type_floating` —— 那条会让 .ToolIcon__icon 套一个
              深色背景，和原生 shape tool（透明背景）不一致。 */}
          <Tooltip label="Create a new channel">
            <button
              className="ToolIcon ToolIcon_size_medium board-channel-tool"
              onClick={onNewChannel}
              type="button"
              aria-label="Create channel"
            >
              <div className="ToolIcon__icon" tabIndex={-1}>
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
                  <rect x="3" y="3" width="18" height="18" rx="3" stroke="currentColor" strokeWidth="1.6"/>
                  <path d="M12 8v8M8 12h8" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
                </svg>
              </div>
            </button>
          </Tooltip>
          <Tooltip label="Create DM line: drag from one session card to another">
          <button
            className="ToolIcon ToolIcon_size_medium board-channel-tool"
            onClick={() => {
              if (!api) return
              try {
                ;(api as any).setActiveTool({ type: 'arrow' })
              } catch (e) {
                console.warn('[Board] setActiveTool(arrow) failed', e)
              }
            }}
            type="button"
            aria-label="Create DM line"
          >
            <div className="ToolIcon__icon" tabIndex={-1}>
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
                <circle cx="6" cy="12" r="2" stroke="currentColor" strokeWidth="1.6"/>
                <circle cx="18" cy="12" r="2" stroke="currentColor" strokeWidth="1.6"/>
                <path d="M8 12h8" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/>
              </svg>
            </div>
          </button>
          </Tooltip>
        </>,
        toolbarRowEl,
      )}
      {zoomActionsEl && createPortal(
        <Tooltip label="Fit canvas to content">
          <button
            className="zoom-button board-fit-content-zoom-button"
            onClick={(event) => {
              event.preventDefault()
              event.stopPropagation()
              onFit()
            }}
            type="button"
            aria-label="Fit canvas to content"
            title="Fit canvas to content"
          >
            <div className="ToolIcon__icon" tabIndex={-1}>
              <FitIcon />
            </div>
          </button>
        </Tooltip>,
        zoomActionsEl,
      )}
      <SessionOverlay
        excalidrawAPI={api}
        state={state}
        currentCanvasSessionIds={currentCanvasSessionIds}
        sceneRevision={sceneRevision}
        templateCache={templateCache}
        onNeedTemplate={onNeedTemplate}
        unreadSids={unreadSids}
        onSessionPointerDown={handleSessionOverlayPointerDown}
      />
      {saveStatus !== 'idle' && (
        <div
          className={
            'canvas-save-status' +
            (saveStatus === 'saving' ? ' canvas-save-status--saving' : '') +
            (saveStatus === 'saved' ? ' canvas-save-status--saved' : '')
          }
          role="status"
          aria-live="polite"
        >
          <span className="canvas-save-status__dot" aria-hidden />
          {saveStatus === 'saving' ? 'Saving canvas' : 'Canvas saved'}
        </div>
      )}
      {state && selectedCoordinationGroup && selectedCoordinationSessionId && (
        <CoordinationPanel
          group={selectedCoordinationGroup}
          selectedSessionId={selectedCoordinationSessionId}
          state={state}
          onRefresh={onRefresh}
        />
      )}
    </div>
  )
}

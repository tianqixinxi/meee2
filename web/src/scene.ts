// Pure mapping from board state + layout → Excalidraw element list.
//
// Wave 16: session cards are Excalidraw-native `embeddable` elements. The
// canvas owns position, selection, copy/paste, delete, and arrow binding.
// We override just the rendering via the `renderEmbeddable` prop in Board.
//
// Each embeddable's `link` encodes the session id: `meee2://session/<sid>`.
// One session can have 0, 1, or many embeddables on the canvas (copy/paste
// creates duplicates that all render the same live session). Arrows target
// one "primary" embeddable id per session — picked by Board.tsx, passed in.
//
// We don't import Excalidraw's full element types here (they're verbose and
// internal). We produce "skeleton" elements and then pass them through
// Excalidraw's `convertToExcalidrawElements` helper at the call site.

import type { BoardState, Channel, Session } from './types'
import type { LayoutMap } from './layout'

// Card size — the embeddable box inside which SessionCard renders at 100%.
export const RECT_W = 360
export const RECT_H = 260
export const MAX_FULL_MESH_MEMBERS = 5

// Session id 存到 element.customData.sessionId 上。之前用 embeddable.link
// 是因为要 renderEmbeddable，现在彻底改走 rectangle + 上面叠 overlay 渲染，
// 就不需要 link 了。customData 在 copy/paste 时自动带上，parseSessionLink
// 就改成从 customData 读。名字还叫 parseSessionLink 是历史，不重要。
export function parseSessionLink(
  linkOrElement: string | null | undefined | { customData?: { sessionId?: string } },
): string | null {
  // Called by legacy code that passes element.link — those return null now.
  if (typeof linkOrElement === 'string' || linkOrElement == null) {
    return null
  }
  return linkOrElement.customData?.sessionId ?? null
}

/** Read sessionId out of an Excalidraw element's customData. */
export function parseSessionFromElement(el: any): string | null {
  return el?.customData?.sessionId ?? null
}

/** Stable id we seed for the first embeddable of a session (pre-placement). */
export function sessionRectId(sid: string): string {
  return `session-${sid}`
}

export function channelArrowId(
  channelName: string,
  fromSid: string,
  toSid: string,
): string {
  return `channel-${channelName}-${fromSid}-${toSid}`
}

/** True if this element id is one Excalidraw-native shape prefix we own. */
export function isManagedElementId(id: string): boolean {
  return id.startsWith('session-') || id.startsWith('channel-')
}

/**
 * Given an Excalidraw element id that starts with "channel-", and the list of
 * current channels, figure out which channel this arrow belongs to. We don't
 * parse — we just prefix-match against known channel names.
 */
export function resolveChannelFromElementId(
  id: string,
  channels: Channel[],
): Channel | null {
  if (!id.startsWith('channel-')) return null
  const rest = id.slice('channel-'.length)
  const withoutLabel = rest.endsWith('-label')
    ? rest.slice(0, -'-label'.length)
    : rest
  let best: Channel | null = null
  for (const ch of channels) {
    if (
      withoutLabel === ch.name ||
      withoutLabel.startsWith(ch.name + '-')
    ) {
      if (!best || ch.name.length > best.name.length) {
        best = ch
      }
    }
  }
  return best
}

// -- Element building ------------------------------------------------------

/** Skeleton shape accepted by `convertToExcalidrawElements`. */
export interface SkeletonElement {
  type: string
  id?: string
  x?: number
  y?: number
  width?: number
  height?: number
  strokeColor?: string
  backgroundColor?: string
  fillStyle?: string
  strokeWidth?: number
  strokeStyle?: string
  roundness?: { type: number } | null
  locked?: boolean
  text?: string
  fontSize?: number
  fontFamily?: number
  textAlign?: string
  verticalAlign?: string
  containerId?: string
  groupIds?: string[]
  opacity?: number
  link?: string
  validated?: boolean | null
  label?: {
    text: string
    fontSize?: number
  }
  start?: { id: string; type?: string }
  end?: { id: string; type?: string }
  [key: string]: any
}

function modeStrokeColor(mode: Channel['mode']): string {
  switch (mode) {
    case 'auto':
      return '#22C55E'
    case 'intercept':
      return '#EAB308'
    case 'paused':
      return '#EF4444'
  }
}

function channelStrokeStyle(channel: Channel): string {
  if (channel.mode === 'paused') return 'dotted'
  if (channel.pendingCount > 0) return 'dashed'
  return 'solid'
}

function channelLabel(ch: Channel): string {
  let s = ch.name
  if (ch.pendingCount > 0) s += ` ·⏳${ch.pendingCount}`
  if (ch.mode !== 'auto') s += ` [${ch.mode}]`
  return s
}

// -- helpers retained for use by other modules (SessionDetail, SessionCard) -

export function truncateOneLine(s: string, max: number): string {
  const flat = s.replace(/\s+/g, ' ').trim()
  return flat.length > max ? flat.slice(0, Math.max(0, max - 1)) + '…' : flat
}

export function shortenProject(p: string): string {
  const home = '/Users/'
  let s = p
  if (s.startsWith(home)) {
    const rest = s.slice(home.length)
    const idx = rest.indexOf('/')
    s = '~' + (idx >= 0 ? rest.slice(idx) : '')
  }
  return s.length > 40 ? '…' + s.slice(-39) : s
}

export function statusLabel(status: string): string {
  const map: Record<string, string> = {
    running: '● running',
    idle: '○ idle',
    thinking: '✦ thinking',
    tooling: '⚡ tooling',
    waitingInput: '⌛ waiting',
    waiting_input: '⌛ waiting',
    permissionRequest: '⚠ permission',
    permission_request: '⚠ permission',
    completed: '✓ completed',
    compacting: '⇣ compacting',
    failed: '✖ failed',
  }
  return map[status] ?? status
}

// -- Session embeddable element ---------------------------------------------

/** Build one embeddable element skeleton for a session at (x, y). */
export function buildSessionEmbeddable(
  session: Session,
  x: number,
  y: number,
  id?: string,
): SkeletonElement {
  // 改成 rectangle 而非 embeddable：embeddable 被 Excalidraw 当成 link-embed
  // 特殊处理（click 走 activation、display:none、scheme launch 报错）。
  // rectangle 是真正的一等 shape — 原生 drag / 选中 / resize / wheel-pan-zoom
  // 全部照常工作。sessionId 藏在 customData 里，copy/paste 自动带着。
  return {
    type: 'rectangle',
    id: id ?? sessionRectId(session.id),
    x,
    y,
    width: RECT_W,
    height: RECT_H,
    strokeColor: 'rgba(120,120,120,0.15)',  // 视觉很淡，overlay 盖住但 hit-test OK
    backgroundColor: 'rgba(30,30,30,0.4)',
    fillStyle: 'solid',
    strokeWidth: 1,
    roundness: { type: 3 },
    locked: false,
    groupIds: [],
    opacity: 100,
    customData: { sessionId: session.id },
  } as SkeletonElement
}

/**
 * Build skeleton elements from state.
 *
 * `sessionIdToElementId(sid)` returns the **primary** embeddable id that
 * channel arrows should bind to for the session, or `null` to skip drawing
 * arrows touching that session. This is computed in Board.tsx which has
 * access to the current Excalidraw scene.
 *
 * This function only produces:
 *   - NEW embeddables for sessions that aren't yet on the canvas (if the
 *     caller includes them via `newSessionIds`), plus
 *   - channel arrows bound to the primary embeddable ids.
 *
 * The caller is responsible for merging with existing user shapes and
 * existing embeddables — see Board.tsx.
 */
export function buildScene(
  state: BoardState,
  layout: LayoutMap,
  opts: {
    /** Sessions that need a fresh embeddable created. */
    newSessionIds: string[]
    /** Primary-element resolver for arrow binding. */
    sessionIdToElementId: (sid: string) => string | null
  },
): { newEmbeddables: SkeletonElement[]; arrows: SkeletonElement[] } {
  const sessionById = new Map(state.sessions.map((s) => [s.id, s]))
  const newEmbeddables: SkeletonElement[] = []

  for (const sid of opts.newSessionIds) {
    const s = sessionById.get(sid)
    if (!s) continue
    const pos = layout[sid] ?? { x: 80, y: 80 }
    newEmbeddables.push(buildSessionEmbeddable(s, pos.x, pos.y))
  }

  const arrows: SkeletonElement[] = []
  for (const ch of state.channels) {
    const pairs = memberPairs(ch, state.sessions)
    for (const [fromSid, toSid] of pairs) {
      const fromId = opts.sessionIdToElementId(fromSid)
      const toId = opts.sessionIdToElementId(toSid)
      if (!fromId || !toId) continue
      arrows.push({
        type: 'arrow',
        id: channelArrowId(ch.name, fromSid, toSid),
        strokeColor: modeStrokeColor(ch.mode),
        strokeWidth: ch.pendingCount > 0 ? 3 : 2,
        strokeStyle: channelStrokeStyle(ch),
        roundness: null,
        // NOTE: type is "rectangle" in the skeleton because
        // convertToExcalidrawElements' type signature excludes "embeddable"
        // from arrow endpoints — but at runtime Excalidraw's
        // isBindableElement() allows "embeddable", and binding works fine
        // when we cast to any.
        start: { id: fromId, type: 'rectangle' },
        end: { id: toId, type: 'rectangle' },
        label: {
          text: channelLabel(ch),
          fontSize: 12,
        },
      })
    }
  }

  return { newEmbeddables, arrows }
}

/**
 * Pick the pairs of member sessionIds to draw arrows for.
 */
function memberPairs(
  channel: Channel,
  sessions: Session[],
): Array<[string, string]> {
  const known = new Set(sessions.map((s) => s.id))
  const sids: string[] = []
  const seen = new Set<string>()
  for (const m of channel.members) {
    if (!known.has(m.sessionId)) continue
    if (seen.has(m.sessionId)) continue
    seen.add(m.sessionId)
    sids.push(m.sessionId)
  }
  if (sids.length < 2) return []

  if (sids.length <= MAX_FULL_MESH_MEMBERS) {
    const out: Array<[string, string]> = []
    for (let i = 0; i < sids.length; i++) {
      for (let j = i + 1; j < sids.length; j++) {
        out.push([sids[i], sids[j]])
      }
    }
    return out
  }
  const [hub, ...rest] = sids
  return rest.map((sid) => [hub, sid] as [string, string])
}

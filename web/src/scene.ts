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

// Channel hub ellipse — sibling constants to RECT_W / RECT_H. Small oval that
// sits between session cards as a visible "hub" with spokes (arrows) pointing
// in from each member session.
export const CHANNEL_W = 100
export const CHANNEL_H = 56

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

/** Read channelName out of an Excalidraw element's customData. */
export function parseChannelFromElement(el: any): string | null {
  return el?.customData?.channelName ?? null
}

/** Stable id we seed for the first embeddable of a session (pre-placement). */
export function sessionRectId(sid: string): string {
  return `session-${sid}`
}

/** Stable id of the hub ellipse for a channel. */
export function channelHubId(channelName: string): string {
  return `channel-${channelName}`
}

/** Stable id of a spoke arrow going from `fromSid` into `channelName`'s hub. */
export function channelSpokeId(channelName: string, fromSid: string): string {
  return `channel-${channelName}-spoke-${fromSid}`
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

/**
 * Stroke color keyed by channel mode. Uses the app's muted Claude-warm palette
 * tokens from styles.css (--success / --warning / --danger) so hub ellipses,
 * spoke arrows, and any other mode-themed chrome stay visually coherent.
 */
export function modeStrokeColor(mode: Channel['mode']): string {
  switch (mode) {
    case 'auto':
      return '#7FA982' // --success (sage green)
    case 'intercept':
      return '#D4A373' // --warning (sand brown)
    case 'paused':
      return '#C26A6A' // --danger  (terracotta red)
  }
}

/**
 * Stroke style keyed by channel mode (+ pending signal). Paused channels are
 * dotted (faint), channels with queued/held messages are dashed (attention),
 * everything else is solid.
 */
export function modeStrokeStyle(channel: Channel): string {
  if (channel.mode === 'paused') return 'dotted'
  if (channel.pendingCount > 0) return 'dashed'
  return 'solid'
}

/** Two-line hub label: "#<name>" on top, "<MODE>[ ·⏳<pending>]" below. */
function channelHubLabel(ch: Channel): string {
  const line1 = `#${ch.name}`
  let line2 = ch.mode.toUpperCase()
  if (ch.pendingCount > 0) line2 += ` ·⏳${ch.pendingCount}`
  return `${line1}\n${line2}`
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
    active: '● active',
    idle: '○ idle',
    thinking: '✦ thinking',
    tooling: '⚡ tooling',
    waitingForUser: '○ idle',
    permissionRequired: '🔒 permission',
    completed: '✓ completed',
    compacting: '⇣ compacting',
    dead: '✖ dead',
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
    // Session rect 只是 Excalidraw 层的 hit-test 载体——click/drag/resize 都
    // 要能抓到这片区域。但视觉完全交给上层的 <CardHost> DOM overlay。
    //
    // 以前用半透明灰（rgba(30,30,30,0.4)）"视觉很淡"，但 overlay 一旦因为
    // resize / zoom 过渡 / 像素四舍五入没盖严，灰底就会从 card 四周漏出来，
    // 看上去像卡片后面多了一层灰影。
    //
    // 解法：填色改成和 --bg（#1a1a1a）完全一致的纯色；solid fillStyle 保留，
    // Excalidraw 的 body hit-test 还是按 bbox 正常走；描边也设成同色，选中 /
    // resize 时 Excalidraw 自己画的蓝框不受影响。
    // 填色跟 styles.css 的 --bg 保持一致（Claude warm dark #262624）
    strokeColor: '#262624',
    backgroundColor: '#262624',
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
 * Build one ellipse skeleton representing a channel "hub" at (x, y).
 *
 * Channels render as hub-and-spoke: one ellipse per channel + one arrow per
 * member → hub. Replaces the previous pair-wise arrow model, which scaled
 * as O(members^2) edges and made dense channels visually noisy.
 */
export function buildChannelHub(
  channel: Channel,
  x: number,
  y: number,
): SkeletonElement {
  return {
    type: 'ellipse',
    id: channelHubId(channel.name),
    x,
    y,
    width: CHANNEL_W,
    height: CHANNEL_H,
    strokeColor: modeStrokeColor(channel.mode),
    backgroundColor: '#2C2B29', // --bg-paper
    fillStyle: 'solid',
    strokeWidth: 2,
    strokeStyle: modeStrokeStyle(channel),
    roundness: null,
    locked: false,
    groupIds: [],
    opacity: 100,
    customData: { channelName: channel.name },
    label: {
      text: channelHubLabel(channel),
      fontSize: 12,
    },
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
 * This function produces:
 *   - NEW session embeddables for sessions that aren't yet on the canvas (via
 *     `newSessionIds`),
 *   - NEW channel hub ellipses for channels that aren't yet on the canvas
 *     (via `newChannelNames`), and
 *   - spoke arrows session → channel hub for each current membership.
 *
 * The caller is responsible for merging with existing user shapes, existing
 * embeddables, and existing hubs — see Board.tsx.
 */
export function buildScene(
  state: BoardState,
  layout: LayoutMap,
  channelLayout: LayoutMap,
  opts: {
    /** Sessions that need a fresh embeddable created. */
    newSessionIds: string[]
    /** Channels that need a fresh hub ellipse created. */
    newChannelNames: string[]
    /** Primary-element resolver for arrow binding. */
    sessionIdToElementId: (sid: string) => string | null
    /**
     * Session↔channel pairs that already have a user-drawn arrow on the
     * canvas. For each such pair we SKIP generating our own spoke — the
     * user's arrow is the sole visual of that membership. Without this,
     * a user who drags session→hub would see two arrows for the same
     * membership (theirs + ours), and Excalidraw's layout loops between
     * the two every tick, effectively freezing.
     * Key format: `<sid>|<channelName>`.
     */
    existingConnections?: Set<string>
  },
): {
  newEmbeddables: SkeletonElement[]
  newChannelHubs: SkeletonElement[]
  arrows: SkeletonElement[]
} {
  const sessionById = new Map(state.sessions.map((s) => [s.id, s]))
  const newEmbeddables: SkeletonElement[] = []

  for (const sid of opts.newSessionIds) {
    const s = sessionById.get(sid)
    if (!s) continue
    const pos = layout[sid] ?? { x: 80, y: 80 }
    newEmbeddables.push(buildSessionEmbeddable(s, pos.x, pos.y))
  }

  const channelByName = new Map(state.channels.map((c) => [c.name, c]))
  const newChannelHubs: SkeletonElement[] = []
  for (const name of opts.newChannelNames) {
    const ch = channelByName.get(name)
    if (!ch) continue
    if (ch.name.startsWith('__')) continue // defensive: skip operator channels
    const pos = channelLayout[name] ?? { x: 80, y: 80 }
    newChannelHubs.push(buildChannelHub(ch, pos.x, pos.y))
  }

  const arrows: SkeletonElement[] = []
  const knownSids = new Set(state.sessions.map((s) => s.id))
  for (const ch of state.channels) {
    if (ch.name.startsWith('__')) continue // defensive
    const hubId = channelHubId(ch.name)
    const seenSids = new Set<string>()
    for (const member of ch.members) {
      if (!knownSids.has(member.sessionId)) continue
      if (seenSids.has(member.sessionId)) continue
      seenSids.add(member.sessionId)

      // 用户亲手画过这条 session↔channel 的 arrow → 别再自动画一条重的，
      // 让用户那条成为这个成员关系的唯一视觉。
      if (opts.existingConnections?.has(`${member.sessionId}|${ch.name}`)) continue

      const fromId = opts.sessionIdToElementId(member.sessionId)
      if (!fromId) continue
      arrows.push({
        type: 'arrow',
        id: channelSpokeId(ch.name, member.sessionId),
        strokeColor: modeStrokeColor(ch.mode),
        strokeWidth: ch.pendingCount > 0 ? 3 : 2,
        strokeStyle: modeStrokeStyle(ch),
        roundness: null,
        // channel 关系是无方向的——"这个 session 和这个 channel 相连"，不是
        // "session 把消息发给 channel" 或反之。把两端 arrowhead 都置 null，
        // 视觉上就是一条中性连线。
        startArrowhead: null,
        endArrowhead: null,
        // NOTE: type is "rectangle"/"ellipse" in the skeleton because
        // convertToExcalidrawElements' type signature excludes "embeddable"
        // from arrow endpoints — but at runtime Excalidraw's
        // isBindableElement() allows both, and binding works fine when we
        // cast to any.
        start: { id: fromId, type: 'rectangle' },
        end: { id: hubId, type: 'ellipse' },
        label: {
          text: member.alias,
          fontSize: 11,
        },
      })
    }
  }

  return { newEmbeddables, newChannelHubs, arrows }
}

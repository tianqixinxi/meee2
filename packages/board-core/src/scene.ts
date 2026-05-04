// Pure mapping from board state + layout → Excalidraw element list.
//
// Wave 16: session cards are Excalidraw-native `embeddable` elements. The
// canvas owns position, selection, copy/paste, delete, and arrow binding.
// Wave 19: switched to plain `rectangle` (visual rendering happens in a DOM
// overlay above the canvas).
//
// Each element's `customData.sessionId` holds the session id. One session
// can have 0, 1, or many rectangles on the canvas (copy/paste creates
// duplicates that all render the same live session). Arrows target one
// "primary" rect id per session — picked by the caller and passed in.
//
// We don't import Excalidraw's full element types here (they're verbose and
// internal). We produce "skeleton" elements and then pass them through
// Excalidraw's `convertToExcalidrawElements` helper at the call site.
//
// Type design: this module is consumed by both meee2 (rich BoardState/Session/
// Channel) and meee360 (slimmer TeamSession-derived types). The exported
// functions therefore accept *structural* shapes — the minimum each function
// actually reads — so both apps' types satisfy them without adapter glue.

import type { LayoutMap } from './layout'

// -- Card / hub size ---------------------------------------------------

/** The rectangle inside which the session card overlay renders at 100%. */
export const RECT_W = 360
export const RECT_H = 260

/** Legacy channel hub ellipse size — kept exported for callers still
 *  referencing the old visual. The current "frame channel" form uses
 *  `CHANNEL_FRAME_W/H` instead. */
export const CHANNEL_W = 100
export const CHANNEL_H = 56

/** Default frame size when a new channel is placed without a member-bbox
 *  hint. Wide enough to comfortably hold a couple of session cards
 *  (RECT_W=360) plus header padding. */
export const CHANNEL_FRAME_W = 820
export const CHANNEL_FRAME_H = 540

/** Prefix marking a 1-on-1 DM channel (created by drawing a line between two
 *  session cards). DM channels are hidden from the sidebar listing. */
export const DM_CHANNEL_PREFIX = 'dm-'

/** Stable channel name for a 1-on-1 DM between two sessions. The two sids
 *  are sorted so the same pair always produces the same name regardless of
 *  arrow direction. Result fits the backend alias regex `[a-z0-9_-]{1,64}`. */
export function dmChannelName(sidA: string, sidB: string): string {
  const a = sidA.replace(/-/g, '').slice(0, 10).toLowerCase()
  const b = sidB.replace(/-/g, '').slice(0, 10).toLowerCase()
  const [first, second] = [a, b].sort()
  return `${DM_CHANNEL_PREFIX}${first}-${second}`
}

export function isDmChannelName(name: string): boolean {
  return name.startsWith(DM_CHANNEL_PREFIX)
}

/** Visual style applied to a card↔card arrow that the canvas owns as a DM
 *  line. Distinct enough that a user-drawn vanilla arrow doesn't get
 *  confused for one. */
export const DM_LINE_STROKE_COLOR = '#9F7BCB' // muted violet
export const DM_LINE_STROKE_WIDTH_BASE = 2
export const DM_LINE_STROKE_WIDTH_PENDING = 3

// -- Structural types --------------------------------------------------

export type ChannelMode = 'auto' | 'intercept' | 'paused'

/** Just enough of a session for the scene builder. Both meee2's `Session`
 *  and meee360's `TeamSession` satisfy this structurally. */
export interface SessionForScene {
  id: string
}

/** Structural channel. Apps with richer Channel types (meee2's `Channel`
 *  with extra fields) satisfy this automatically. */
export interface ChannelForScene {
  name: string
  mode: ChannelMode
  pendingCount: number
  members: Array<{ sessionId: string; alias: string }>
}

export interface BoardStateForScene {
  sessions: SessionForScene[]
  channels: ChannelForScene[]
}

// -- ID parsers / helpers ----------------------------------------------

/** Read sessionId from an element. Tolerates legacy callers that pass the
 *  element.link string (always returns null for those — link-based encoding
 *  is gone). */
export function parseSessionLink(
  linkOrElement: string | null | undefined | { customData?: { sessionId?: string } },
): string | null {
  if (typeof linkOrElement === 'string' || linkOrElement == null) return null
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

/** Stable id we seed for the first rectangle of a session (pre-placement). */
export function sessionRectId(sid: string): string {
  return `session-${sid}`
}

/** Stable id of the hub ellipse for a channel. */
export function channelHubId(channelName: string): string {
  return `channel-${channelName}`
}

/**
 * Minimal duck-typed slice of Excalidraw's imperative API needed to pan/scroll
 * the canvas onto a managed element. Kept here (instead of importing
 * `@excalidraw/excalidraw` types) so board-core stays framework-free and
 * meee360 can call this without pulling Excalidraw types into its core paths.
 */
export interface BoardPanAPI {
  getSceneElements(): readonly { id?: string; type?: string }[]
  scrollToContent(
    target: readonly unknown[] | unknown,
    opts?: { fitToContent?: boolean; animate?: boolean },
  ): void
}

/**
 * Center the board's viewport on the channel hub for `channelName`.
 *
 * Returns true if the hub element was found and a scroll was issued.
 * Returns false if the hub doesn't exist on the canvas yet — the caller
 * should re-invoke after the next scene rebuild (typically by depending on
 * the board state in the surrounding effect).
 *
 * Both meee2's board-app and meee360 wire this from a `useEffect` that
 * fires when the sidebar selection switches to a channel.
 */
export function panToChannelHub(
  api: BoardPanAPI,
  channelName: string,
): boolean {
  if (!api || !channelName) return false
  const hubId = channelHubId(channelName)
  // Frame is the current form; ellipse is the legacy form, still tolerated
  // so unmigrated scenes can pan correctly.
  const hubEl = api
    .getSceneElements()
    .find((el) => el?.id === hubId && (el?.type === 'frame' || el?.type === 'ellipse'))
  if (!hubEl) return false
  api.scrollToContent([hubEl], { fitToContent: false, animate: true })
  return true
}

/**
 * Stable id of the text label bound to a channel hub. Deterministic (instead
 * of letting Excalidraw auto-generate one from the `label: {…}` skeleton
 * sugar) so it's treated as managed — otherwise the random id makes it look
 * like a user shape, gets persisted to localStorage, and on every page
 * refresh the hub is rebuilt WITH a fresh label while the old one is also
 * restored from storage. Labels then accumulate one-per-refresh.
 */
export function channelLabelId(channelName: string): string {
  return `channel-${channelName}-label`
}

/** Stable id of a spoke arrow from `fromSid` into `channelName`'s hub. */
export function channelSpokeId(channelName: string, fromSid: string): string {
  return `channel-${channelName}-spoke-${fromSid}`
}

/**
 * Stable id of the alias text label bound to a spoke arrow. Same managed-id
 * reasoning as channelLabelId — without it, every refresh leaks a new random
 * label and the old one survives in user-shapes localStorage.
 */
export function channelSpokeLabelId(channelName: string, fromSid: string): string {
  return `channel-${channelName}-spoke-${fromSid}-label`
}

/** True if this element id is a programmatic shape we manage. */
export function isManagedElementId(id: string): boolean {
  return id.startsWith('session-') || id.startsWith('channel-')
}

/**
 * Given an Excalidraw element id that starts with "channel-", and the list of
 * current channels, figure out which channel this element belongs to. Greedy
 * prefix-match — longest matching channel name wins so a channel `foo-bar`
 * doesn't accidentally swallow `foo`.
 */
export function resolveChannelFromElementId<C extends ChannelForScene>(
  id: string,
  channels: C[],
): C | null {
  if (!id.startsWith('channel-')) return null
  const rest = id.slice('channel-'.length)
  const withoutLabel = rest.endsWith('-label')
    ? rest.slice(0, -'-label'.length)
    : rest
  let best: C | null = null
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

// -- Skeleton element shape --------------------------------------------

/** Skeleton shape accepted by Excalidraw's `convertToExcalidrawElements`. */
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

// -- Mode-keyed visuals ------------------------------------------------

/** Stroke color keyed by channel mode. Uses meee2's muted Claude-warm
 *  palette — apps wanting a different palette can override at the consumer
 *  level (e.g. by post-processing the returned skeletons). */
export function modeStrokeColor(mode: ChannelMode): string {
  switch (mode) {
    case 'auto':
      return '#7FA982' // sage green
    case 'intercept':
      return '#D4A373' // sand brown
    case 'paused':
      return '#C26A6A' // terracotta red
  }
}

/** Stroke style keyed by mode + pending signal: paused = dotted (faint),
 *  pendingCount > 0 = dashed (attention), else solid. */
export function modeStrokeStyle(channel: ChannelForScene): string {
  if (channel.mode === 'paused') return 'dotted'
  if (channel.pendingCount > 0) return 'dashed'
  return 'solid'
}

/** Two-line hub label: "#<name>" on top, "<MODE>[ ·⏳<pending>]" below. */
export function channelHubLabelText(ch: ChannelForScene): string {
  const line1 = `#${ch.name}`
  let line2 = ch.mode.toUpperCase()
  if (ch.pendingCount > 0) line2 += ` ·⏳${ch.pendingCount}`
  return `${line1}\n${line2}`
}

// -- Generic helpers retained for app-level UIs ------------------------

export function truncateOneLine(s: string, max: number): string {
  const flat = s.replace(/\s+/g, ' ').trim()
  return flat.length > max ? flat.slice(0, Math.max(0, max - 1)) + '…' : flat
}

/** Replace `/Users/<username>/` prefix with `~/` and truncate to 40 chars. */
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

/** Pretty status badge with a glyph prefix. */
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

// -- Element builders --------------------------------------------------

/** Visual style of a session rect. The rect is a hit-test carrier — visual
 *  rendering happens in a DOM overlay above the canvas. Stroke + bg should
 *  match the host app's background color so any pixel-rounding gap between
 *  the overlay and the rect doesn't leak a contrasting halo. Defaults match
 *  meee2's --bg (#262624). meee360 (or other hosts with darker themes) can
 *  pass overrides via buildScene's `rectStyle` opt. */
export interface SessionRectStyle {
  strokeColor?: string
  backgroundColor?: string
  fillStyle?: string
  strokeWidth?: number
  /** Excalidraw `roundness` — pass `null` for sharp corners. */
  roundness?: { type: number } | null
}

const DEFAULT_RECT_STYLE: Required<Omit<SessionRectStyle, 'roundness'>> & { roundness: { type: number } | null } = {
  strokeColor: '#262624',
  backgroundColor: '#262624',
  fillStyle: 'solid',
  strokeWidth: 1,
  roundness: { type: 3 },
}

/** Build one rectangle skeleton for a session at (x, y). Pass `style` to
 *  override any of stroke/bg/strokeWidth/roundness for hosts with non-meee2
 *  background colors. */
export function buildSessionRect(
  session: SessionForScene | string,
  x: number,
  y: number,
  idOrStyle?: string | SessionRectStyle,
  styleArg?: SessionRectStyle,
): SkeletonElement {
  const sid = typeof session === 'string' ? session : session.id
  // Backwards-compatible signature: 4th arg can be the legacy `id?: string`
  // OR a style object. If string, treat as id; if object, treat as style.
  const id = typeof idOrStyle === 'string' ? idOrStyle : undefined
  const style = (typeof idOrStyle === 'object' ? idOrStyle : styleArg) ?? {}
  return {
    type: 'rectangle',
    id: id ?? sessionRectId(sid),
    x,
    y,
    width: RECT_W,
    height: RECT_H,
    strokeColor: style.strokeColor ?? DEFAULT_RECT_STYLE.strokeColor,
    backgroundColor: style.backgroundColor ?? DEFAULT_RECT_STYLE.backgroundColor,
    fillStyle: style.fillStyle ?? DEFAULT_RECT_STYLE.fillStyle,
    strokeWidth: style.strokeWidth ?? DEFAULT_RECT_STYLE.strokeWidth,
    roundness: style.roundness === undefined ? DEFAULT_RECT_STYLE.roundness : style.roundness,
    locked: false,
    groupIds: [],
    opacity: 100,
    customData: { sessionId: sid },
  } as SkeletonElement
}

/** Backward-compatible alias — the old name from when these were `embeddable`
 *  elements. New code should use `buildSessionRect`. */
export const buildSessionEmbeddable = buildSessionRect

/**
 * Build a channel "frame" skeleton — an Excalidraw native frame element. A
 * session card is a member of this channel iff its rectangle's `frameId`
 * points to this frame's id; Excalidraw assigns frameId automatically when
 * the user drags a rect inside the frame's bbox. Returns 1 element.
 *
 * Caller is responsible for choosing (x, y) and (w, h) — when a channel is
 * first placed at the viewport center we use `CHANNEL_FRAME_W/H`; if member
 * rects already exist we'd typically grow to enclose them.
 *
 * The frame's deterministic id (`channelHubId(name)`) puts it on the
 * managed side of `isManagedElementId`, same as the legacy hub ellipse.
 */
export function buildChannelHub(
  channel: ChannelForScene,
  x: number,
  y: number,
  width: number = CHANNEL_FRAME_W,
  height: number = CHANNEL_FRAME_H,
): SkeletonElement[] {
  const frameId = channelHubId(channel.name)
  // `children` is required by Excalidraw's frame skeleton type — omitting it
  // makes `convertToExcalidrawElements` call `.forEach` on undefined and the
  // whole board renders as a black screen. Empty array is fine: Excalidraw
  // computes containment from each child's `frameId` on every render, the
  // skeleton-level list is only the explicit seed.
  const frame: SkeletonElement = {
    type: 'frame',
    id: frameId,
    x,
    y,
    width,
    height,
    name: `#${channel.name}`,
    children: [],
    strokeColor: modeStrokeColor(channel.mode),
    backgroundColor: 'transparent',
    fillStyle: 'solid',
    strokeWidth: 2,
    strokeStyle: modeStrokeStyle(channel),
    roundness: null,
    locked: false,
    groupIds: [],
    opacity: 100,
    customData: { channelName: channel.name },
  } as SkeletonElement
  return [frame]
}

/** Backward-compatible alias, in case downstream callers want the
 *  expressive name. */
export const buildChannelFrame = buildChannelHub

// -- Scene builder -----------------------------------------------------

/**
 * Build skeleton elements from state.
 *
 * Produces:
 *   - NEW session rectangles for sessions in `newSessionIds`, and
 *   - NEW channel frames for channels in `newChannelNames`.
 *
 * Memberships are tracked in two places now: frame channels via Excalidraw's
 * native `frameId` on each session rect (set by drag-into-frame), and DM
 * channels via card↔card user-drawn arrows annotated with `customData.dm`.
 * Neither is generated here — the caller (Board.tsx) reconciles state ↔ scene
 * in its onChange / scene-rebuild effects.
 *
 * The caller merges the returned arrays with existing user shapes / rects /
 * frames already in the scene.
 */
export function buildScene(
  state: BoardStateForScene,
  layout: LayoutMap,
  channelLayout: LayoutMap,
  opts: {
    /** Sessions that need a fresh rect created. */
    newSessionIds: string[]
    /** Channels that need a fresh frame created. */
    newChannelNames: string[]
    /**
     * Override the rect's stroke / background / strokeWidth / roundness so
     * the host app's canvas background can flush the rect cleanly. meee2
     * uses the default (#262624 to match its --bg). meee360 with a darker
     * Tailwind theme should pass e.g. `{ strokeColor: '#0a0a0a',
     * backgroundColor: '#141414', strokeWidth: 0, roundness: null }`.
     */
    rectStyle?: SessionRectStyle
  },
): {
  newRects: SkeletonElement[]
  /** @deprecated alias for newRects, kept for callers still using the old
   *  embeddable terminology. */
  newEmbeddables: SkeletonElement[]
  newChannelHubs: SkeletonElement[]
} {
  const newRects: SkeletonElement[] = []

  for (const sid of opts.newSessionIds) {
    const pos = layout[sid] ?? { x: 80, y: 80 }
    newRects.push(buildSessionRect(sid, pos.x, pos.y, opts.rectStyle))
  }

  const channelByName = new Map(state.channels.map((c) => [c.name, c]))
  const newChannelHubs: SkeletonElement[] = []
  for (const name of opts.newChannelNames) {
    const ch = channelByName.get(name)
    if (!ch) continue
    if (ch.name.startsWith('__')) continue // skip operator channels
    if (isDmChannelName(ch.name)) continue // DM channels render as arrows, not frames
    const pos = channelLayout[name] ?? { x: 80, y: 80 }
    newChannelHubs.push(...buildChannelHub(ch, pos.x, pos.y))
  }

  return {
    newRects,
    newEmbeddables: newRects,
    newChannelHubs,
  }
}

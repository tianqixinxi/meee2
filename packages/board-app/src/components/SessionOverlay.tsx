// Session cards rendered as DOM overlay above the Excalidraw canvas.
//
// Wave 19: session shapes are now plain `rectangle` elements (not embeddables)
// so Excalidraw handles click/drag/resize/wheel-pan-zoom natively. Overlay is
// mostly `pointer-events: none`: empty canvas areas flow through to Excalidraw,
// while each card item captures pointer drag so we can persist card layout
// immediately even when Excalidraw's transparent rect hit-testing misses.
//
// Selection sync: click on rect → Excalidraw native selection → Board's onChange
// handler reads selectedElementIds → updates sidebar.
// Drag/zoom: Excalidraw native. Card visuals track via sceneCoordsToViewportCoords.
// Jump to terminal: via sidebar's "Open terminal" button (no card-body dbl-click
// because that would require capturing events, breaking drag).
//
// Keying: each overlay item is keyed on element.id so copied rects get their
// own overlay instance — same session data via customData.sessionId.

import { memo, useEffect, useRef, useState } from 'react'
import type { CSSProperties, PointerEvent as ReactPointerEvent } from 'react'
import type { ExcalidrawImperativeAPI } from '@excalidraw/excalidraw/types'

import type { BoardState, Session } from '../types'
import { parseSessionFromElement, RECT_W, RECT_H, shortenProject } from '@meee1/board-core'
import { CardHost } from '@meee1/board-ui'
import { DEFAULT_TEMPLATE, templateIdForSession } from '@meee1/board-cards'

interface Props {
  excalidrawAPI: ExcalidrawImperativeAPI | null
  state: BoardState | null
  templateCache: Record<string, string>
  onNeedTemplate: (pluginId: string) => void
  /** 未读通知的 session id 集合 */
  unreadSids: Set<string>
  currentCanvasSessionIds: Set<string>
  /** Bumped after Board mutates the Excalidraw scene programmatically. */
  sceneRevision: number
  onSessionPointerDown?: (event: ReactPointerEvent<HTMLDivElement>, elementId: string, sessionId: string) => void
}

// De-dup log tracker keyed by sid. Only fires when the source length changes
// for a given session so we don't flood the console on every animation frame.
const _lastLoggedSrcLen = new Map<string, number>()
function logSourceForSid(sid: string, tplId: string, source: string) {
  const prev = _lastLoggedSrcLen.get(sid)
  if (prev === source.length) return
  _lastLoggedSrcLen.set(sid, source.length)
  // console.log(
  //   '[SessionOverlay] source resolved sid=%s tpl=%s len=%d firstLine=%s',
  //   sid.slice(0, 8),
  //   tplId,
  //   source.length,
  //   source.split('\n', 1)[0]?.slice(0, 60),
  // )
}

const MemoCardHost = memo(CardHost, (prev, next) =>
  prev.sessionId === next.sessionId &&
  prev.session === next.session &&
  prev.board === next.board &&
  prev.source === next.source,
)

interface OverlayItem {
  elementId: string
  session: Session
  source: string
  // 场景坐标（scene space）—— 跟 Excalidraw 元素本身一致。viewport 位置/缩放
  // 由外层 .session-overlay__scene 的 transform 统一应用，pan/zoom 时不会触发
  // 任何一项 inline style 重写，浏览器只需重新合成（composite）外层一层。
  sceneX: number
  sceneY: number
  sceneW: number
  sceneH: number
  isCurrentCanvasSession: boolean
}

export function SessionOverlay({
  excalidrawAPI,
  state,
  templateCache,
  onNeedTemplate,
  unreadSids,
  currentCanvasSessionIds,
  sceneRevision: _sceneRevision,
  onSessionPointerDown,
}: Props) {
  void _sceneRevision
  // overlayTick 仅用于触发 re-render，不读取它的值；setOverlayTick 在 onChange
  // 里检测到 scene mutation 才递增。
  const [, setOverlayTick] = useState(0)
  const rafRef = useRef<number | null>(null)
  const sceneRef = useRef<HTMLDivElement | null>(null)
  // Pan/zoom 的最新值 —— 直接写到 sceneRef 的 transform，不进 React。
  // sceneSignature 用来判 elements 是否变了（add/remove/move/resize）。变了
  // 才走 setOverlayTick 重渲；纯 pan/zoom 不重渲。
  const lastSceneSigRef = useRef<string>('')
  useEffect(() => {
    if (!excalidrawAPI) return
    const applyTransform = () => {
      const s = excalidrawAPI.getAppState()
      const zoom = s.zoom?.value || 1
      // Excalidraw 的 sceneCoordsToViewportCoords 等价于
      //   viewportXY = (sceneXY + scrollXY) * zoom (+ offsetLeft/Top)
      // 所以外层 transform 用 translate(scrollX*zoom, scrollY*zoom) scale(zoom)
      // —— 内层 item 直接用 sceneX/sceneY 作为 left/top 即可。
      const tx = s.scrollX * zoom
      const ty = s.scrollY * zoom
      if (sceneRef.current) {
        sceneRef.current.style.transform =
          `translate3d(${tx}px, ${ty}px, 0) scale(${zoom})`
      }
    }
    applyTransform()
    const computeSceneSig = (): string => {
      // 只把 session rect 的 id/x/y/w/h/customData.cardSource 拼起来；其他元素
      // （线、文字）不影响 overlay。length 短，每帧算一次便宜。
      const parts: string[] = []
      for (const el of excalidrawAPI.getSceneElements()) {
        if (el.type !== 'rectangle' || el.isDeleted) continue
        const sid = parseSessionFromElement(el)
        if (!sid) continue
        const src = (el as any).customData?.cardSource ?? ''
        parts.push(`${el.id}:${el.x}:${el.y}:${el.width}:${el.height}:${src.length}`)
      }
      return parts.join('|')
    }
    lastSceneSigRef.current = computeSceneSig()
    const onChange = () => {
      // pan/zoom 每帧都同步刷到 transform（DOM 写，不进 React）。
      applyTransform()
      // 真正的 scene mutation 才走 React。比对签名避免每个 onChange 都重渲。
      const sig = computeSceneSig()
      if (sig === lastSceneSigRef.current) return
      lastSceneSigRef.current = sig
      if (rafRef.current !== null) return
      rafRef.current = requestAnimationFrame(() => {
        rafRef.current = null
        setOverlayTick((t) => (t + 1) & 0x7fffffff)
      })
    }
    const unsub = excalidrawAPI.onChange(onChange)
    return () => {
      try { unsub() } catch { /* noop */ }
      if (rafRef.current !== null) {
        cancelAnimationFrame(rafRef.current)
        rafRef.current = null
      }
    }
  }, [excalidrawAPI])

  if (!excalidrawAPI || !state) return null

  const elements = excalidrawAPI.getSceneElements()

  const overlayItems: OverlayItem[] = []
  for (const el of elements) {
    // Our session rects — plain Excalidraw rectangle with customData.sessionId
    if (el.type !== 'rectangle') continue
    if (el.isDeleted) continue
    const sid = parseSessionFromElement(el)
    if (!sid) continue
    const session = state.sessions.find((s) => s.id === sid)
    if (!session) continue

    // 场景坐标 + 场景宽高。pan/zoom 不在这里算，由外层 .session-overlay__scene
    // 的 transform: translate(scroll*zoom) scale(zoom) 统一应用。
    const sceneW = el.width || RECT_W
    const sceneH = el.height || RECT_H

    const overrideSource: string | undefined = (el as any).customData?.cardSource
    // 每张 card 独立 template（per-session），而不是整个 plugin 共用一份。
    const tplId = templateIdForSession(session.id)
    const cached = templateCache[tplId]
    if (cached === undefined && !overrideSource) {
      onNeedTemplate(session.id)
    }
    const source = overrideSource ?? cached ?? DEFAULT_TEMPLATE
    // Fires once per (sid, len) combo — de-duped to avoid log spam. Useful
    // to check whether the source actually changed when you click a preset.
    logSourceForSid(session.id, tplId, source)

    overlayItems.push({
      elementId: el.id,
      session,
      source,
      sceneX: el.x,
      sceneY: el.y,
      sceneW,
      sceneH,
      isCurrentCanvasSession: currentCanvasSessionIds.has(session.id),
    })
  }

  overlayItems.sort((a, b) => {
    if (a.isCurrentCanvasSession !== b.isCurrentCanvasSession) {
      return a.isCurrentCanvasSession ? 1 : -1
    }
    return a.sceneY - b.sceneY || a.sceneX - b.sceneX
  })

  return (
    <div
      className="session-overlay"
      style={{
        position: 'absolute',
        inset: 0,
        pointerEvents: 'none',
        overflow: 'hidden',
        // Excalidraw canvas sits at z-index:2. Overlay above so visuals show;
        // only individual card items opt back into pointer events.
        zIndex: 3,
      }}
    >
      {/* Scene container：所有 card 用场景坐标定位，pan/zoom 由这一层 transform
          统一应用。useEffect 里 onChange 直接写 ref.style.transform，绕开 React
          render path，浏览器只做一次 composite。 */}
      <div
        ref={sceneRef}
        className="session-overlay__scene"
        style={{
          position: 'absolute',
          top: 0,
          left: 0,
          transformOrigin: '0 0',
          // willChange 提示浏览器给这一层独立 layer，pan 时纯 GPU 合成。
          willChange: 'transform',
        }}
      >
        {overlayItems.map((it) => {
          // 通知红点条件：
          //  1. status === 'permissionRequired'（权限阻塞，必须用户点确认）
          //  2. unreadSids 里有这个 sid（App 层检测到 status 从工作态转到休息态，
          //     代表 Claude 刚完成一轮回复；用户点 session card 后会清掉）
          const urgent =
            it.session.status === 'permissionRequired' ||
            unreadSids.has(it.session.id)
          // 内层 card 的 base 尺寸是 RECT_W × RECT_H，rect 实际场景宽高可能不同
          // （用户 resize 过）。用 scale 把 base 拉到场景宽高；canvas zoom 由
          // 外层 scene transform 再叠一层。
          const innerScale = it.sceneW / RECT_W
          return (
            <div
              key={it.elementId}
              className={
                'session-overlay__item' +
                (it.isCurrentCanvasSession
                  ? ' session-overlay__item--current'
                  : ' session-overlay__item--secondary')
              }
              onPointerDown={(event) => onSessionPointerDown?.(event, it.elementId, it.session.id)}
              style={{
                position: 'absolute',
                left: it.sceneX,
                top: it.sceneY,
                width: it.sceneW,
                height: it.sceneH,
                pointerEvents: 'auto',
              }}
            >
              <div style={{
                pointerEvents: 'none',
                position: 'relative',
                transform: `scale(${innerScale})`,
                transformOrigin: 'top left',
                width: RECT_W,
                height: RECT_H,
              }}>
                {it.isCurrentCanvasSession ? (
                  <div className="session-overlay__card-shell">
                    <MemoCardHost
                      sessionId={it.session.id}
                      session={it.session}
                      board={state}
                      source={it.source}
                    />
                  </div>
                ) : (
                    <SecondarySessionCard session={it.session} />
                  )}
                {urgent && <NotificationDot />}
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}

function SecondarySessionCard({ session }: { session: Session }) {
  const detail = session.currentTool || session.status
  return (
    <div
      className="secondary-session-card"
      style={{ '--card-accent': session.pluginColor } as CSSProperties}
    >
      <div className="secondary-session-card__top">
        <span className="secondary-session-card__plugin">{session.pluginDisplayName}</span>
        <span className="secondary-session-card__status">{detail}</span>
      </div>
      <div className="secondary-session-card__title">{session.title}</div>
      <div className="secondary-session-card__project">{shortenProject(session.project)}</div>
    </div>
  )
}

/**
 * 右上角小红点 —— 和 Island 的橙色 attention 指示灯对齐。
 * 放在 card 的缩放容器内，跟随 session card 的 canvas zoom 一起缩放。
 */
function NotificationDot() {
  return (
    <div
      className="session-overlay__dot"
      style={{
        position: 'absolute',
        top: 6,
        right: 6,
        width: 10,
        height: 10,
        borderRadius: '50%',
        background: '#EF4444',
        boxShadow: '0 0 0 2px rgba(239,68,68,0.25), 0 0 6px rgba(239,68,68,0.6)',
        zIndex: 4,
        pointerEvents: 'none',
      }}
    />
  )
}

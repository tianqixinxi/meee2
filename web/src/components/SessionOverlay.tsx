// Session cards rendered as DOM overlay above the Excalidraw canvas.
//
// Wave 19: session shapes are now plain `rectangle` elements (not embeddables)
// so Excalidraw handles click/drag/resize/wheel-pan-zoom natively. Overlay is
// fully `pointer-events: none` — mouse events flow through to Excalidraw.
//
// Selection sync: click on rect → Excalidraw native selection → Board's onChange
// handler reads selectedElementIds → updates sidebar.
// Drag/zoom: Excalidraw native. Card visuals track via sceneCoordsToViewportCoords.
// Jump to terminal: via sidebar's "Open terminal" button (no card-body dbl-click
// because that would require capturing events, breaking drag).
//
// Keying: each overlay item is keyed on element.id so copied rects get their
// own overlay instance — same session data via customData.sessionId.

import { useEffect, useState } from 'react'
import { sceneCoordsToViewportCoords } from '@excalidraw/excalidraw'
import type { ExcalidrawImperativeAPI } from '@excalidraw/excalidraw/types/types'

import type { BoardState, Session } from '../types'
import { parseSessionFromElement, RECT_W, RECT_H } from '../scene'
import { CardHost } from './CardHost'
import { DEFAULT_TEMPLATE } from '../defaultTemplate'
import { templateIdForPlugin } from '../cardTemplateStore'

interface Props {
  excalidrawAPI: ExcalidrawImperativeAPI | null
  state: BoardState | null
  templateCache: Record<string, string>
  onNeedTemplate: (pluginId: string) => void
}

// De-dup log tracker keyed by sid. Only fires when the source length changes
// for a given session so we don't flood the console on every animation frame.
const _lastLoggedSrcLen = new Map<string, number>()
function logSourceForSid(sid: string, tplId: string, source: string) {
  const prev = _lastLoggedSrcLen.get(sid)
  if (prev === source.length) return
  _lastLoggedSrcLen.set(sid, source.length)
  console.log(
    '[SessionOverlay] source resolved sid=%s tpl=%s len=%d firstLine=%s',
    sid.slice(0, 8),
    tplId,
    source.length,
    source.split('\n', 1)[0]?.slice(0, 60),
  )
}

interface OverlayItem {
  elementId: string
  session: Session
  source: string
  left: number
  top: number
  width: number
  height: number
}

export function SessionOverlay({
  excalidrawAPI,
  state,
  templateCache,
  onNeedTemplate,
}: Props) {
  const [, setTick] = useState(0)
  useEffect(() => {
    if (!excalidrawAPI) return
    const unsub = excalidrawAPI.onChange(() => {
      setTick((t) => (t + 1) & 0x7fffffff)
    })
    return () => {
      try { unsub() } catch { /* noop */ }
    }
  }, [excalidrawAPI])

  if (!excalidrawAPI || !state) return null

  const appState = excalidrawAPI.getAppState()
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

    // Official util for scene→viewport transform. Tracks pan + zoom correctly.
    const { x: left, y: top } = sceneCoordsToViewportCoords(
      { sceneX: el.x, sceneY: el.y },
      {
        zoom: appState.zoom,
        offsetLeft: 0,
        offsetTop: 0,
        scrollX: appState.scrollX,
        scrollY: appState.scrollY,
      },
    )

    // Width/height ARE scaled by zoom — cards should zoom with the canvas for
    // a true native-shape feel. User asked for this in Wave 19.
    const zoom = appState.zoom?.value || 1
    const width = (el.width || RECT_W) * zoom
    const height = (el.height || RECT_H) * zoom

    const overrideSource: string | undefined = (el as any).customData?.cardSource
    const tplId = templateIdForPlugin(session.pluginId)
    const cached = templateCache[tplId]
    if (cached === undefined && !overrideSource) {
      onNeedTemplate(session.pluginId)
    }
    const source = overrideSource ?? cached ?? DEFAULT_TEMPLATE
    // Fires once per (sid, len) combo — de-duped to avoid log spam. Useful
    // to check whether the source actually changed when you click a preset.
    logSourceForSid(session.id, tplId, source)

    overlayItems.push({
      elementId: el.id,
      session,
      source,
      left,
      top,
      width,
      height,
    })
  }

  return (
    <div
      className="session-overlay"
      style={{
        position: 'absolute',
        inset: 0,
        pointerEvents: 'none',  // crucial: let all mouse events reach Excalidraw
        overflow: 'hidden',
        // Excalidraw canvas sits at z-index:2. Overlay above so visuals show,
        // but events pass through thanks to pointer-events:none.
        zIndex: 3,
      }}
    >
      {overlayItems.map((it) => (
        <div
          key={it.elementId}
          className="session-overlay__item"
          style={{
            position: 'absolute',
            left: it.left,
            top: it.top,
            width: it.width,
            height: it.height,
            pointerEvents: 'none',
          }}
        >
          <div style={{
            pointerEvents: 'none',
            // Render card at base 360x260, CSS-scale to match zoom.
            // Font rendering stays crisp at any zoom level.
            transform: `scale(${it.width / RECT_W})`,
            transformOrigin: 'top left',
            width: RECT_W,
            height: RECT_H,
          }}>
            <CardHost
              sessionId={it.session.id}
              session={it.session}
              board={state}
              source={it.source}
            />
          </div>
        </div>
      ))}
    </div>
  )
}

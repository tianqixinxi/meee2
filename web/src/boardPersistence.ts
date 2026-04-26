// 画板的完整持久化：
//   - appState（viewport: scrollX/scrollY/zoom）→ meee2.board.appstate.v1
//   - 用户自己画的 non-session 元素 → meee2.board.user-shapes.v1
//
// Session card 的 *位置* 依旧在 layout.ts 的 meee2.board.layout.v1。Session
// card 本身由 Board.tsx 的 scene 副作用按 state.sessions 生成，不走这个文件。

import { parseSessionFromElement } from './scene'

const APPSTATE_KEY = 'meee2.board.appstate.v1'
const SHAPES_KEY = 'meee2.board.user-shapes.v1'

export interface PersistedAppState {
  scrollX: number
  scrollY: number
  zoom: number
}

export function loadAppState(): PersistedAppState | null {
  try {
    const raw = localStorage.getItem(APPSTATE_KEY)
    if (!raw) return null
    const p = JSON.parse(raw)
    if (
      typeof p?.scrollX === 'number' &&
      typeof p?.scrollY === 'number' &&
      typeof p?.zoom === 'number'
    ) {
      return p
    }
  } catch { /* ignore */ }
  return null
}

export function saveAppState(s: PersistedAppState): void {
  try {
    localStorage.setItem(APPSTATE_KEY, JSON.stringify(s))
  } catch { /* quota / private mode */ }
}

/** 非 session-rect 的元素（用户自己画的箭头、文字、矩形等）。类型宽松成
 *  `any[]` —— Excalidraw 的 element 类型是联合，这里不强绑，避免频繁升级。*/
export function loadUserShapes(): any[] {
  try {
    const raw = localStorage.getItem(SHAPES_KEY)
    if (!raw) return []
    const arr = JSON.parse(raw)
    if (Array.isArray(arr)) return arr
  } catch { /* ignore */ }
  return []
}

export function saveUserShapes(elements: readonly any[]): void {
  try {
    // 只留"非 managed"的元素。Managed = 由 scene 副作用从 state 重建的。
    // 排除规则：
    //   1. session rect (type=rectangle + customData.sessionId)
    //   2. id 以 `channel-` 开头的（hub ellipse、hub label `channel-X-label`、
    //      spoke arrow `channel-X-spoke-Y`）
    //   3. **text 元素 containerId 指向 managed 元素**（`channel-` / `session-`
    //      开头）：spoke arrow 用 `label:{...}` skeleton sugar 时 Excalidraw 给
    //      label 分配随机 id，不带 `channel-` 前缀，老规则漏过它们 → 进了
    //      localStorage → 下次刷新 spoke arrow 不在 storage（已被前缀排除），
    //      `existingSpokeIds` 空 → buildScene 又生成一份新 label → 画布累积。
    const keep = elements.filter((el: any) => {
      if (!el) return false
      if (el.isDeleted) return false
      if (el.type === 'rectangle' && parseSessionFromElement(el)) return false
      if (typeof el.id === 'string' && el.id.startsWith('channel-')) return false
      if (el.type === 'text') {
        const cid = el.containerId
        if (typeof cid === 'string' && (cid.startsWith('channel-') || cid.startsWith('session-'))) {
          return false
        }
      }
      return true
    })
    localStorage.setItem(SHAPES_KEY, JSON.stringify(keep))
  } catch { /* quota / private mode */ }
}

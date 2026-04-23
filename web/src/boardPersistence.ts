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
    // 只留"非 session rect"的元素；channel 箭头（id 以 channel- 开头）也
    // 由 Board 的 scene 副作用生成，排除。
    const keep = elements.filter((el: any) => {
      if (!el) return false
      if ((el as any).isDeleted) return false
      if (el.type === 'rectangle' && parseSessionFromElement(el)) return false
      if (typeof el.id === 'string' && el.id.startsWith('channel-')) return false
      return true
    })
    localStorage.setItem(SHAPES_KEY, JSON.stringify(keep))
  } catch { /* quota / private mode */ }
}

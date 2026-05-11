import { useCallback, useEffect, useRef, useState } from 'react'
import { connectEvents, fetchState } from './api'
import type { BoardState } from './types'
import { isOlderSession } from './types'

export interface BoardStateHook {
  state: BoardState | null
  loading: boolean
  error: string | null
  connected: boolean
  refresh: () => void
}

/**
 * Subscribes to /api/events and re-fetches /api/state on every frame (plus
 * initial fetch on mount). Auto-reconnects the socket.
 */
export function useBoardState(): BoardStateHook {
  const [state, setState] = useState<BoardState | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [connected, setConnected] = useState(false)
  const inFlight = useRef(false)
  const pendingRefetch = useRef(false)
  const pendingWhileHidden = useRef(false)
  const debounceTimer = useRef<number | null>(null)
  const hasState = useRef(false)
  // 上一次 setState 的 payload 指纹（JSON）。Claude 活跃时 WS 每秒 push 多次
  // state.changed，但绝大多数 tick 的内容没变——还是会让全 App 重渲一次。
  // 用 JSON.stringify 做快速 diff，不变就跳过 setState（新对象引用一旦进入
  // React 必然触发下游 rerender，哪怕 props 深度相等）。
  const lastSigRef = useRef<string>('')

  const refresh = useCallback(async () => {
    if (document.visibilityState === 'hidden' && hasState.current) {
      pendingWhileHidden.current = true
      return
    }
    if (inFlight.current) {
      pendingRefetch.current = true
      return
    }
    inFlight.current = true
    try {
      const s = await fetchState()
      // issue #25 诊断：抓 fetched state 的形状，配合服务端
      // [StateTrace][channelDTO] 判断 0-member 是否真的来自 server。
      // const zeroMembers = s.channels.filter((c) => c.members.length === 0).length
      // console.log(
      //   '[StateTrace][board-state] fetched: sessions=' + s.sessions.length +
      //   ' channels=' + s.channels.length +
      //   ', channels-with-zero-members=' + zeroMembers,
      // )
      // 快速指纹：排除频繁变但 UI 不直接看的字段（lastActivity 每秒都可能
      // bump）。如果 sessions 的关键字段 + channels 都没变，视作同态。
      const sig = signatureFor(s)
      if (sig !== lastSigRef.current) {
        lastSigRef.current = sig
        hasState.current = true
        setState(s)
      }
      setError(null)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setLoading(false)
      inFlight.current = false
      if (pendingRefetch.current) {
        pendingRefetch.current = false
        // queue a follow-up to collapse bursts
        debounceTimer.current = window.setTimeout(() => void refresh(), 750)
      }
    }
  }, [])

  const scheduleRefresh = useCallback(() => {
    if (document.visibilityState === 'hidden' && hasState.current) {
      pendingWhileHidden.current = true
      return
    }
    if (debounceTimer.current) {
      window.clearTimeout(debounceTimer.current)
    }
    debounceTimer.current = window.setTimeout(() => {
      debounceTimer.current = null
      void refresh()
    }, 750)
  }, [refresh])

  useEffect(() => {
    // initial fetch (WS will also fire one immediately on connect; that's fine)
    void refresh()
    const dispose = connectEvents(
      scheduleRefresh,
      (c) => setConnected(c),
    )
    const onVisible = () => {
      if (document.visibilityState !== 'visible' || !pendingWhileHidden.current) return
      pendingWhileHidden.current = false
      void refresh()
    }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      dispose()
      document.removeEventListener('visibilitychange', onVisible)
      if (debounceTimer.current) {
        window.clearTimeout(debounceTimer.current)
        debounceTimer.current = null
      }
    }
  }, [refresh, scheduleRefresh])

  return { state, loading, error, connected, refresh }
}

/**
 * 计算 BoardState 的内容指纹。故意排除"churny" 字段（lastActivity、
 * startedAt —— 这些每个 WS tick 都在刷新但 UI 不直接渲染它们）。
 * 只对"真变了用户才关心"的字段做比对：sessions 的 id/status/title/project/
 * currentTool/inboxPending/pendingPermissionTool/older(派生)/recentMessages、channels。
 *
 * `older` 改成前端从 lastActivity 派生（isOlderSession）。在 signature 里
 * 记录其布尔值，确保 1h 阈值翻越时下游 UI 能拿到 new state 触发重渲。
 */
function signatureFor(s: BoardState): string {
  const slim = {
    sessions: s.sessions.map((x) => ({
      id: x.id,
      title: x.title,
      project: x.project,
      status: x.status,
      currentTool: x.currentTool,
      inboxPending: x.inboxPending,
      pendingPermissionTool: x.pendingPermissionTool,
      older: isOlderSession(x),
      // recentMessages 里每条 text 是最后 200 字，内容变了才代表"有新消息"
      recent: x.recentMessages?.map((m) => `${m.role}:${m.text}`).join('|'),
    })),
    channels: s.channels.map((c) => ({
      name: c.name,
      mode: c.mode,
      pendingCount: c.pendingCount,
      memberCount: c.members.length,
      members: c.members.map((m) => `${m.sessionId}:${m.alias}`).sort(),
    })),
  }
  return JSON.stringify(slim)
}

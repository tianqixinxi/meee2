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
  /**
   * Fetch + commit fresh state immediately, bypassing the visibility/in-flight
   * guards that `refresh` applies. Use when an explicit user action needs the
   * latest server state *right now* — e.g. jumping to a session that was just
   * dispatched, where the normal event-driven refresh may not have landed yet
   * (or the WS dropped during the dispatch). Without this, the jump target can
   * be absent from the session list and the workspace shows nothing.
   */
  forceRefresh: () => Promise<void>
}

/**
 * Subscribes to /api/events and re-fetches /api/state on every frame (plus
 * initial fetch on mount). Auto-reconnects the socket.
 */
export function useBoardState(onStateChangedEvent?: () => void): BoardStateHook {
  const [state, setState] = useState<BoardState | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [connected, setConnected] = useState(false)
  const inFlight = useRef(false)
  const pendingRefetch = useRef(false)
  const pendingWhileHidden = useRef(false)
  const burstRefetchTimer = useRef<number | null>(null)
  const hasState = useRef(false)
  // 上一次 setState 的 payload 指纹（JSON）。Claude 活跃时 WS 每秒 push 多次
  // state.changed，但绝大多数 tick 的内容没变——还是会让全 App 重渲一次。
  // 用 JSON.stringify 做快速 diff，不变就跳过 setState（新对象引用一旦进入
  // React 必然触发下游 rerender，哪怕 props 深度相等）。
  const lastSigRef = useRef<string>('')
  // 请求代际:每次 fetch(refresh / forceRefresh)发起前领一个单调递增序号,响应
  // 回来时只有「迄今最新发起」的请求能 commit。防止 forceRefresh 与 in-flight
  // refresh 并发时,更早发起的 refresh 响应后到、用 stale 快照覆盖掉刚强制刷新的
  // 结果(lastSigRef 只挡内容相同,挡不住旧响应覆盖新响应)。
  const fetchSeqRef = useRef(0)
  const committedSeqRef = useRef(0)

  // 按代际提交:seq 比已提交的更旧(更早发起却后到)就丢弃,避免 stale 覆盖。
  const commitState = useCallback((s: BoardState, seq: number) => {
    if (seq < committedSeqRef.current) return
    committedSeqRef.current = seq
    const sig = signatureFor(s)
    if (sig !== lastSigRef.current) {
      lastSigRef.current = sig
      hasState.current = true
      setState(s)
    }
  }, [])

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
    const seq = ++fetchSeqRef.current
    try {
      const s = await fetchState()
      commitState(s, seq)
      setError(null)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setLoading(false)
      inFlight.current = false
      if (pendingRefetch.current) {
        pendingRefetch.current = false
        // queue a follow-up to collapse bursts
        burstRefetchTimer.current = window.setTimeout(() => {
          burstRefetchTimer.current = null
          void refresh()
        }, 160)
      }
    }
  }, [commitState])

  // Unguarded sibling of `refresh`: always fetches and commits immediately (no
  // in-flight/visibility guard). Intended for explicit navigations (open-session)
  // where staleness shows up as an empty workspace. Concurrency with an in-flight
  // `refresh` is handled by the seq gate in `commitState`: the latest-*issued*
  // fetch wins, so an older refresh that resolves late can no longer clobber the
  // freshly forced snapshot (which would make a just-created session disappear).
  const forceRefresh = useCallback(async () => {
    const seq = ++fetchSeqRef.current
    try {
      const s = await fetchState()
      commitState(s, seq)
      setError(null)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [commitState])

  const scheduleRefresh = useCallback(() => {
    if (document.visibilityState === 'hidden' && hasState.current) {
      pendingWhileHidden.current = true
      return
    }
    onStateChangedEvent?.()
    if (burstRefetchTimer.current !== null) {
      window.clearTimeout(burstRefetchTimer.current)
      burstRefetchTimer.current = null
    }
    void refresh()
  }, [onStateChangedEvent, refresh])

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
      onStateChangedEvent?.()
      void refresh()
    }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      dispose()
      document.removeEventListener('visibilitychange', onVisible)
      if (burstRefetchTimer.current) {
        window.clearTimeout(burstRefetchTimer.current)
        burstRefetchTimer.current = null
      }
    }
  }, [onStateChangedEvent, refresh, scheduleRefresh])

  return { state, loading, error, connected, refresh, forceRefresh }
}

/**
 * 计算 BoardState 的内容指纹。故意排除"churny" 字段（lastActivity、
 * startedAt —— 这些每个 WS tick 都在刷新但 UI 不直接渲染它们）。
 * 只对"真变了用户才关心"的字段做比对：sessions 的 id/status/title/project/
 * terminal surface identity/lifecycle/currentTool/inboxPending/
 * pendingPermissionTool/older(派生)/recentMessages、channels。
 *
 * `older` 改成前端从 lastActivity 派生（isOlderSession）。在 signature 里
 * 记录其布尔值，确保 1h 阈值翻越时下游 UI 能拿到 new state 触发重渲。
 */
function signatureFor(s: BoardState): string {
  const sessions = Array.isArray(s.sessions) ? s.sessions : []
  const channels = Array.isArray(s.channels) ? s.channels : []
  const slim = {
    sessions: sessions.map((x) => ({
      id: x.id,
      title: x.title,
      project: x.project,
      status: x.status,
      terminalKind: x.terminalKind,
      terminalBackend: x.terminalBackend,
      openTarget: x.openTarget,
      surfaceId: x.surfaceId,
      surfaceStatus: x.surfaceStatus,
      canOpenExternal: x.canOpenExternal,
      currentTool: x.currentTool,
      inboxPending: x.inboxPending,
      pendingPermissionTool: x.pendingPermissionTool,
      older: isOlderSession(x),
      // recentMessages 里每条 text 是最后 200 字，内容变了才代表"有新消息"
      recent: x.recentMessages?.map((m) => `${m.role}:${m.text}`).join('|'),
    })),
    channels: channels.map((c) => ({
      name: c.name,
      mode: c.mode,
      pendingCount: c.pendingCount,
      memberCount: Array.isArray(c.members) ? c.members.length : 0,
      members: Array.isArray(c.members) ? c.members.map((m) => `${m.sessionId}:${m.alias}`).sort() : [],
    })),
  }
  return JSON.stringify(slim)
}

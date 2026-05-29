import { useCallback, useEffect, useLayoutEffect, useMemo, useRef } from 'react'
import { syncNativeSessionsWorkspace, type NativeTerminalRect } from '../api'
import { useI18n } from '../lib/i18n'
import type { BoardState, Session } from '../types'

interface Props {
  state: BoardState | null
  selectedSessionId?: string | null
}

export function NativeSessionsWorkspaceHost({ state, selectedSessionId }: Props) {
  const { t } = useI18n()
  const hostRef = useRef<HTMLDivElement | null>(null)
  const lastRectRef = useRef<NativeTerminalRect | null>(null)
  const visibleSessions = useMemo(() => (
    (state?.sessions ?? [])
      .filter((session) => session.openTarget === 'native-workspace' || session.nativeWorkspaceAvailable === true)
      .slice(0, 12)
  ), [state?.sessions])
  const selectedSession = useMemo(() => {
    const id = selectedSessionId?.trim()
    if (!id) return null
    return (state?.sessions ?? []).find((session) => (
      session.id === id || session.surfaceId === id
    )) ?? null
  }, [selectedSessionId, state?.sessions])
  const target = useMemo(() => {
    const resolved = nativeTargetForSession(selectedSession)
    if (resolved.sessionId || resolved.surfaceId) return resolved
    const fallbackId = selectedSessionId?.trim()
    if (fallbackId) return { sessionId: fallbackId }
    const pending = window.__meee2PendingSessionsWorkspace
    return pending?.sessionId || pending?.surfaceId
      ? { sessionId: pending.sessionId, surfaceId: pending.surfaceId }
      : {}
  }, [selectedSession, selectedSessionId])

  const sync = useCallback((phase: 'show' | 'layout' | 'focus' = 'layout') => {
    const host = hostRef.current
    if (!host) return
    const rect = host.getBoundingClientRect()
    const nextRect = {
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: rect.height,
    }
    if (phase === 'layout' && sameRect(lastRectRef.current, nextRect)) return
    lastRectRef.current = nextRect
    syncNativeSessionsWorkspace({
      phase,
      rect: nextRect,
      sessionId: target.sessionId,
      surfaceId: target.surfaceId,
    })
    if (target.sessionId || target.surfaceId) {
      window.__meee2PendingSessionsWorkspace = null
    }
  }, [target.sessionId, target.surfaceId])

  useLayoutEffect(() => {
    sync('show')
    const host = hostRef.current
    if (!host) return undefined
    const resizeObserver = new ResizeObserver(() => sync('layout'))
    resizeObserver.observe(host)
    const handleWindowLayout = () => sync('layout')
    window.addEventListener('resize', handleWindowLayout)
    window.addEventListener('meee2:layout-native-sessions-workspace', handleWindowLayout)
    return () => {
      resizeObserver.disconnect()
      window.removeEventListener('resize', handleWindowLayout)
      window.removeEventListener('meee2:layout-native-sessions-workspace', handleWindowLayout)
      syncNativeSessionsWorkspace({ phase: 'hide' })
      lastRectRef.current = null
    }
  }, [sync])

  useEffect(() => {
    if (!target.sessionId && !target.surfaceId) return
    sync('focus')
  }, [sync])

  return (
    <section className="native-sessions-workspace-host" aria-label={t('sessions.title')}>
      <div ref={hostRef} className="native-sessions-workspace-host__surface" />
      <div className="native-sessions-workspace-host__fallback" aria-hidden>
        <aside className="native-sessions-workspace-host__rail">
          <div className="native-sessions-workspace-host__rail-header">
            <strong>{t('sessions.title')}</strong>
            <span>{visibleSessions.length}</span>
          </div>
          <div className="native-sessions-workspace-host__rows">
            {visibleSessions.map((session) => (
              <div
                key={session.id}
                className={[
                  'native-sessions-workspace-host__row',
                  session.id === selectedSession?.id ? 'is-selected' : '',
                ].filter(Boolean).join(' ')}
              >
                <span>{session.title || session.pluginDisplayName || 'Session'}</span>
                <small>{session.status} · {shortSessionId(session.id)}</small>
              </div>
            ))}
          </div>
        </aside>
        <main className="native-sessions-workspace-host__terminal">
          <span>{t('sessions.nativeWorkspaceSummary')}</span>
        </main>
      </div>
    </section>
  )
}

function nativeTargetForSession(session: Session | null): { sessionId?: string; surfaceId?: string } {
  if (!session) return {}
  if (session.openTarget !== 'native-workspace' && session.nativeWorkspaceAvailable !== true) return {}
  return {
    sessionId: session.id,
    surfaceId: session.surfaceId ?? undefined,
  }
}

function sameRect(a: NativeTerminalRect | null, b: NativeTerminalRect): boolean {
  if (!a) return false
  return Math.abs(a.x - b.x) < 0.5
    && Math.abs(a.y - b.y) < 0.5
    && Math.abs(a.width - b.width) < 0.5
    && Math.abs(a.height - b.height) < 0.5
}

function shortSessionId(value: string): string {
  return value.length > 12 ? `${value.slice(0, 12)}...` : value
}

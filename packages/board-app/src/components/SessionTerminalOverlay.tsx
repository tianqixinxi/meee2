import { ExternalLink, Terminal as TerminalIcon, X } from 'lucide-react'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef } from 'react'
import { syncNativeSessionsWorkspace, type NativeTerminalRect } from '../api'
import { useI18n } from '../lib/i18n'
import {
  nativeTerminalTargetForSession,
  type SessionOpenTarget,
} from '../lib/sessionTerminal'
import type { CanvasInfo, Session } from '../types'

interface Props {
  target: SessionOpenTarget
  session: Session | null
  canvas: CanvasInfo | null
  onClose: () => void
}

export function SessionTerminalOverlay({
  target,
  session,
  canvas,
  onClose,
}: Props) {
  const { t } = useI18n()
  const terminalHostRef = useRef<HTMLDivElement | null>(null)
  const layoutFrameRef = useRef<number | null>(null)
  const layoutTimerRefs = useRef<number[]>([])
  const lastRectRef = useRef<NativeTerminalRect | null>(null)
  const latestSyncRef = useRef<(phase?: 'show' | 'layout' | 'focus', options?: { force?: boolean }) => void>(() => {})
  const switchStartedAtRef = useRef(Date.now())
  const traceIdRef = useRef(`overlay-${(target.sessionId || target.surfaceId || 'unknown').slice(0, 8)}-${switchStartedAtRef.current.toString(36)}`)
  const terminalTarget = useMemo(() => {
    const liveTarget = nativeTerminalTargetForSession(session)
    if (liveTarget.sessionId || liveTarget.surfaceId) return liveTarget
    return {
      sessionId: target.sessionId,
      surfaceId: target.surfaceId,
    }
  }, [session, target.sessionId, target.surfaceId])

  const syncTerminal = useCallback((phase: 'show' | 'layout' | 'focus' = 'layout', options?: { force?: boolean }) => {
    const host = terminalHostRef.current
    if (!host) return
    if (!terminalTarget.sessionId && !terminalTarget.surfaceId) {
      syncNativeSessionsWorkspace({
        phase: 'hide',
        mode: 'terminal',
        traceId: traceIdRef.current,
        clickStartedAtMs: switchStartedAtRef.current,
        sentAtMs: Date.now(),
        webPhase: 'overlay.hide',
      })
      lastRectRef.current = null
      return
    }
    const rect = host.getBoundingClientRect()
    const nextRect = {
      x: Math.round(rect.left),
      y: Math.round(rect.top),
      width: Math.round(rect.width),
      height: Math.round(rect.height),
    }
    if (phase === 'layout' && !options?.force && sameRect(lastRectRef.current, nextRect)) return
    lastRectRef.current = nextRect
    const sentAtMs = Date.now()
    syncNativeSessionsWorkspace({
      phase,
      mode: 'terminal',
      rect: nextRect,
      sessionId: terminalTarget.sessionId,
      surfaceId: terminalTarget.surfaceId,
      traceId: traceIdRef.current,
      clickStartedAtMs: switchStartedAtRef.current,
      sentAtMs,
      webPhase: `overlay.${phase}`,
    })
  }, [terminalTarget.sessionId, terminalTarget.surfaceId])

  useEffect(() => {
    latestSyncRef.current = syncTerminal
  }, [syncTerminal])

  const scheduleLayout = useCallback(() => {
    if (layoutFrameRef.current !== null) return
    layoutFrameRef.current = window.requestAnimationFrame(() => {
      layoutFrameRef.current = null
      latestSyncRef.current('layout')
    })
  }, [])

  const scheduleStabilizedLayouts = useCallback(() => {
    layoutTimerRefs.current.forEach((timer) => window.clearTimeout(timer))
    layoutTimerRefs.current = [40, 140, 320].map((delay) => window.setTimeout(() => {
      latestSyncRef.current('layout', { force: true })
    }, delay))
  }, [])

  useLayoutEffect(() => {
    syncTerminal('show')
    scheduleStabilizedLayouts()
    const host = terminalHostRef.current
    if (!host) return undefined
    const resizeObserver = new ResizeObserver(() => scheduleLayout())
    resizeObserver.observe(host)
    const handleWindowLayout = () => scheduleLayout()
    window.addEventListener('resize', handleWindowLayout)
    window.addEventListener('meee2:layout-native-sessions-workspace', handleWindowLayout)
    return () => {
      if (layoutFrameRef.current !== null) {
        window.cancelAnimationFrame(layoutFrameRef.current)
        layoutFrameRef.current = null
      }
      layoutTimerRefs.current.forEach((timer) => window.clearTimeout(timer))
      layoutTimerRefs.current = []
      resizeObserver.disconnect()
      window.removeEventListener('resize', handleWindowLayout)
      window.removeEventListener('meee2:layout-native-sessions-workspace', handleWindowLayout)
      syncNativeSessionsWorkspace({ phase: 'hide', mode: 'terminal' })
      lastRectRef.current = null
    }
  }, [scheduleLayout, scheduleStabilizedLayouts, syncTerminal])

  useEffect(() => {
    syncTerminal('focus')
    scheduleStabilizedLayouts()
  }, [scheduleStabilizedLayouts, syncTerminal])

  const title = session?.title || target.sessionId || target.surfaceId || t('sessions.terminal')
  const status = session?.surfaceStatus || session?.status || t('sessions.pendingSelectedSession', { id: title.slice(0, 8) })
  const canvasName = canvas?.name?.trim() || t('rail.monitor')
  const hasTarget = Boolean(terminalTarget.sessionId || terminalTarget.surfaceId)

  return (
    <section className="session-terminal-overlay" role="presentation">
      <div className="session-terminal-overlay__scrim" aria-hidden onMouseDown={onClose} />
      <div
        className="session-terminal-overlay__panel"
        role="dialog"
        aria-modal="true"
        aria-label={t('sessions.terminal')}
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="session-terminal-overlay__header">
          <div className="session-terminal-overlay__title">
            <TerminalIcon size={15} aria-hidden />
            <strong>{title}</strong>
            <span className={`session-terminal-overlay__status is-${statusTone(status)}`}>{status}</span>
          </div>
          <button
            type="button"
            className="session-terminal-overlay__close"
            onClick={onClose}
            aria-label={t('common.close')}
            title={t('common.close')}
          >
            <X size={16} aria-hidden />
          </button>
        </header>
        <main className="session-terminal-overlay__body">
          <div ref={terminalHostRef} className="session-terminal-overlay__surface" aria-label={`${title} · ${canvasName}`} />
          {!hasTarget && (
            <div className="session-terminal-overlay__placeholder">
              <ExternalLink size={18} aria-hidden />
              <span>{t('sessions.nativeTerminalUnavailable')}</span>
            </div>
          )}
        </main>
      </div>
    </section>
  )
}

function statusTone(status: string): 'running' | 'idle' | 'failed' | 'default' {
  const lower = status.toLowerCase()
  if (lower.includes('running') || lower.includes('starting') || lower.includes('tool')) return 'running'
  if (lower.includes('idle') || lower.includes('done') || lower.includes('exited')) return 'idle'
  if (lower.includes('fail') || lower.includes('blocked') || lower.includes('error')) return 'failed'
  return 'default'
}

function sameRect(a: NativeTerminalRect | null, b: NativeTerminalRect): boolean {
  if (!a) return false
  return Math.abs(a.x - b.x) < 0.5
    && Math.abs(a.y - b.y) < 0.5
    && Math.abs(a.width - b.width) < 0.5
    && Math.abs(a.height - b.height) < 0.5
}

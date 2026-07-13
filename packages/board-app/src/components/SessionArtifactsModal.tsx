import { Archive, ExternalLink, FileText, Loader2 } from 'lucide-react'
import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { fetchSessionArtifacts, syncNativeSessionsWorkspace } from '../api'
import type { PlannerArtifact, SessionArtifactsEnvelope } from '../types'
import { useI18n } from '../lib/i18n'

export interface SessionArtifactsModalTarget {
  sessionId: string
  title: string
  providerResumeSessionId?: string | null
  surfaceId?: string | null
  project?: string | null
  projectName?: string | null
}

interface SessionArtifactsModalProps {
  target: SessionArtifactsModalTarget
  onClose: () => void
  onChanged?: () => void
  onOpenDetails?: (target: SessionArtifactsModalTarget) => void
}

interface SessionArtifactsPanelProps {
  target: SessionArtifactsModalTarget
  onChanged?: () => void
  onOpenDetails?: (target: SessionArtifactsModalTarget) => void
  className?: string
}

const SESSION_ARTIFACTS_CACHE_TTL_MS = 5_000
const SESSION_ARTIFACTS_CACHE_LIMIT = 24

type SessionArtifactsCacheEntry = {
  data: SessionArtifactsEnvelope
  fetchedAt: number
}

const sessionArtifactsCache = new Map<string, SessionArtifactsCacheEntry>()
const sessionArtifactsRequests = new Map<string, Promise<SessionArtifactsEnvelope>>()

function cacheSessionArtifactsData(sessionId: string, data: SessionArtifactsEnvelope): SessionArtifactsEnvelope {
  sessionArtifactsCache.delete(sessionId)
  sessionArtifactsCache.set(sessionId, { data, fetchedAt: Date.now() })
  while (sessionArtifactsCache.size > SESSION_ARTIFACTS_CACHE_LIMIT) {
    const oldestSessionId = sessionArtifactsCache.keys().next().value
    if (!oldestSessionId) break
    sessionArtifactsCache.delete(oldestSessionId)
  }
  return data
}

function requestSessionArtifacts(sessionId: string): Promise<SessionArtifactsEnvelope> {
  const cached = sessionArtifactsCache.get(sessionId)
  if (cached && Date.now() - cached.fetchedAt < SESSION_ARTIFACTS_CACHE_TTL_MS) {
    return Promise.resolve(cached.data)
  }
  const pending = sessionArtifactsRequests.get(sessionId)
  if (pending) return pending

  const request = fetchSessionArtifacts(sessionId)
    .then((data) => {
      return cacheSessionArtifactsData(sessionId, data)
    })
    .finally(() => sessionArtifactsRequests.delete(sessionId))
  sessionArtifactsRequests.set(sessionId, request)
  return request
}

export function prefetchSessionArtifacts(sessionId: string): void {
  void requestSessionArtifacts(sessionId).catch(() => undefined)
}

export function invalidateSessionArtifactsCache(sessionId?: string): void {
  if (sessionId) sessionArtifactsCache.delete(sessionId)
  else sessionArtifactsCache.clear()
}

export function SessionArtifactsPanel({ target, onOpenDetails, className }: SessionArtifactsPanelProps) {
  const { t } = useI18n()
  const initialData = sessionArtifactsCache.get(target.sessionId)?.data ?? null
  const [data, setData] = useState<SessionArtifactsEnvelope | null>(initialData)
  const [loading, setLoading] = useState(initialData === null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const cached = sessionArtifactsCache.get(target.sessionId)?.data ?? null
    setData(cached)
    setLoading(cached === null)
    setError(null)
    requestSessionArtifacts(target.sessionId)
      .then((next) => {
        if (!cancelled) setData(next)
      })
      .catch((err) => {
        if (!cancelled) setError((err as Error).message || t('artifacts.loadFailed'))
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [target.sessionId, t])

  return (
    <div className={['session-artifacts-panel', className].filter(Boolean).join(' ')}>
      <header className="session-artifacts-modal__header">
        <h2>{t('artifacts.title')}</h2>
        {onOpenDetails && (
          <button
            type="button"
            className="session-artifacts-modal__details-button"
            onClick={() => onOpenDetails(target)}
          >
            <ExternalLink size={14} aria-hidden />
            <span>{t('artifacts.openDetailsPage')}</span>
          </button>
        )}
      </header>

      {error && <div className="session-artifacts-modal__error" role="status">{error}</div>}

      {loading ? (
        <div className="session-artifacts-modal__empty" role="status">
          <Loader2 size={15} className="spin" aria-hidden />
          <span>{t('artifacts.loading')}</span>
        </div>
      ) : !data || data.totalCount === 0 ? (
        <div className="session-artifacts-modal__empty">
          <Archive size={16} aria-hidden />
          <span>{t('artifacts.empty')}</span>
        </div>
      ) : (
        <div className="session-artifacts-modal__body">
          <section>
            <h3>{t('artifacts.attachedArtifacts')}</h3>
            {data.artifacts.length === 0 ? (
              <div className="session-artifacts-modal__empty compact">{t('artifacts.noAttachedArtifacts')}</div>
            ) : (
              <div className="session-artifacts-list">
                {data.artifacts.map((artifact) => (
                  <AttachedArtifactRow artifact={artifact} key={artifact.id} />
                ))}
              </div>
            )}
          </section>
        </div>
      )}
    </div>
  )
}

export function SessionArtifactsModal({ target, onClose, onChanged, onOpenDetails }: SessionArtifactsModalProps) {
  const { t } = useI18n()

  useEffect(() => {
    syncNativeSessionsWorkspace({
      phase: 'obscure',
      mode: 'terminal',
      webPhase: 'sessionArtifactsModal.obscureNativeTerminal',
    })
    return () => {
      window.dispatchEvent(new Event('meee2:restore-native-sessions-workspace'))
      window.dispatchEvent(new Event('meee2:layout-native-sessions-workspace'))
    }
  }, [])

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [onClose])

  return createPortal(
    <div className="session-artifacts-modal-backdrop" role="presentation" onClick={onClose}>
      <section
        className="session-artifacts-modal"
        role="dialog"
        aria-modal="true"
        aria-label={t('artifacts.sessionModalTitle', { title: target.title })}
        onClick={(event) => event.stopPropagation()}
      >
        <SessionArtifactsPanel
          target={target}
          onChanged={onChanged}
          onOpenDetails={onOpenDetails}
          className="session-artifacts-panel--modal"
        />
      </section>
    </div>,
    document.body,
  )
}

function AttachedArtifactRow({ artifact }: { artifact: PlannerArtifact }) {
  const { t } = useI18n()
  return (
    <article className="session-artifact-row">
      <div className="session-artifact-row__main">
        <div className="session-artifact-row__title">
          <span className="session-artifact-row__badge attached">{t('artifacts.attachedArtifacts')}</span>
          <strong>{artifact.title}</strong>
        </div>
        <div className="session-artifact-row__meta inline">
          <span>{artifact.kind}</span>
          <time>{formatDate(artifact.createdAt)}</time>
        </div>
        <p>{artifact.reference}</p>
      </div>
      <div className="session-artifact-row__actions">
        <button
          type="button"
          aria-label={t('artifacts.open')}
          title={t('artifacts.open')}
          onClick={() => openReference(artifact.reference)}
        >
          <FileText size={14} aria-hidden />
          <span>{t('artifacts.open')}</span>
        </button>
      </div>
    </article>
  )
}

function openReference(value: string) {
  if (/^https?:\/\//i.test(value) || /^file:\/\//i.test(value)) {
    window.open(value, '_blank', 'noopener,noreferrer')
    return
  }
  if (value.startsWith('/')) {
    window.open(`file://${value}`, '_blank', 'noopener,noreferrer')
  }
}

function formatDate(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

import { Archive, CheckCircle2, ExternalLink, FileText, Loader2, Trash2 } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import {
  discardArtifactCandidate,
  fetchSessionArtifacts,
  promoteArtifactCandidate,
  syncNativeSessionsWorkspace,
} from '../api'
import type {
  PlannerArtifact,
  SessionArtifactCandidate,
  SessionArtifactsEnvelope,
} from '../types'
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

export function SessionArtifactsPanel({ target, onChanged, onOpenDetails, className }: SessionArtifactsPanelProps) {
  const { t } = useI18n()
  const initialData = sessionArtifactsCache.get(target.sessionId)?.data ?? null
  const [data, setData] = useState<SessionArtifactsEnvelope | null>(initialData)
  const [loading, setLoading] = useState(initialData === null)
  const [error, setError] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)

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

  const handlePromote = useCallback((candidate: SessionArtifactCandidate) => {
    if (busyId) return
    setBusyId(candidate.id)
    promoteArtifactCandidate(candidate.id)
      .then((result) => {
        setData((current) => {
          if (!current) return current
          const candidates = current.candidates.filter((item) => item.id !== candidate.id)
          const artifacts = result.artifact
            ? [result.artifact, ...current.artifacts.filter((item) => item.id !== result.artifact?.id)]
            : current.artifacts
          return cacheSessionArtifactsData(target.sessionId, {
            ...current,
            candidates,
            artifacts,
            totalCount: candidates.length + artifacts.length,
            attachTargets: result.attachTargets.length > 0 ? result.attachTargets : current.attachTargets,
          })
        })
        window.dispatchEvent(new CustomEvent('meee2:session-artifacts-changed', {
          detail: { sessionId: target.sessionId, candidateId: candidate.id, action: 'promote' },
        }))
        onChanged?.()
      })
      .catch((err) => setError((err as Error).message || t('artifacts.promoteFailed')))
      .finally(() => setBusyId(null))
  }, [busyId, onChanged, t, target.sessionId])

  const handleDiscard = useCallback((candidate: SessionArtifactCandidate) => {
    if (busyId) return
    setBusyId(candidate.id)
    discardArtifactCandidate(candidate.id)
      .then(() => {
        setData((current) => {
          if (!current) return current
          const candidates = current.candidates.filter((item) => item.id !== candidate.id)
          return cacheSessionArtifactsData(target.sessionId, {
            ...current,
            candidates,
            totalCount: candidates.length + current.artifacts.length,
          })
        })
        window.dispatchEvent(new CustomEvent('meee2:session-artifacts-changed', {
          detail: { sessionId: target.sessionId, candidateId: candidate.id, action: 'discard' },
        }))
        onChanged?.()
      })
      .catch((err) => setError((err as Error).message || t('artifacts.discardFailed')))
      .finally(() => setBusyId(null))
  }, [busyId, onChanged, t, target.sessionId])

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
            <h3>{t('artifacts.candidates')}</h3>
            {data.candidates.length === 0 ? (
              <div className="session-artifacts-modal__empty compact">{t('artifacts.noCandidates')}</div>
            ) : (
              <div className="session-artifacts-list">
                {data.candidates.map((candidate) => (
                    <CandidateRow
                      key={candidate.id}
                      candidate={candidate}
                      busy={busyId === candidate.id}
                      onPromote={() => handlePromote(candidate)}
                      onDiscard={() => handleDiscard(candidate)}
                    />
                ))}
              </div>
            )}
          </section>

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

function CandidateRow({
  candidate,
  busy,
  onPromote,
  onDiscard,
}: {
  candidate: SessionArtifactCandidate
  busy: boolean
  onPromote: () => void
  onDiscard: () => void
}) {
  const { t } = useI18n()
  const source = [candidate.toolName, candidate.sourceEvent, candidate.kind].filter(Boolean).join(' · ')
  return (
    <article className="session-artifact-row">
      <div className="session-artifact-row__main">
        <div className="session-artifact-row__title">
          <span className="session-artifact-row__badge">{t('artifacts.candidate')}</span>
          <strong>{candidate.title}</strong>
        </div>
        <div className="session-artifact-row__meta inline">
          <span>{source}</span>
          <time>{formatDate(candidate.createdAt)}</time>
        </div>
        <p>{candidate.summary}</p>
        <ReferenceList references={candidate.references} />
      </div>
      <div className="session-artifact-row__actions">
        <button
          type="button"
          aria-label={t('artifacts.promote')}
          title={t('artifacts.promote')}
          onClick={onPromote}
          disabled={busy}
        >
          {busy ? <Loader2 size={14} className="spin" aria-hidden /> : <CheckCircle2 size={14} aria-hidden />}
          <span>{t('artifacts.promote')}</span>
        </button>
        <button
          type="button"
          className="danger"
          aria-label={t('artifacts.discard')}
          title={t('artifacts.discard')}
          onClick={onDiscard}
          disabled={busy}
        >
          <Trash2 size={14} aria-hidden />
          <span>{t('artifacts.discard')}</span>
        </button>
      </div>
    </article>
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

function ReferenceList({ references }: { references: SessionArtifactCandidate['references'] }) {
  if (references.length === 0) return null
  return (
    <div className="session-artifact-row__refs">
      {references.map((reference, index) => (
        <button
          type="button"
          key={`${reference.kind}:${reference.value}:${index}`}
          title={reference.value}
          onClick={() => openReference(reference.value)}
        >
          <ExternalLink size={12} aria-hidden />
          <span>{reference.label ?? reference.value}</span>
        </button>
      ))}
    </div>
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

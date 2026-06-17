import { Archive, CheckCircle2, ExternalLink, FileText, Loader2, Trash2 } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { createPortal } from 'react-dom'
import {
  discardArtifactCandidate,
  fetchSessionArtifacts,
  promoteArtifactCandidate,
  syncNativeSessionsWorkspace,
} from '../api'
import type {
  PlannerArtifact,
  SessionArtifactAttachTarget,
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
}

export function SessionArtifactsModal({ target, onClose, onChanged }: SessionArtifactsModalProps) {
  const { t } = useI18n()
  const [data, setData] = useState<SessionArtifactsEnvelope | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [selectedTargetKey, setSelectedTargetKey] = useState<string>('')

  const load = useCallback(() => {
    setLoading(true)
    setError(null)
    fetchSessionArtifacts(target.sessionId)
      .then((next) => {
        setData(next)
        const first = next.attachTargets[0]
        setSelectedTargetKey(first ? targetKey(first) : '')
      })
      .catch((err) => setError((err as Error).message || t('artifacts.loadFailed')))
      .finally(() => setLoading(false))
  }, [target.sessionId, t])

  useEffect(() => {
    load()
  }, [load])

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

  const selectedTarget = useMemo(
    () => data?.attachTargets.find((item) => targetKey(item) === selectedTargetKey) ?? null,
    [data?.attachTargets, selectedTargetKey],
  )

  const handlePromote = useCallback((candidate: SessionArtifactCandidate) => {
    if (busyId) return
    const attachTargets = data?.attachTargets ?? []
    const explicitTarget = attachTargets.length === 1 ? attachTargets[0] : selectedTarget
    if (!explicitTarget) {
      setError(t('artifacts.chooseAttachTarget'))
      return
    }
    setBusyId(candidate.id)
    promoteArtifactCandidate(candidate.id, {
      canvasId: explicitTarget.canvasId,
      nodeId: explicitTarget.nodeId,
    })
      .then(() => {
        onChanged?.()
        load()
      })
      .catch((err) => setError((err as Error).message || t('artifacts.promoteFailed')))
      .finally(() => setBusyId(null))
  }, [busyId, data?.attachTargets, load, onChanged, selectedTarget, t])

  const handleDiscard = useCallback((candidate: SessionArtifactCandidate) => {
    if (busyId) return
    setBusyId(candidate.id)
    discardArtifactCandidate(candidate.id)
      .then(() => {
        onChanged?.()
        load()
      })
      .catch((err) => setError((err as Error).message || t('artifacts.discardFailed')))
      .finally(() => setBusyId(null))
  }, [busyId, load, onChanged, t])

  const body = (
    <div className="session-artifacts-modal-backdrop" role="presentation" onClick={onClose}>
      <section
        className="session-artifacts-modal"
        role="dialog"
        aria-modal="true"
        aria-label={t('artifacts.sessionModalTitle', { title: target.title })}
        onClick={(event) => event.stopPropagation()}
      >
        <header className="session-artifacts-modal__header">
          <div>
            <span>{target.title}</span>
            <h2>{t('artifacts.sessionModalHeading', { count: data?.totalCount ?? 0 })}</h2>
          </div>
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
            {data.attachTargets.length > 1 && (
              <label className="session-artifacts-modal__target">
                <span>{t('artifacts.attachTarget')}</span>
                <select value={selectedTargetKey} onChange={(event) => setSelectedTargetKey(event.target.value)}>
                  {data.attachTargets.map((item) => (
                    <option value={targetKey(item)} key={targetKey(item)}>
                      {item.canvasName} / {item.nodeTitle}
                    </option>
                  ))}
                </select>
              </label>
            )}

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
                      canPromote={data.attachTargets.length > 0}
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
      </section>
    </div>
  )

  return createPortal(body, document.body)
}

function CandidateRow({
  candidate,
  busy,
  canPromote,
  onPromote,
  onDiscard,
}: {
  candidate: SessionArtifactCandidate
  busy: boolean
  canPromote: boolean
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
        <button type="button" onClick={onPromote} disabled={busy || !canPromote}>
          {busy ? <Loader2 size={14} className="spin" aria-hidden /> : <CheckCircle2 size={14} aria-hidden />}
          <span>{t('artifacts.promote')}</span>
        </button>
        <button type="button" className="danger" onClick={onDiscard} disabled={busy}>
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
        <button type="button" onClick={() => openReference(artifact.reference)}>
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

function targetKey(target: SessionArtifactAttachTarget): string {
  return `${target.canvasId}:${target.nodeId}`
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

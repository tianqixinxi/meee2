import {
  Archive,
  Bot,
  Boxes,
  ChevronRight,
  Clock3,
  FileText,
  FileJson,
  GitBranch,
  GitCompare,
  Loader2,
  MessageSquare,
  Route,
  Sparkles,
  Wrench,
} from 'lucide-react'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import {
  fetchSessionArtifacts,
  fetchSessionEnvironment,
  openSessionEnvironmentOutput,
} from '../api'
import { useI18n } from '../lib/i18n'
import type { Session, SessionArtifactsEnvelope, SessionEnvironmentSnapshot } from '../types'
import {
  SessionArtifactsModal,
  type SessionArtifactsModalTarget,
} from './SessionArtifactsModal'
import { SessionTranscriptModal } from './SessionTranscriptModal'

interface SessionContextPanelProps {
  session: Session
}

type EnvironmentCacheEntry = {
  data: SessionEnvironmentSnapshot
  refreshKey: string
}

type ArtifactCacheEntry = {
  data: SessionArtifactsEnvelope
  fetchedAt: number
}

const ENVIRONMENT_CACHE_LIMIT = 24
const ARTIFACT_CACHE_LIMIT = 24
const ARTIFACT_CACHE_TTL_MS = 5_000
const ACTIVE_REFRESH_MS = 5_000
const RESTING_REFRESH_MS = 15_000
const environmentCache = new Map<string, EnvironmentCacheEntry>()
const environmentPending = new Map<string, { refreshKey: string; promise: Promise<SessionEnvironmentSnapshot> }>()
const environmentSequence = new Map<string, number>()
const artifactCache = new Map<string, ArtifactCacheEntry>()
const artifactPending = new Map<string, Promise<SessionArtifactsEnvelope>>()

function requestEnvironment(
  sessionId: string,
  refreshKey: string,
  force = false,
): Promise<SessionEnvironmentSnapshot> {
  const cached = environmentCache.get(sessionId)
  if (!force && cached?.refreshKey === refreshKey) return Promise.resolve(cached.data)
  const existing = environmentPending.get(sessionId)
  if (existing?.refreshKey === refreshKey) return existing.promise
  const sequence = (environmentSequence.get(sessionId) ?? 0) + 1
  environmentSequence.set(sessionId, sequence)
  const request = fetchSessionEnvironment(sessionId)
    .then((data) => {
      if (environmentSequence.get(sessionId) === sequence) {
        environmentCache.delete(sessionId)
        environmentCache.set(sessionId, { data, refreshKey })
        trimCache(environmentCache, ENVIRONMENT_CACHE_LIMIT)
      }
      return data
    })
    .finally(() => {
      if (environmentPending.get(sessionId)?.promise === request) environmentPending.delete(sessionId)
    })
  environmentPending.set(sessionId, { refreshKey, promise: request })
  return request
}

function requestArtifacts(sessionId: string): Promise<SessionArtifactsEnvelope> {
  const cached = artifactCache.get(sessionId)
  if (cached && Date.now() - cached.fetchedAt < ARTIFACT_CACHE_TTL_MS) {
    return Promise.resolve(cached.data)
  }
  const existing = artifactPending.get(sessionId)
  if (existing) return existing
  const request = fetchSessionArtifacts(sessionId)
    .then((data) => {
      artifactCache.delete(sessionId)
      artifactCache.set(sessionId, { data, fetchedAt: Date.now() })
      trimCache(artifactCache, ARTIFACT_CACHE_LIMIT)
      return data
    })
    .finally(() => {
      if (artifactPending.get(sessionId) === request) artifactPending.delete(sessionId)
    })
  artifactPending.set(sessionId, request)
  return request
}

function trimCache<T>(cache: Map<string, T>, limit: number): void {
  while (cache.size > limit) {
    const oldest = cache.keys().next().value
    if (!oldest) break
    cache.delete(oldest)
  }
}

export function sessionContextRefreshInterval(refreshStatus?: string | null): number {
  const status = refreshStatus?.trim().toLowerCase() ?? ''
  return status === 'starting'
    || status === 'running'
    || status === 'active'
    || status === 'thinking'
    || status === 'compacting'
    || status.includes('tool')
    ? ACTIVE_REFRESH_MS
    : RESTING_REFRESH_MS
}

function canRefreshContext(): boolean {
  return document.visibilityState === 'visible' && document.hasFocus()
}

export function SessionContextPanel({ session }: SessionContextPanelProps) {
  const { t } = useI18n()
  const refreshKey = session.lastActivity ?? ''
  const initialEnvironment = environmentCache.get(session.id)?.data ?? null
  const initialArtifacts = artifactCache.get(session.id)?.data ?? null
  const [environment, setEnvironment] = useState<SessionEnvironmentSnapshot | null>(initialEnvironment)
  const [artifacts, setArtifacts] = useState<SessionArtifactsEnvelope | null>(initialArtifacts)
  const [environmentLoading, setEnvironmentLoading] = useState(initialEnvironment === null)
  const [artifactsLoading, setArtifactsLoading] = useState(initialArtifacts === null)
  const [openingPath, setOpeningPath] = useState<string | null>(null)
  const [openError, setOpenError] = useState(false)
  const [artifactsModalOpen, setArtifactsModalOpen] = useState(false)
  const [transcriptModalOpen, setTranscriptModalOpen] = useState(false)
  const mountedRef = useRef(true)
  const activeSessionIdRef = useRef(session.id)
  const activeRefreshKeyRef = useRef(refreshKey)
  activeSessionIdRef.current = session.id
  activeRefreshKeyRef.current = refreshKey

  const artifactTarget = useMemo<SessionArtifactsModalTarget>(() => ({
    sessionId: session.id,
    title: session.title,
    providerResumeSessionId: session.providerResumeSessionId,
    surfaceId: session.surfaceId,
    project: session.project,
  }), [session.id, session.project, session.providerResumeSessionId, session.surfaceId, session.title])

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  const refreshEnvironment = useCallback((force = false) => {
    const cached = environmentCache.get(session.id)?.data ?? null
    if (!force) {
      setEnvironment(cached)
      setEnvironmentLoading(cached === null)
    }
    return requestEnvironment(session.id, refreshKey, force)
      .then((next) => {
        if (
          mountedRef.current
          && activeSessionIdRef.current === session.id
          && activeRefreshKeyRef.current === refreshKey
        ) setEnvironment(next)
      })
      .catch(() => undefined)
      .finally(() => {
        if (
          mountedRef.current
          && activeSessionIdRef.current === session.id
          && activeRefreshKeyRef.current === refreshKey
        ) setEnvironmentLoading(false)
      })
  }, [refreshKey, session.id])

  useEffect(() => {
    setArtifacts(artifactCache.get(session.id)?.data ?? null)
    setArtifactsLoading(!artifactCache.has(session.id))
    let cancelled = false
    void requestArtifacts(session.id)
      .then((next) => {
        if (!cancelled) setArtifacts(next)
      })
      .catch(() => undefined)
      .finally(() => {
        if (!cancelled) setArtifactsLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [session.id])

  useEffect(() => {
    // A selected session always paints one snapshot; focus only gates polling.
    void refreshEnvironment()
  }, [refreshEnvironment])

  useEffect(() => {
    const intervalMs = sessionContextRefreshInterval(session.status)
    let timer: number | null = null
    let stopped = false
    const schedule = () => {
      if (stopped) return
      if (timer !== null) window.clearTimeout(timer)
      timer = window.setTimeout(async () => {
        timer = null
        if (stopped) return
        if (canRefreshContext()) await refreshEnvironment(true)
        schedule()
      }, intervalMs)
    }
    const refreshOnFocus = () => {
      if (!canRefreshContext()) return
      void refreshEnvironment(true)
      schedule()
    }
    const refreshOnVisibility = () => {
      if (document.visibilityState === 'visible') refreshOnFocus()
    }
    window.addEventListener('focus', refreshOnFocus)
    document.addEventListener('visibilitychange', refreshOnVisibility)
    schedule()
    return () => {
      stopped = true
      if (timer !== null) window.clearTimeout(timer)
      window.removeEventListener('focus', refreshOnFocus)
      document.removeEventListener('visibilitychange', refreshOnVisibility)
    }
  }, [refreshEnvironment, session.status])

  const handleOpenOutput = async (path: string) => {
    setOpeningPath(path)
    setOpenError(false)
    try {
      await openSessionEnvironmentOutput(session.id, path)
    } catch {
      setOpenError(true)
    } finally {
      setOpeningPath(null)
    }
  }

  const recentActivity = session.latestRecap?.content?.trim()
    ? [{ role: 'recap', text: session.latestRecap.content.trim() }]
    : session.recentMessages.slice(-3)
  const backgroundAgents = session.backgroundAgents ?? []
  const tasks = session.tasks ?? []
  const outputs = environment?.outputs ?? []
  const changedFiles = environment?.files ?? []
  const artifactCount = artifacts?.totalCount ?? 0
  const currentStatusTone = statusTone(session.status)
  const activityLabel = session.lastActivity
    ? contextActivityLabel(session.lastActivity, currentStatusTone === 'idle', t)
    : ''
  const showWork = Boolean(environment?.isGit && (environment.branch || environment.changes || changedFiles.length > 0))
  const showDeliverables = outputs.length > 0 || artifactCount > 0 || environmentLoading || artifactsLoading

  return (
    <aside className="session-context" aria-label={t('sessions.context.title')}>
      <header className="session-context__header">
        <div>
          <Sparkles size={14} aria-hidden />
          <h3>{t('sessions.context.title')}</h3>
        </div>
        {environmentLoading ? <Loader2 size={13} className="spin" aria-label={t('common.loading')} /> : null}
      </header>

      <ContextSection icon={<Route size={13} aria-hidden />} title={t('sessions.context.now')}>
        <div className="session-context__now">
          <div className="session-context__status-line">
            <span className={`session-context__status is-${currentStatusTone}`}>
              {currentStatusTone === 'idle' && activityLabel
                ? activityLabel
                : contextStatusLabel(currentStatusTone, t)}
            </span>
            <span>{session.pluginDisplayName}</span>
          </div>
          {session.currentTask ? <strong>{session.currentTask}</strong> : null}
          {session.currentTool ? (
            <span className="session-context__muted"><Wrench size={11} aria-hidden />{session.currentTool}</span>
          ) : null}
          {session.lastActivity && currentStatusTone !== 'idle' ? (
            <span
              className="session-context__muted"
              title={formatDateTime(session.lastActivity)}
            >
              <Clock3 size={11} aria-hidden />{activityLabel}
            </span>
          ) : null}
        </div>
      </ContextSection>

      {recentActivity.length > 0 ? (
        <ContextSection icon={<MessageSquare size={13} aria-hidden />} title={t('sessions.context.recentActivity')}>
          <div className="session-context__activity-list">
            {recentActivity.map((entry, index) => (
              <article key={`${entry.role}-${index}`}>
                <span>{activityRoleLabel(entry.role, t)}</span>
                <p>{entry.text}</p>
              </article>
            ))}
          </div>
          <button type="button" className="session-context__secondary-action" onClick={() => setTranscriptModalOpen(true)}>
            <FileJson size={12} aria-hidden />
            <span>{t('sessions.context.viewTranscript')}</span>
            <ChevronRight size={12} aria-hidden />
          </button>
        </ContextSection>
      ) : null}

      {backgroundAgents.length > 0 || tasks.length > 0 ? (
        <ContextSection icon={<Bot size={13} aria-hidden />} title={t('sessions.context.agents')}>
          <div className="session-context__agent-list">
            {backgroundAgents.map((agent) => (
              <div key={agent.id}>
                <span className="session-context__agent-dot" aria-hidden />
                <strong>{agent.description || agent.kind}</strong>
                <small>{agent.kind}</small>
              </div>
            ))}
            {tasks.map((task) => (
              <div key={task.id}>
                <span className={`session-context__task-dot is-${task.status}`} aria-hidden />
                <strong>{task.name}</strong>
                <small>{task.status.replace('_', ' ')}</small>
              </div>
            ))}
          </div>
        </ContextSection>
      ) : null}

      {showWork ? (
        <ContextSection icon={<GitCompare size={13} aria-hidden />} title={t('sessions.context.work')}>
          {environment?.branch ? (
            <ContextValue icon={<GitBranch size={12} aria-hidden />} label={t('sessions.environment.branch')}>
              <code title={environment.branch}>{environment.branch}</code>
            </ContextValue>
          ) : null}
          {environment?.changes ? (
            <div className="session-context__change-summary">
              <span>{t('sessions.environment.changedFiles', { count: environment.changes.files })}</span>
              <b className="is-addition">+{environment.changes.additions}</b>
              <b className="is-deletion">-{environment.changes.deletions}</b>
            </div>
          ) : null}
          {changedFiles.length > 0 ? (
            <ul className="session-context__changed-files">
              {changedFiles.slice(0, 8).map((file) => (
                <li key={file.relativePath} title={file.relativePath}>
                  <span className={`is-${file.status}`}>{fileStatusLabel(file.status)}</span>
                  <code>{file.relativePath}</code>
                  {file.additions != null ? <b className="is-addition">+{file.additions}</b> : null}
                  {file.deletions != null ? <b className="is-deletion">-{file.deletions}</b> : null}
                </li>
              ))}
            </ul>
          ) : null}
        </ContextSection>
      ) : null}

      {showDeliverables ? (
        <ContextSection icon={<Boxes size={13} aria-hidden />} title={t('sessions.context.deliverables')}>
          {outputs.length > 0 ? (
            <ul className="session-context__outputs">
              {outputs.map((file) => (
                <li key={file.path}>
                  <button
                    type="button"
                    title={t('sessions.environment.openOutput')}
                    aria-label={`${t('sessions.environment.openOutput')}: ${file.relativePath}`}
                    disabled={openingPath === file.path}
                    onClick={() => void handleOpenOutput(file.path)}
                  >
                    {openingPath === file.path
                      ? <Loader2 size={12} className="spin" aria-hidden />
                      : <FileText size={12} aria-hidden />}
                    <span>{file.relativePath}</span>
                  </button>
                </li>
              ))}
            </ul>
          ) : null}
          {artifactCount > 0 ? (
            <button type="button" className="session-context__artifacts-button" onClick={() => setArtifactsModalOpen(true)}>
              <Archive size={13} aria-hidden />
              <span>{t('sessions.context.artifactCount', { count: artifactCount })}</span>
              <ChevronRight size={13} aria-hidden />
            </button>
          ) : null}
          {openError ? <span className="session-context__error" role="alert">{t('sessions.environment.openOutputFailed')}</span> : null}
        </ContextSection>
      ) : null}

      {session.usageStats ? (
        <details className="session-context__usage">
          <summary>{t('sessions.context.usage')}</summary>
          <dl>
            {session.usageStats.model ? <Metric label={t('sessions.context.model')} value={session.usageStats.model} /> : null}
            <Metric label={t('sessions.context.turns')} value={formatNumber(session.usageStats.turns)} />
            <Metric label={t('sessions.context.inputTokens')} value={formatNumber(session.usageStats.inputTokens)} />
            <Metric label={t('sessions.context.outputTokens')} value={formatNumber(session.usageStats.outputTokens)} />
            <Metric
              label={t('sessions.context.cachedTokens')}
              value={formatNumber(session.usageStats.cacheCreateTokens + session.usageStats.cacheReadTokens)}
            />
          </dl>
        </details>
      ) : null}

      {artifactsModalOpen ? (
        <SessionArtifactsModal target={artifactTarget} onClose={() => setArtifactsModalOpen(false)} />
      ) : null}
      {transcriptModalOpen ? (
        <SessionTranscriptModal
          sessionId={session.id}
          title={session.title}
          onClose={() => setTranscriptModalOpen(false)}
        />
      ) : null}
    </aside>
  )
}

function ContextSection({ icon, title, children }: { icon: ReactNode; title: string; children: ReactNode }) {
  return (
    <section className="session-context__section">
      <h4>{icon}<span>{title}</span></h4>
      <div className="session-context__section-body">{children}</div>
    </section>
  )
}

function ContextValue({ icon, label, children }: { icon: ReactNode; label: string; children: ReactNode }) {
  return (
    <div className="session-context__value">
      <span>{icon}{label}</span>
      {children}
    </div>
  )
}

function Metric({ label, value }: { label: string; value: string }) {
  return <div><dt>{label}</dt><dd title={value}>{value}</dd></div>
}

function statusTone(status: string): 'running' | 'attention' | 'done' | 'failed' | 'idle' {
  const normalized = status.toLowerCase()
  if (normalized.includes('fail') || normalized.includes('error')) return 'failed'
  if (normalized.includes('permission') || normalized.includes('waiting') || normalized.includes('choice')) return 'attention'
  if (normalized.includes('done') || normalized.includes('complete') || normalized.includes('exit')) return 'done'
  if (normalized.includes('run') || normalized.includes('think') || normalized.includes('tool')) return 'running'
  return 'idle'
}

function activityRoleLabel(role: string, t: ReturnType<typeof useI18n>['t']): string {
  if (role === 'recap') return t('sessions.context.recap')
  if (role === 'user') return t('sessions.context.you')
  if (role === 'assistant') return t('sessions.context.agent')
  return role
}

function contextStatusLabel(
  tone: ReturnType<typeof statusTone>,
  t: ReturnType<typeof useI18n>['t'],
): string {
  if (tone === 'running') return t('sessions.launcher.statusRunning')
  if (tone === 'attention') return t('sessions.launcher.statusNeedsInput')
  if (tone === 'done') return t('sessions.launcher.statusDone')
  if (tone === 'failed') return t('sessions.launcher.statusFailed')
  return t('sessions.context.idle')
}

function fileStatusLabel(status: SessionEnvironmentSnapshot['files'][number]['status']): string {
  switch (status) {
    case 'added': return 'A'
    case 'deleted': return 'D'
    case 'renamed': return 'R'
    case 'untracked': return 'U'
    case 'modified': return 'M'
  }
}

function formatDateTime(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function contextActivityLabel(
  value: string,
  idle: boolean,
  t: ReturnType<typeof useI18n>['t'],
): string {
  const timestamp = Date.parse(value)
  if (!Number.isFinite(timestamp)) return value
  const minutes = Math.max(0, Math.floor((Date.now() - timestamp) / 60_000))
  if (minutes < 1) return t(idle ? 'sessions.context.idleJustNow' : 'sessions.context.activeJustNow')
  if (minutes < 60) {
    return t(idle ? 'sessions.context.idleMinutes' : 'sessions.context.activeMinutesAgo', { count: minutes })
  }
  const hours = Math.floor(minutes / 60)
  if (hours < 24) {
    return t(idle ? 'sessions.context.idleHours' : 'sessions.context.activeHoursAgo', { count: hours })
  }
  const days = Math.floor(hours / 24)
  return t(idle ? 'sessions.context.idleDays' : 'sessions.context.activeDaysAgo', { count: days })
}

function formatNumber(value: number): string {
  return new Intl.NumberFormat(undefined, { notation: 'compact', maximumFractionDigits: 1 }).format(value)
}

import { FileText, GitBranch, GitCompare, Loader2 } from 'lucide-react'
import { useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { fetchSessionEnvironment, openSessionEnvironmentOutput } from '../api'
import { useI18n } from '../lib/i18n'
import type { SessionEnvironmentSnapshot } from '../types'

interface SessionEnvironmentPanelProps {
  sessionId: string
  refreshKey?: string | null
}

type CacheEntry = {
  data: SessionEnvironmentSnapshot
  refreshKey: string
}

const CACHE_LIMIT = 24
const cache = new Map<string, CacheEntry>()
const pending = new Map<string, Promise<SessionEnvironmentSnapshot>>()

function requestEnvironment(sessionId: string, refreshKey: string): Promise<SessionEnvironmentSnapshot> {
  const cached = cache.get(sessionId)
  if (cached?.refreshKey === refreshKey) return Promise.resolve(cached.data)
  const requestKey = `${sessionId}:${refreshKey}`
  const existing = pending.get(requestKey)
  if (existing) return existing
  const request = fetchSessionEnvironment(sessionId)
    .then((data) => {
      cache.delete(sessionId)
      cache.set(sessionId, { data, refreshKey })
      while (cache.size > CACHE_LIMIT) {
        const oldest = cache.keys().next().value
        if (!oldest) break
        cache.delete(oldest)
      }
      return data
    })
    .finally(() => pending.delete(requestKey))
  pending.set(requestKey, request)
  return request
}

export function SessionEnvironmentPanel({ sessionId, refreshKey }: SessionEnvironmentPanelProps) {
  const { t } = useI18n()
  const normalizedRefreshKey = refreshKey ?? ''
  const initialData = cache.get(sessionId)?.data ?? null
  const [data, setData] = useState<SessionEnvironmentSnapshot | null>(initialData)
  const [loading, setLoading] = useState(initialData === null)
  const [openingPath, setOpeningPath] = useState<string | null>(null)
  const [openError, setOpenError] = useState(false)

  useEffect(() => {
    let cancelled = false
    const cached = cache.get(sessionId)?.data ?? null
    setData(cached)
    setLoading(cached === null)
    requestEnvironment(sessionId, normalizedRefreshKey)
      .then((next) => {
        if (!cancelled) setData(next)
      })
      .catch(() => undefined)
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [normalizedRefreshKey, sessionId])

  const handleOpenOutput = async (path: string) => {
    setOpeningPath(path)
    setOpenError(false)
    try {
      await openSessionEnvironmentOutput(sessionId, path)
    } catch {
      setOpenError(true)
    } finally {
      setOpeningPath(null)
    }
  }

  return (
    <div className="session-environment">
      <section className="session-environment__group">
        <header className="session-environment__header">
          <h3>{t('sessions.environment.title')}</h3>
          {loading ? <Loader2 size={13} className="spin" aria-label={t('common.loading')} /> : null}
        </header>
        <div className="session-environment__body">
          <EnvironmentSection icon={<GitCompare size={14} aria-hidden />} label={t('sessions.environment.changes')}>
            {data?.isGit && data.changes ? (
              <div className="session-environment__change-summary">
                <span>{t('sessions.environment.changedFiles', { count: data.changes.files })}</span>
                <b className="is-addition">+{data.changes.additions}</b>
                <b className="is-deletion">-{data.changes.deletions}</b>
              </div>
            ) : <EmptyValue />}
          </EnvironmentSection>

          <EnvironmentSection icon={<GitBranch size={14} aria-hidden />} label={t('sessions.environment.branch')}>
            <span className="session-environment__branch" title={data?.branch ?? undefined}>
              {data?.isGit && data.branch ? data.branch : '—'}
            </span>
          </EnvironmentSection>
        </div>
      </section>

      <section className="session-environment__group session-environment__outputs">
        <header className="session-environment__header">
          <h3>{t('sessions.environment.outputs')}</h3>
        </header>
        <div className="session-environment__outputs-body">
          {data && data.outputs.length > 0 ? (
            <ul className="session-environment__files">
              {data.outputs.map((file) => (
                <li key={file.path}>
                  <button
                    type="button"
                    title={t('sessions.environment.openOutput')}
                    aria-label={`${t('sessions.environment.openOutput')}: ${file.relativePath}`}
                    disabled={openingPath === file.path}
                    onClick={() => void handleOpenOutput(file.path)}
                  >
                    {openingPath === file.path
                      ? <Loader2 size={13} className="spin" aria-hidden />
                      : <FileText size={13} aria-hidden />}
                    <span>{file.relativePath}</span>
                  </button>
                </li>
              ))}
            </ul>
          ) : <EmptyValue />}
          {openError ? (
            <span className="session-environment__open-error" role="alert">
              {t('sessions.environment.openOutputFailed')}
            </span>
          ) : null}
        </div>
      </section>
    </div>
  )
}

function EnvironmentSection({
  icon,
  label,
  children,
}: {
  icon: ReactNode
  label: string
  children: ReactNode
}) {
  return (
    <section className="session-environment__section">
      <h4>{icon}<span>{label}</span></h4>
      <div className="session-environment__value">{children}</div>
    </section>
  )
}

function EmptyValue() {
  return <span className="session-environment__empty">—</span>
}

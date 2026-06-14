import {
  ChevronDown,
  Folder,
  FolderPlus,
  Loader2,
  MessageSquarePlus,
  Pin,
  PinOff,
  Play,
  Terminal as TerminalIcon,
  Trash2,
} from 'lucide-react'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { Dispatch, ReactNode, SetStateAction } from 'react'
import {
  createProjectSession,
  createSessionProject,
  createTemporarySession,
  fetchSessionProjects,
  forgetSessionProject,
  openNativeTerminalSurface,
  pickSessionProjectDirectory,
  type NativeTerminalRect,
} from '../api'
import { spawnProviderLabel } from '../preferences'
import { loadPinnedSet, togglePinned } from '../sessionOverrides'
import type { BoardState, Session, SessionProject, SpawnProvider } from '../types'

interface Props {
  state: BoardState | null
  onSessionCreated?: () => void
  onToast?: (kind: 'success' | 'error', text: string) => void
}

type Selection =
  | { kind: 'project'; projectId: string }
  | { kind: 'temporaryDraft' }
  | { kind: 'session'; sessionId: string; surfaceId?: string | null }

const DEFAULT_PROMPT = ''
const PROVIDERS: SpawnProvider[] = ['codex', 'claude']
const DEFAULT_VISIBLE_SESSIONS = 5
const TEMPORARY_GROUP_ID = 'temporary'

export function SessionLauncherView({
  state,
  onSessionCreated,
  onToast,
}: Props) {
  const [projects, setProjects] = useState<SessionProject[]>([])
  const [projectsLoading, setProjectsLoading] = useState(true)
  const [projectsError, setProjectsError] = useState<string | null>(null)
  const [selection, setSelection] = useState<Selection | null>(null)
  const [expandedProjectIds, setExpandedProjectIds] = useState<Set<string>>(() => new Set())
  const [expandedSessionGroups, setExpandedSessionGroups] = useState<Set<string>>(() => new Set())
  const [promptByProjectId, setPromptByProjectId] = useState<Record<string, string>>({})
  const [providerByProjectId, setProviderByProjectId] = useState<Record<string, SpawnProvider>>({})
  const [temporaryPrompt, setTemporaryPrompt] = useState(DEFAULT_PROMPT)
  const [temporaryProvider, setTemporaryProvider] = useState<SpawnProvider>('codex')
  const [pinnedSessionIds, setPinnedSessionIds] = useState<Set<string>>(() => loadPinnedSet())
  const [addingFolder, setAddingFolder] = useState(false)
  const [startingProjectId, setStartingProjectId] = useState<string | null>(null)
  const [startingTemporary, setStartingTemporary] = useState(false)
  const initializedSelectionRef = useRef(false)
  const sessions = state?.sessions ?? []

  const refreshProjects = useCallback(() => {
    setProjectsLoading(true)
    setProjectsError(null)
    fetchSessionProjects()
      .then((result) => {
        const projectList = Array.isArray(result?.projects) ? result.projects : []
        const explicit = projectList.filter((project) => project.explicit)
        setProjects(explicit)
        if (!initializedSelectionRef.current && explicit[0]) {
          initializedSelectionRef.current = true
          setSelection({ kind: 'project', projectId: explicit[0].id })
          setExpandedProjectIds(new Set([explicit[0].id]))
        }
      })
      .catch((err: Error) => setProjectsError(err.message || 'Failed to load projects'))
      .finally(() => setProjectsLoading(false))
  }, [])

  useEffect(() => {
    refreshProjects()
  }, [refreshProjects])

  useEffect(() => {
    const refreshPinned = () => setPinnedSessionIds(loadPinnedSet())
    window.addEventListener('meee2:session-overrides-changed', refreshPinned)
    return () => window.removeEventListener('meee2:session-overrides-changed', refreshPinned)
  }, [])

  const explicitProjects = useMemo(
    () => projects.filter((project) => project.explicit),
    [projects],
  )

  const projectByPath = useMemo(() => {
    const map = new Map<string, SessionProject>()
    for (const project of explicitProjects) map.set(normalizePath(project.path), project)
    return map
  }, [explicitProjects])

  const activeSessions = useMemo(
    () => sessions.filter((session) => session.controlState !== 'archived'),
    [sessions],
  )

  const grouped = useMemo(() => {
    const byProject = new Map<string, Session[]>()
    for (const project of explicitProjects) byProject.set(project.id, [])
    const pinned: Session[] = []
    const temporary: Session[] = []

    for (const session of activeSessions) {
      if (pinnedSessionIds.has(session.id)) {
        pinned.push(session)
        continue
      }
      const project = projectByPath.get(normalizePath(session.project))
      if (project) byProject.get(project.id)?.push(session)
      else temporary.push(session)
    }

    for (const list of byProject.values()) list.sort(compareSessions)
    pinned.sort(compareSessions)
    temporary.sort(compareSessions)
    return { byProject, pinned, temporary }
  }, [activeSessions, explicitProjects, pinnedSessionIds, projectByPath])

  const latestProjectSessionTimes = useMemo(() => {
    const times = new Map<string, number>()
    for (const session of activeSessions) {
      const project = projectByPath.get(normalizePath(session.project))
      if (!project) continue
      times.set(project.id, Math.max(times.get(project.id) ?? 0, sessionTime(session)))
    }
    return times
  }, [activeSessions, projectByPath])

  const sortedProjects = useMemo(() => {
    return [...explicitProjects].sort((a, b) => {
      const aTime = latestProjectSessionTimes.get(a.id) ?? projectTime(a)
      const bTime = latestProjectSessionTimes.get(b.id) ?? projectTime(b)
      if (aTime !== bTime) return bTime - aTime
      return a.name.localeCompare(b.name, undefined, { sensitivity: 'base' })
    })
  }, [explicitProjects, latestProjectSessionTimes])

  useEffect(() => {
    if (selection) return
    const first = sortedProjects[0]
    if (first) {
      initializedSelectionRef.current = true
      setSelection({ kind: 'project', projectId: first.id })
      setExpandedProjectIds(new Set([first.id]))
    }
  }, [selection, sortedProjects])

  const selectedProject = useMemo(() => {
    if (selection?.kind !== 'project') return null
    return explicitProjects.find((project) => project.id === selection.projectId) ?? null
  }, [explicitProjects, selection])

  const selectedSession = useMemo(() => {
    if (selection?.kind !== 'session') return null
    return sessions.find((session) => session.id === selection.sessionId || session.surfaceId === selection.surfaceId) ?? null
  }, [selection, sessions])

  const selectedProjectProvider = selectedProject
    ? providerByProjectId[selectedProject.id] ?? selectedProject.preferredProvider
    : temporaryProvider
  const currentProjectPrompt = selectedProject
    ? promptByProjectId[selectedProject.id] ?? DEFAULT_PROMPT
    : DEFAULT_PROMPT

  const selectProject = useCallback((project: SessionProject) => {
    setSelection({ kind: 'project', projectId: project.id })
    setExpandedProjectIds(new Set([project.id]))
  }, [])

  const handleAddFolder = useCallback(async () => {
    setAddingFolder(true)
    try {
      const picked = await pickSessionProjectDirectory()
      if (!picked.path) return
      const project = await createSessionProject({
        path: picked.path,
        preferredProvider: selectedProjectProvider,
      })
      setProjects((current) => [project, ...current.filter((item) => item.id !== project.id)])
      setSelection({ kind: 'project', projectId: project.id })
      setExpandedProjectIds(new Set([project.id]))
      onToast?.('success', `Added ${project.name}`)
    } catch (err) {
      onToast?.('error', (err as Error).message || 'Failed to add folder')
    } finally {
      setAddingFolder(false)
    }
  }, [onToast, selectedProjectProvider])

  const handleForgetProject = useCallback(async (project: SessionProject) => {
    try {
      await forgetSessionProject(project.id)
      setProjects((current) => current.filter((item) => item.id !== project.id))
      setSelection((current) => current?.kind === 'project' && current.projectId === project.id ? null : current)
      setExpandedProjectIds((current) => {
        const next = new Set(current)
        next.delete(project.id)
        return next
      })
      onToast?.('success', `Forgot ${project.name}`)
    } catch (err) {
      onToast?.('error', (err as Error).message || 'Failed to forget project')
    }
  }, [onToast])

  const handleStartProjectSession = useCallback(async () => {
    if (!selectedProject) return
    const prompt = currentProjectPrompt.trim()
    setStartingProjectId(selectedProject.id)
    try {
      const result = await createProjectSession({
        projectId: selectedProject.id,
        provider: selectedProjectProvider,
        initialPrompt: prompt || undefined,
      })
      setProjects((current) => [result.project, ...current.filter((item) => item.id !== result.project.id)])
      setProviderByProjectId((current) => ({ ...current, [result.project.id]: result.project.preferredProvider }))
      setSelection({
        kind: 'session',
        sessionId: result.surface.sessionId,
        surfaceId: result.surface.surfaceId,
      })
      setExpandedProjectIds(new Set([result.project.id]))
      onSessionCreated?.()
      onToast?.('success', `Started ${spawnProviderLabel(selectedProjectProvider)} in ${result.project.name}`)
    } catch (err) {
      onToast?.('error', (err as Error).message || 'Failed to start session')
    } finally {
      setStartingProjectId(null)
    }
  }, [currentProjectPrompt, onSessionCreated, onToast, selectedProject, selectedProjectProvider])

  const handleStartTemporarySession = useCallback(async () => {
    const prompt = temporaryPrompt.trim()
    setStartingTemporary(true)
    try {
      const result = await createTemporarySession({
        provider: temporaryProvider,
        initialPrompt: prompt || undefined,
      })
      setSelection({
        kind: 'session',
        sessionId: result.surface.sessionId,
        surfaceId: result.surface.surfaceId,
      })
      setTemporaryPrompt(DEFAULT_PROMPT)
      setExpandedSessionGroups((current) => new Set([...current, TEMPORARY_GROUP_ID]))
      onSessionCreated?.()
      onToast?.('success', `Started ${spawnProviderLabel(temporaryProvider)} temporary session`)
    } catch (err) {
      onToast?.('error', (err as Error).message || 'Failed to start temporary session')
    } finally {
      setStartingTemporary(false)
    }
  }, [onSessionCreated, onToast, temporaryPrompt, temporaryProvider])

  const handleTogglePinned = useCallback((session: Session) => {
    const pinned = togglePinned(session.id)
    setPinnedSessionIds(loadPinnedSet())
    onToast?.('success', pinned ? 'Pinned session' : 'Unpinned session')
  }, [onToast])

  return (
    <section className="session-launcher" aria-label="Session">
      <aside className="session-launcher__sidebar">
        <div className="session-launcher__sidebar-header">
          <div>
            <h1>Session</h1>
            <span>{activeSessions.length} sessions</span>
          </div>
          <button
            type="button"
            className="session-launcher__icon-button"
            onClick={handleAddFolder}
            disabled={addingFolder}
            aria-label="Add folder"
            title="Add folder"
          >
            {addingFolder ? <Loader2 size={16} className="spin" /> : <FolderPlus size={16} />}
          </button>
        </div>
        {projectsError && <div className="session-launcher__error">{projectsError}</div>}
        <div className="session-launcher__project-list">
          <SessionGroupHeader title="置顶" count={grouped.pinned.length} />
          {grouped.pinned.length > 0 ? (
            <SessionList
              groupId="pinned"
              sessions={grouped.pinned}
              selection={selection}
              expandedSessionGroups={expandedSessionGroups}
              onToggleExpanded={setExpandedSessionGroups}
              onSelectSession={(session) => setSelection({ kind: 'session', sessionId: session.id, surfaceId: session.surfaceId })}
              onTogglePinned={handleTogglePinned}
              pinnedSessionIds={pinnedSessionIds}
            />
          ) : (
            <div className="session-launcher__empty session-launcher__empty--compact">暂无置顶</div>
          )}

          <SessionGroupHeader title="项目" count={sortedProjects.length} />
          {projectsLoading ? (
            <div className="session-launcher__empty">Loading projects</div>
          ) : sortedProjects.length === 0 ? (
            <div className="session-launcher__empty">Add a local folder to start.</div>
          ) : sortedProjects.map((project) => {
            const projectSessions = grouped.byProject.get(project.id) ?? []
            const expanded = expandedProjectIds.has(project.id)
            const selected = selection?.kind === 'project' && selection.projectId === project.id
            return (
              <div key={project.id} className="session-launcher__project-group">
                <button
                  type="button"
                  className={`session-launcher__project-row${selected ? ' is-selected' : ''}`}
                  onClick={() => selectProject(project)}
                >
                  <Folder size={16} aria-hidden />
                  <span>
                    <strong>{project.name}</strong>
                    <small>{project.path}</small>
                  </span>
                </button>
                <div className="session-launcher__project-actions">
                  <button
                    type="button"
                    onClick={() => setExpandedProjectIds((current) => toggleSet(current, project.id))}
                    aria-label={expanded ? `Collapse ${project.name}` : `Expand ${project.name}`}
                    title={expanded ? 'Collapse' : 'Expand'}
                  >
                    <ChevronDown size={14} className={expanded ? 'is-open' : ''} />
                    <span>{projectSessions.length}</span>
                  </button>
                  <button
                    type="button"
                    onClick={() => void handleForgetProject(project)}
                    aria-label={`Forget ${project.name}`}
                    title="Forget project"
                  >
                    <Trash2 size={14} />
                  </button>
                </div>
                {expanded && (
                  <SessionList
                    groupId={`project:${project.id}`}
                    sessions={projectSessions}
                    selection={selection}
                    expandedSessionGroups={expandedSessionGroups}
                    onToggleExpanded={setExpandedSessionGroups}
                    onSelectSession={(session) => setSelection({ kind: 'session', sessionId: session.id, surfaceId: session.surfaceId })}
                    onTogglePinned={handleTogglePinned}
                    pinnedSessionIds={pinnedSessionIds}
                  />
                )}
              </div>
            )
          })}

          <SessionGroupHeader
            title="临时对话"
            count={grouped.temporary.length}
            action={(
              <button
                type="button"
                className="session-launcher__group-action"
                onClick={() => setSelection({ kind: 'temporaryDraft' })}
                aria-label="New temporary session"
                title="New temporary session"
              >
                <MessageSquarePlus size={14} />
              </button>
            )}
          />
          <SessionList
            groupId={TEMPORARY_GROUP_ID}
            sessions={grouped.temporary}
            selection={selection}
            expandedSessionGroups={expandedSessionGroups}
            onToggleExpanded={setExpandedSessionGroups}
            onSelectSession={(session) => setSelection({ kind: 'session', sessionId: session.id, surfaceId: session.surfaceId })}
            onTogglePinned={handleTogglePinned}
            pinnedSessionIds={pinnedSessionIds}
          />
        </div>
      </aside>
      <main className="session-launcher__main">
        {selection?.kind === 'session' ? (
          <SessionLauncherTerminal
            session={selectedSession}
            sessionId={selection.sessionId}
            surfaceId={selection.surfaceId}
          />
        ) : selection?.kind === 'temporaryDraft' ? (
          <SessionComposer
            title="我们应该在临时工作区中构建什么？"
            prompt={temporaryPrompt}
            provider={temporaryProvider}
            starting={startingTemporary}
            onPromptChange={setTemporaryPrompt}
            onProviderChange={setTemporaryProvider}
            onStart={() => void handleStartTemporarySession()}
          />
        ) : selectedProject ? (
          <SessionComposer
            title={`我们应该在 ${selectedProject.name} 中构建什么？`}
            prompt={currentProjectPrompt}
            provider={selectedProjectProvider}
            starting={startingProjectId === selectedProject.id}
            onPromptChange={(value) => setPromptByProjectId((current) => ({
              ...current,
              [selectedProject.id]: value,
            }))}
            onProviderChange={(provider) => setProviderByProjectId((current) => ({ ...current, [selectedProject.id]: provider }))}
            onStart={() => void handleStartProjectSession()}
          />
        ) : (
          <div className="session-launcher__empty-main">
            <button type="button" onClick={handleAddFolder} disabled={addingFolder}>
              {addingFolder ? <Loader2 size={16} className="spin" /> : <FolderPlus size={16} />}
              <span>Add folder</span>
            </button>
          </div>
        )}
      </main>
    </section>
  )
}

function SessionGroupHeader({
  title,
  count,
  action,
}: {
  title: string
  count: number
  action?: ReactNode
}) {
  return (
    <div className="session-launcher__group-header">
      <span>{title}</span>
      <em>{count}</em>
      {action}
    </div>
  )
}

function SessionList({
  groupId,
  sessions,
  selection,
  expandedSessionGroups,
  onToggleExpanded,
  onSelectSession,
  onTogglePinned,
  pinnedSessionIds,
}: {
  groupId: string
  sessions: Session[]
  selection: Selection | null
  expandedSessionGroups: Set<string>
  onToggleExpanded: Dispatch<SetStateAction<Set<string>>>
  onSelectSession: (session: Session) => void
  onTogglePinned: (session: Session) => void
  pinnedSessionIds: Set<string>
}) {
  const expanded = expandedSessionGroups.has(groupId)
  const visible = expanded ? sessions : sessions.slice(0, DEFAULT_VISIBLE_SESSIONS)
  if (sessions.length === 0) {
    return <div className="session-launcher__empty session-launcher__empty--compact">暂无对话</div>
  }
  return (
    <div className="session-launcher__session-list">
      {visible.map((session) => {
        const active = selection?.kind === 'session'
          && (selection.sessionId === session.id || selection.surfaceId === session.surfaceId)
        return (
          <SessionRow
            key={session.id}
            session={session}
            active={active}
            pinned={pinnedSessionIds.has(session.id)}
            onSelect={() => onSelectSession(session)}
            onTogglePinned={() => onTogglePinned(session)}
          />
        )
      })}
      {sessions.length > DEFAULT_VISIBLE_SESSIONS && (
        <button
          type="button"
          className="session-launcher__show-more"
          onClick={() => onToggleExpanded((current) => toggleSet(current, groupId))}
        >
          {expanded ? '收起' : '展开显示'}
        </button>
      )}
    </div>
  )
}

function SessionRow({
  session,
  active,
  pinned,
  onSelect,
  onTogglePinned,
}: {
  session: Session
  active: boolean
  pinned: boolean
  onSelect: () => void
  onTogglePinned: () => void
}) {
  const time = sessionRelativeTime(session)
  const statusLine = [session.status, time].filter(Boolean).join(' · ')
  return (
    <div className={`session-launcher__session-item${active ? ' is-selected' : ''}`}>
      <button
        type="button"
        className="session-launcher__session-row"
        onClick={onSelect}
        aria-label={`${sessionTitle(session)} ${statusLine}`}
      >
        <TerminalIcon size={14} aria-hidden />
        <span>
          <strong>{sessionTitle(session)}</strong>
          <small>{statusLine}</small>
        </span>
      </button>
      <button
        type="button"
        className="session-launcher__pin-button"
        onClick={onTogglePinned}
        aria-label={pinned ? `Unpin ${sessionTitle(session)}` : `Pin ${sessionTitle(session)}`}
        title={pinned ? 'Unpin' : 'Pin'}
      >
        {pinned ? <PinOff size={13} /> : <Pin size={13} />}
      </button>
    </div>
  )
}

function SessionComposer({
  title,
  prompt,
  provider,
  starting,
  onPromptChange,
  onProviderChange,
  onStart,
}: {
  title: string
  prompt: string
  provider: SpawnProvider
  starting: boolean
  onPromptChange: (value: string) => void
  onProviderChange: (provider: SpawnProvider) => void
  onStart: () => void
}) {
  return (
    <div className="session-launcher__composer-shell">
      <div className="session-launcher__composer">
        <h2>{title}</h2>
        <textarea
          value={prompt}
          onChange={(event) => onPromptChange(event.target.value)}
          placeholder="描述你想让本地 agent 完成的工作..."
          rows={4}
        />
        <div className="session-launcher__composer-footer">
          <div className="session-launcher__runtime" role="group" aria-label="Runtime">
            {PROVIDERS.map((item) => (
              <button
                key={item}
                type="button"
                className={provider === item ? 'is-selected' : ''}
                aria-pressed={provider === item}
                onClick={() => onProviderChange(item)}
              >
                {spawnProviderLabel(item)}
              </button>
            ))}
          </div>
          <button
            type="button"
            className="session-launcher__start"
            onClick={onStart}
            disabled={starting}
          >
            {starting ? <Loader2 size={16} className="spin" /> : <Play size={16} />}
            <span>Start session</span>
          </button>
        </div>
      </div>
    </div>
  )
}

function SessionLauncherTerminal({
  session,
  sessionId,
  surfaceId,
}: {
  session: Session | null
  sessionId: string
  surfaceId?: string | null
}) {
  const hostRef = useRef<HTMLDivElement | null>(null)
  const layoutFrameRef = useRef<number | null>(null)
  const layoutTimersRef = useRef<number[]>([])
  const lastRectRef = useRef<NativeTerminalRect | null>(null)
  const targetSurfaceId = session?.surfaceId ?? surfaceId ?? undefined
  const targetSessionId = session?.id ?? sessionId

  const syncTerminal = useCallback((type: 'attach' | 'layout' | 'focus' = 'layout', force = false) => {
    const host = hostRef.current
    if (!host || !targetSurfaceId) return
    const rect = host.getBoundingClientRect()
    const nextRect = {
      x: Math.round(rect.left),
      y: Math.round(rect.top),
      width: Math.round(rect.width),
      height: Math.round(rect.height),
    }
    if (type === 'layout' && !force && sameRect(lastRectRef.current, nextRect)) return
    lastRectRef.current = nextRect
    openNativeTerminalSurface({
      type,
      surfaceId: targetSurfaceId,
      sessionId: targetSessionId,
      rect: nextRect,
      sentAtMs: Date.now(),
      webPhase: `sessionLauncher.${type}`,
    })
  }, [targetSessionId, targetSurfaceId])

  const scheduleLayout = useCallback(() => {
    if (layoutFrameRef.current !== null) return
    layoutFrameRef.current = window.requestAnimationFrame(() => {
      layoutFrameRef.current = null
      syncTerminal('layout')
    })
  }, [syncTerminal])

  const scheduleStabilizedLayouts = useCallback(() => {
    layoutTimersRef.current.forEach((timer) => window.clearTimeout(timer))
    layoutTimersRef.current = [80, 180, 360, 700].map((delay) => window.setTimeout(() => {
      syncTerminal('layout', true)
    }, delay))
  }, [syncTerminal])

  useLayoutEffect(() => {
    syncTerminal('attach', true)
    scheduleStabilizedLayouts()
    const host = hostRef.current
    if (!host) return undefined
    const resizeObserver = new ResizeObserver(() => scheduleLayout())
    resizeObserver.observe(host)
    window.addEventListener('resize', scheduleLayout)
    return () => {
      if (layoutFrameRef.current !== null) window.cancelAnimationFrame(layoutFrameRef.current)
      layoutTimersRef.current.forEach((timer) => window.clearTimeout(timer))
      resizeObserver.disconnect()
      window.removeEventListener('resize', scheduleLayout)
      if (targetSurfaceId) {
        openNativeTerminalSurface({ type: 'hide', surfaceId: targetSurfaceId, sessionId: targetSessionId })
      }
      lastRectRef.current = null
    }
  }, [scheduleLayout, scheduleStabilizedLayouts, syncTerminal, targetSessionId, targetSurfaceId])

  useEffect(() => {
    syncTerminal('focus', true)
    scheduleStabilizedLayouts()
  }, [scheduleStabilizedLayouts, syncTerminal])

  return (
    <div className="session-launcher-terminal">
      <header className="session-launcher-terminal__header">
        <div>
          <strong>{session?.title ?? 'Starting session'}</strong>
          <span>{session?.project ?? 'Waiting for terminal surface'}</span>
        </div>
        <em>{session?.surfaceStatus ?? session?.status ?? 'starting'}</em>
      </header>
      <div ref={hostRef} className="session-launcher-terminal__host" />
      {!targetSurfaceId && (
        <div className="session-launcher-terminal__placeholder">
          Preparing native terminal...
        </div>
      )}
    </div>
  )
}

function toggleSet(values: Set<string>, value: string): Set<string> {
  const next = new Set(values)
  if (next.has(value)) next.delete(value)
  else next.add(value)
  return next
}

function normalizePath(path: string): string {
  return path.trim().replace(/\/+$/, '')
}

function compareSessions(a: Session, b: Session): number {
  return sessionTime(b) - sessionTime(a)
}

function sessionTime(session: Session): number {
  const raw = session.lastActivity ?? session.startedAt ?? ''
  const parsed = Date.parse(raw)
  return Number.isNaN(parsed) ? 0 : parsed
}

function projectTime(project: SessionProject): number {
  const raw = project.lastUsedAt ?? project.updatedAt ?? project.createdAt
  const parsed = Date.parse(raw)
  return Number.isNaN(parsed) ? 0 : parsed
}

function sessionTitle(session: Session): string {
  const title = session.title.trim()
  if (title) return title.replace(/\s+-\s+[^-]+$/, '')
  return session.pluginDisplayName || 'Session'
}

function sessionRelativeTime(session: Session): string {
  const raw = session.lastActivity ?? session.startedAt
  if (!raw) return ''
  const parsed = Date.parse(raw)
  if (Number.isNaN(parsed)) return ''
  const delta = Math.max(0, Date.now() - parsed)
  if (delta < 60_000) return '刚刚'
  const minutes = Math.floor(delta / 60_000)
  if (minutes < 60) return `${minutes} 分钟前`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} 小时前`
  const days = Math.floor(hours / 24)
  if (days < 14) return `${days} 天前`
  const weeks = Math.floor(days / 7)
  return `${weeks} 周前`
}

function sameRect(a: NativeTerminalRect | null, b: NativeTerminalRect): boolean {
  if (!a) return false
  return a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height
}

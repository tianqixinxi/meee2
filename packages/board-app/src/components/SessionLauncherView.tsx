import {
  Archive,
  ArrowUp,
  ChevronDown,
  Circle,
  Edit3,
  Folder,
  FolderPlus,
  FolderOpen,
  Loader2,
  MessageSquarePlus,
  Mic,
  MoreHorizontal,
  PencilLine,
  Pin,
  PinOff,
  Plus,
  Shield,
  Terminal as TerminalIcon,
  Trash2,
} from 'lucide-react'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { Dispatch, FormEvent, ReactNode, SetStateAction } from 'react'
import {
  createProjectSession,
  createSessionProject,
  createTemporarySession,
  fetchSessionProjects,
  forgetSessionProject,
  pickSessionProjectDirectory,
  renameSessionProject,
  reopenLauncherSession,
  revealSessionProjectInFinder,
  syncNativeSessionsWorkspace,
  updateSessionControl,
  type NativeTerminalRect,
} from '../api'
import { NATIVE_TERMINAL_STABILIZED_LAYOUT_DELAYS_MS } from '../lib/nativeTerminalLayout'
import { nativeTerminalTargetForSession } from '../lib/sessionTerminal'
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

type RestoredTerminalTarget = {
  sessionId: string
  surfaceId: string
}

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
  const [projectMenuId, setProjectMenuId] = useState<string | null>(null)
  const [renameProject, setRenameProject] = useState<SessionProject | null>(null)
  const [renameValue, setRenameValue] = useState('')
  const [renamingProjectId, setRenamingProjectId] = useState<string | null>(null)
  const [revealingProjectId, setRevealingProjectId] = useState<string | null>(null)
  const [reopeningSessionId, setReopeningSessionId] = useState<string | null>(null)
  const [archivingSessionId, setArchivingSessionId] = useState<string | null>(null)
  const [locallyArchivedSessionIds, setLocallyArchivedSessionIds] = useState<Set<string>>(() => new Set())
  const [restoredSessionTargets, setRestoredSessionTargets] = useState<Record<string, RestoredTerminalTarget>>({})
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

  useEffect(() => {
    if (!projectMenuId) return undefined
    const closeMenu = (event: PointerEvent) => {
      if (event.target instanceof Element && event.target.closest('[data-session-project-menu-root]')) return
      setProjectMenuId(null)
    }
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setProjectMenuId(null)
    }
    document.addEventListener('pointerdown', closeMenu)
    document.addEventListener('keydown', closeOnEscape)
    return () => {
      document.removeEventListener('pointerdown', closeMenu)
      document.removeEventListener('keydown', closeOnEscape)
    }
  }, [projectMenuId])

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
    () => sessions.filter((session) => session.controlState !== 'archived' && !locallyArchivedSessionIds.has(session.id)),
    [locallyArchivedSessionIds, sessions],
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
    return sessions.find((session) => sessionMatchesSelection(session, selection)) ?? null
  }, [selection, sessions])
  const selectedRestoredTarget = selection?.kind === 'session'
    ? restoredSessionTargets[selection.sessionId] ?? null
    : null

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

  const openProjectComposer = useCallback((project: SessionProject) => {
    setSelection({ kind: 'project', projectId: project.id })
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
    setProjectMenuId(null)
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

  const openRenameProject = useCallback((project: SessionProject) => {
    setProjectMenuId(null)
    setRenameProject(project)
    setRenameValue(project.name)
  }, [])

  const handleRenameProject = useCallback(async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (!renameProject) return
    const nextName = renameValue.trim()
    if (!nextName) {
      onToast?.('error', 'Project name is required')
      return
    }
    setRenamingProjectId(renameProject.id)
    try {
      const updated = await renameSessionProject(renameProject.id, { name: nextName })
      setProjects((current) => current.map((item) => item.id === updated.id ? updated : item))
      setRenameProject(null)
      setRenameValue('')
      onToast?.('success', `Renamed project to ${updated.name}`)
    } catch (err) {
      onToast?.('error', (err as Error).message || 'Failed to rename project')
    } finally {
      setRenamingProjectId(null)
    }
  }, [onToast, renameProject, renameValue])

  const handleRevealProject = useCallback(async (project: SessionProject) => {
    setProjectMenuId(null)
    setRevealingProjectId(project.id)
    try {
      await revealSessionProjectInFinder(project.id)
      onToast?.('success', `Revealed ${project.name} in Finder`)
    } catch (err) {
      onToast?.('error', (err as Error).message || 'Failed to reveal project')
    } finally {
      setRevealingProjectId(null)
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

  const handleSelectSession = useCallback(async (session: Session) => {
    setSelection({ kind: 'session', sessionId: session.id, surfaceId: session.surfaceId })
    if (nativeTerminalTargetForSession(session).surfaceId) return
    setReopeningSessionId(session.id)
    try {
      const result = await reopenLauncherSession({
        sessionId: session.id,
        provider: providerForSession(session),
        cwd: session.project,
      })
      setRestoredSessionTargets((current) => ({
        ...current,
        [session.id]: {
          sessionId: result.surface.sessionId,
          surfaceId: result.surface.surfaceId,
        },
      }))
      setSelection({
        kind: 'session',
        sessionId: session.id,
        surfaceId: result.surface.surfaceId,
      })
      onSessionCreated?.()
      if (result.action === 'resume') {
        onToast?.('success', `Resumed ${sessionTitle(session)}`)
      }
    } catch (err) {
      onToast?.('error', (err as Error).message || 'Failed to reopen session')
    } finally {
      setReopeningSessionId(null)
    }
  }, [onSessionCreated, onToast])

  const handleTogglePinned = useCallback((session: Session) => {
    const pinned = togglePinned(session.id)
    setPinnedSessionIds(loadPinnedSet())
    onToast?.('success', pinned ? 'Pinned session' : 'Unpinned session')
  }, [onToast])

  const handleArchiveSession = useCallback(async (session: Session) => {
    setArchivingSessionId(session.id)
    setLocallyArchivedSessionIds((current) => new Set([...current, session.id]))
    const previousSelection = selection
    if (selection?.kind === 'session' && selection.sessionId === session.id) {
      const ownerProject = projectForSession(session, explicitProjects)
      setSelection(ownerProject ? { kind: 'project', projectId: ownerProject.id } : { kind: 'temporaryDraft' })
    }
    try {
      await updateSessionControl(session.id, 'archive')
      setPinnedSessionIds(loadPinnedSet())
      setRestoredSessionTargets((current) => {
        if (!current[session.id]) return current
        const next = { ...current }
        delete next[session.id]
        return next
      })
      onSessionCreated?.()
      onToast?.('success', 'Session archived')
    } catch (err) {
      setLocallyArchivedSessionIds((current) => {
        const next = new Set(current)
        next.delete(session.id)
        return next
      })
      setSelection(previousSelection)
      onToast?.('error', (err as Error).message || 'Failed to archive session')
    } finally {
      setArchivingSessionId(null)
    }
  }, [explicitProjects, onSessionCreated, onToast, selection])

  return (
    <>
    <section className="session-launcher" aria-label="Session">
      <aside className="session-launcher__sidebar">
        <div className="session-launcher__sidebar-header">
          <div>
            <h1>Session</h1>
          </div>
        </div>
        {projectsError && <div className="session-launcher__error">{projectsError}</div>}
        <div className="session-launcher__project-list">
          <SessionGroupHeader title="置顶" />
          {grouped.pinned.length > 0 ? (
            <SessionList
              groupId="pinned"
              sessions={grouped.pinned}
              selection={selection}
              expandedSessionGroups={expandedSessionGroups}
              onToggleExpanded={setExpandedSessionGroups}
              onSelectSession={(session) => void handleSelectSession(session)}
              onTogglePinned={handleTogglePinned}
              onArchiveSession={(session) => void handleArchiveSession(session)}
              pinnedSessionIds={pinnedSessionIds}
              archivingSessionId={archivingSessionId}
            />
          ) : (
            <div className="session-launcher__empty session-launcher__empty--compact">暂无置顶</div>
          )}

          <SessionGroupHeader
            title="项目"
            action={(
              <button
                type="button"
                className="session-launcher__group-action"
                onClick={handleAddFolder}
                disabled={addingFolder}
                aria-label="Add folder"
                title="Add folder"
              >
                {addingFolder ? <Loader2 size={14} className="spin" /> : <FolderPlus size={14} />}
              </button>
            )}
          />
          {projectsLoading ? (
            <div className="session-launcher__empty">Loading projects</div>
          ) : sortedProjects.length === 0 ? (
            <div className="session-launcher__empty">Add a local folder to start.</div>
          ) : sortedProjects.map((project) => {
            const projectSessions = grouped.byProject.get(project.id) ?? []
            const expanded = expandedProjectIds.has(project.id)
            const selected = selection?.kind === 'project' && selection.projectId === project.id
            return (
              <div key={project.id} className={`session-launcher__project-group${selected ? ' is-selected' : ''}`}>
                <ProjectLauncherRow
                  project={project}
                  expanded={expanded}
                  selected={selected}
                  menuOpen={projectMenuId === project.id}
                  revealing={revealingProjectId === project.id}
                  onSelect={() => selectProject(project)}
                  onCompose={() => openProjectComposer(project)}
                  onToggleExpanded={() => setExpandedProjectIds((current) => toggleSet(current, project.id))}
                  onToggleMenu={() => setProjectMenuId((current) => current === project.id ? null : project.id)}
                  onRename={() => openRenameProject(project)}
                  onReveal={() => void handleRevealProject(project)}
                  onForget={() => void handleForgetProject(project)}
                />
                {expanded && (
                  <SessionList
                    groupId={`project:${project.id}`}
                    sessions={projectSessions}
                    selection={selection}
                    expandedSessionGroups={expandedSessionGroups}
                    onToggleExpanded={setExpandedSessionGroups}
                    onSelectSession={(session) => void handleSelectSession(session)}
                    onTogglePinned={handleTogglePinned}
                    onArchiveSession={(session) => void handleArchiveSession(session)}
                    pinnedSessionIds={pinnedSessionIds}
                    archivingSessionId={archivingSessionId}
                    nested
                  />
                )}
              </div>
            )
          })}

          <SessionGroupHeader
            title="临时对话"
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
            onSelectSession={(session) => void handleSelectSession(session)}
            onTogglePinned={handleTogglePinned}
            onArchiveSession={(session) => void handleArchiveSession(session)}
            pinnedSessionIds={pinnedSessionIds}
            archivingSessionId={archivingSessionId}
          />
        </div>
      </aside>
      <main className="session-launcher__main">
        {selection?.kind === 'session' ? (
          <SessionLauncherTerminal
            session={selectedSession}
            sessionId={selectedRestoredTarget?.sessionId ?? selection.sessionId}
            surfaceId={selectedRestoredTarget?.surfaceId ?? selection.surfaceId}
            reopening={reopeningSessionId === selection.sessionId}
          />
        ) : selection?.kind === 'temporaryDraft' ? (
          <SessionComposer
            title="我们应该在临时工作区中做些什么？"
            projectLabel="临时工作区"
            prompt={temporaryPrompt}
            provider={temporaryProvider}
            starting={startingTemporary}
            onPromptChange={setTemporaryPrompt}
            onProviderChange={setTemporaryProvider}
            onStart={() => void handleStartTemporarySession()}
          />
        ) : selectedProject ? (
          <SessionComposer
            title={`我们应该在${selectedProject.name}中做些什么？`}
            projectLabel={selectedProject.name}
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
    {renameProject && (
      <RenameProjectModal
        project={renameProject}
        value={renameValue}
        busy={renamingProjectId === renameProject.id}
        onValueChange={setRenameValue}
        onCancel={() => {
          setRenameProject(null)
          setRenameValue('')
        }}
        onSubmit={(event) => void handleRenameProject(event)}
      />
    )}
    </>
  )
}

function ProjectLauncherRow({
  project,
  expanded,
  selected,
  menuOpen,
  revealing,
  onSelect,
  onCompose,
  onToggleExpanded,
  onToggleMenu,
  onRename,
  onReveal,
  onForget,
}: {
  project: SessionProject
  expanded: boolean
  selected: boolean
  menuOpen: boolean
  revealing: boolean
  onSelect: () => void
  onCompose: () => void
  onToggleExpanded: () => void
  onToggleMenu: () => void
  onRename: () => void
  onReveal: () => void
  onForget: () => void
}) {
  return (
    <>
      <button
        type="button"
        className={`session-launcher__project-row${selected ? ' is-selected' : ''}`}
        onClick={onSelect}
      >
        <Folder size={16} aria-hidden />
        <span>
          <strong>{project.name}</strong>
          <small>{project.path}</small>
        </span>
      </button>
      <div className="session-launcher__project-actions" data-session-project-menu-root>
        <button
          type="button"
          onClick={onToggleExpanded}
          aria-label={expanded ? `Collapse ${project.name}` : `Expand ${project.name}`}
          title={expanded ? 'Collapse' : 'Expand'}
        >
          <ChevronDown size={14} className={expanded ? 'is-open' : ''} />
        </button>
        <div className="session-launcher__project-menu-wrap">
          <button
            type="button"
            onClick={onToggleMenu}
            aria-haspopup="menu"
            aria-expanded={menuOpen}
            aria-label={`More actions for ${project.name}`}
            title="More actions"
          >
            <MoreHorizontal size={15} />
          </button>
          {menuOpen && (
            <div className="session-launcher__project-menu" role="menu">
              <button type="button" role="menuitem" onClick={onRename}>
                <Edit3 size={13} aria-hidden />
                <span>Rename</span>
              </button>
              <button type="button" role="menuitem" onClick={onReveal} disabled={revealing}>
                {revealing ? <Loader2 size={13} className="spin" aria-hidden /> : <FolderOpen size={13} aria-hidden />}
                <span>Reveal in Finder</span>
              </button>
              <button type="button" role="menuitem" className="is-danger" onClick={onForget}>
                <Trash2 size={13} aria-hidden />
                <span>Forget project - keeps files</span>
              </button>
            </div>
          )}
        </div>
        <button
          type="button"
          onClick={onCompose}
          aria-label={`Compose in ${project.name}`}
          title="New session"
        >
          <PencilLine size={14} />
        </button>
      </div>
    </>
  )
}

function RenameProjectModal({
  project,
  value,
  busy,
  onValueChange,
  onCancel,
  onSubmit,
}: {
  project: SessionProject
  value: string
  busy: boolean
  onValueChange: (value: string) => void
  onCancel: () => void
  onSubmit: (event: FormEvent<HTMLFormElement>) => void
}) {
  const trimmed = value.trim()
  return (
    <div className="session-launcher-modal" role="presentation" onMouseDown={(event) => {
      if (event.target === event.currentTarget) onCancel()
    }}>
      <form className="session-launcher-modal__dialog" role="dialog" aria-modal="true" aria-label={`Rename ${project.name}`} onSubmit={onSubmit}>
        <header>
          <strong>Rename project</strong>
          <span>{project.path}</span>
        </header>
        <label>
          <span>Display name</span>
          <input
            autoFocus
            value={value}
            onChange={(event) => onValueChange(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Escape') onCancel()
            }}
          />
        </label>
        <footer>
          <button type="button" className="ghost" onClick={onCancel} disabled={busy}>Cancel</button>
          <button type="submit" disabled={busy || trimmed.length === 0}>
            {busy ? <Loader2 size={14} className="spin" /> : null}
            <span>Rename</span>
          </button>
        </footer>
      </form>
    </div>
  )
}

function SessionGroupHeader({
  title,
  action,
}: {
  title: string
  action?: ReactNode
}) {
  return (
    <div className="session-launcher__group-header">
      <span>{title}</span>
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
  onArchiveSession,
  pinnedSessionIds,
  archivingSessionId,
  nested = false,
}: {
  groupId: string
  sessions: Session[]
  selection: Selection | null
  expandedSessionGroups: Set<string>
  onToggleExpanded: Dispatch<SetStateAction<Set<string>>>
  onSelectSession: (session: Session) => void
  onTogglePinned: (session: Session) => void
  onArchiveSession: (session: Session) => void
  pinnedSessionIds: Set<string>
  archivingSessionId: string | null
  nested?: boolean
}) {
  const expanded = expandedSessionGroups.has(groupId)
  const visible = expanded ? sessions : sessions.slice(0, DEFAULT_VISIBLE_SESSIONS)
  if (sessions.length === 0) {
    return <div className="session-launcher__empty session-launcher__empty--compact">暂无对话</div>
  }
  return (
    <div className={`session-launcher__session-list${nested ? ' session-launcher__session-list--nested' : ''}`}>
      {visible.map((session) => {
        const active = selection?.kind === 'session' && sessionMatchesSelection(session, selection)
        return (
          <SessionRow
            key={session.id}
            session={session}
            active={active}
            pinned={pinnedSessionIds.has(session.id)}
            archiving={archivingSessionId === session.id}
            onSelect={() => onSelectSession(session)}
            onTogglePinned={() => onTogglePinned(session)}
            onArchive={() => onArchiveSession(session)}
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
  archiving,
  onSelect,
  onTogglePinned,
  onArchive,
}: {
  session: Session
  active: boolean
  pinned: boolean
  archiving: boolean
  onSelect: () => void
  onTogglePinned: () => void
  onArchive: () => void
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
      <div className="session-launcher__session-actions">
        <button
          type="button"
          className="session-launcher__pin-button"
          onClick={onTogglePinned}
          aria-label={pinned ? `Unpin ${sessionTitle(session)}` : `Pin ${sessionTitle(session)}`}
          title={pinned ? 'Unpin' : 'Pin'}
        >
          {pinned ? <PinOff size={13} /> : <Pin size={13} />}
        </button>
        <button
          type="button"
          className="session-launcher__archive-button"
          onClick={onArchive}
          disabled={archiving}
          aria-label={`Archive ${sessionTitle(session)}`}
          title="Archive"
        >
          {archiving ? <Loader2 size={13} className="spin" /> : <Archive size={13} />}
        </button>
      </div>
    </div>
  )
}

function SessionComposer({
  title,
  projectLabel,
  prompt,
  provider,
  starting,
  onPromptChange,
  onProviderChange,
  onStart,
}: {
  title: string
  projectLabel: string
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
        <div className="session-launcher__prompt-tray">
          <div className="session-launcher__prompt-card">
            <textarea
              value={prompt}
              onChange={(event) => onPromptChange(event.target.value)}
              placeholder="随心输入"
              rows={4}
            />
            <div className="session-launcher__composer-footer">
              <div className="session-launcher__composer-left">
                <button type="button" className="session-launcher__composer-icon" aria-label="Add context" title="Add context">
                  <Plus size={17} />
                </button>
                <button type="button" className="session-launcher__access-mode" aria-label="Full access" title="Full access">
                  <Shield size={15} />
                  <span>完全访问</span>
                  <ChevronDown size={14} />
                </button>
              </div>
              <div className="session-launcher__composer-right">
                <div className="session-launcher__runtime" role="group" aria-label="Runtime">
                  {PROVIDERS.map((item) => (
                    <button
                      key={item}
                      type="button"
                      className={provider === item ? 'is-selected' : ''}
                      aria-pressed={provider === item}
                      onClick={() => onProviderChange(nextSpawnProvider(provider))}
                      title={`Switch to ${spawnProviderLabel(nextSpawnProvider(provider))}`}
                    >
                      {provider === item ? <Circle size={13} /> : null}
                      <span>{spawnProviderLabel(item)}</span>
                      {provider === item ? <ChevronDown size={14} /> : null}
                    </button>
                  ))}
                </div>
                <button type="button" className="session-launcher__composer-icon" aria-label="Voice input" title="Voice input">
                  <Mic size={16} />
                </button>
                <button
                  type="button"
                  className="session-launcher__start"
                  onClick={onStart}
                  disabled={starting}
                  aria-label="Start session"
                  title="Start session"
                >
                  {starting ? <Loader2 size={18} className="spin" /> : <ArrowUp size={20} />}
                </button>
              </div>
            </div>
          </div>
          <div className="session-launcher__project-strip">
            <Folder size={16} />
            <span>{projectLabel}</span>
            <ChevronDown size={15} />
          </div>
        </div>
      </div>
    </div>
  )
}

function SessionLauncherTerminal({
  session,
  sessionId,
  surfaceId,
  reopening,
}: {
  session: Session | null
  sessionId: string
  surfaceId?: string | null
  reopening?: boolean
}) {
  const hostRef = useRef<HTMLDivElement | null>(null)
  const layoutFrameRef = useRef<number | null>(null)
  const layoutTimersRef = useRef<number[]>([])
  const lastRectRef = useRef<NativeTerminalRect | null>(null)
  const liveTarget = nativeTerminalTargetForSession(session)
  const suppliedSurfaceId = surfaceId?.trim() || undefined
  const targetSurfaceId = liveTarget.surfaceId ?? suppliedSurfaceId
  const targetSessionId = liveTarget.sessionId ?? (targetSurfaceId ? sessionId : undefined)
  const canOpenNativeTerminal = Boolean(targetSurfaceId && targetSessionId)

  const syncTerminal = useCallback((phase: 'show' | 'layout' | 'focus' = 'layout', force = false) => {
    const host = hostRef.current
    if (!host || !canOpenNativeTerminal) {
      syncNativeSessionsWorkspace({
        phase: 'hide',
        mode: 'terminal',
        webPhase: 'sessionLauncher.hide.missingTarget',
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
    if (phase === 'layout' && !force && sameRect(lastRectRef.current, nextRect)) return
    lastRectRef.current = nextRect
    syncNativeSessionsWorkspace({
      phase,
      mode: 'terminal',
      surfaceId: targetSurfaceId,
      sessionId: targetSessionId,
      rect: nextRect,
      sentAtMs: Date.now(),
      webPhase: `sessionLauncher.${phase}`,
    })
  }, [canOpenNativeTerminal, targetSessionId, targetSurfaceId])

  const scheduleLayout = useCallback(() => {
    if (layoutFrameRef.current !== null) return
    layoutFrameRef.current = window.requestAnimationFrame(() => {
      layoutFrameRef.current = null
      syncTerminal('layout')
    })
  }, [syncTerminal])

  const scheduleStabilizedLayouts = useCallback(() => {
    layoutTimersRef.current.forEach((timer) => window.clearTimeout(timer))
    layoutTimersRef.current = NATIVE_TERMINAL_STABILIZED_LAYOUT_DELAYS_MS.map((delay) => window.setTimeout(() => {
      syncTerminal('layout', true)
    }, delay))
  }, [syncTerminal])

  useLayoutEffect(() => {
    syncTerminal('show', true)
    scheduleStabilizedLayouts()
    const host = hostRef.current
    if (!host) return undefined
    const resizeObserver = new ResizeObserver(() => scheduleLayout())
    resizeObserver.observe(host)
    const handleWindowLayout = () => scheduleLayout()
    window.addEventListener('resize', handleWindowLayout)
    window.addEventListener('meee2:layout-native-sessions-workspace', handleWindowLayout)
    return () => {
      if (layoutFrameRef.current !== null) window.cancelAnimationFrame(layoutFrameRef.current)
      layoutTimersRef.current.forEach((timer) => window.clearTimeout(timer))
      resizeObserver.disconnect()
      window.removeEventListener('resize', handleWindowLayout)
      window.removeEventListener('meee2:layout-native-sessions-workspace', handleWindowLayout)
      syncNativeSessionsWorkspace({ phase: 'hide', mode: 'terminal' })
      lastRectRef.current = null
    }
  }, [scheduleLayout, scheduleStabilizedLayouts, syncTerminal, targetSessionId, targetSurfaceId])

  useEffect(() => {
    syncTerminal('focus', true)
    scheduleStabilizedLayouts()
  }, [scheduleStabilizedLayouts, syncTerminal])

  if (!canOpenNativeTerminal) {
    return (
      <div className="session-launcher__terminal-empty">
        {reopening ? <Loader2 size={18} className="spin" aria-hidden /> : <TerminalIcon size={18} aria-hidden />}
        <strong>{session ? sessionTitle(session) : 'Session'}</strong>
        <span>{reopening ? '正在恢复原生 terminal session...' : '这个 session 还没有可挂载的原生 terminal surface'}</span>
      </div>
    )
  }

  return (
    <div className="session-launcher-terminal">
      <header className="session-launcher-terminal__header">
        <div>
          <strong>{session ? sessionTitle(session) : 'Starting session'}</strong>
          <span>{session?.project ?? 'Waiting for terminal surface'}</span>
        </div>
        <em>{session?.surfaceStatus ?? session?.status ?? 'starting'}</em>
      </header>
      <div ref={hostRef} className="session-launcher-terminal__host" />
    </div>
  )
}

function toggleSet(values: Set<string>, value: string): Set<string> {
  const next = new Set(values)
  if (next.has(value)) next.delete(value)
  else next.add(value)
  return next
}

function sessionMatchesSelection(session: Session, selection: Extract<Selection, { kind: 'session' }>): boolean {
  if (session.id === selection.sessionId) return true
  return Boolean(selection.surfaceId && session.surfaceId && selection.surfaceId === session.surfaceId)
}

function providerForSession(session: Session): SpawnProvider {
  const raw = `${session.pluginId} ${session.pluginDisplayName} ${session.title}`.toLowerCase()
  return raw.includes('codex') ? 'codex' : 'claude'
}

function projectForSession(session: Session, projects: SessionProject[]): SessionProject | null {
  const path = normalizePath(session.project || '')
  if (!path) return null
  return projects.find((project) => normalizePath(project.path) === path) ?? null
}

function normalizePath(path: string): string {
  return path.trim().replace(/\/+$/, '')
}

function nextSpawnProvider(provider: SpawnProvider): SpawnProvider {
  return provider === 'codex' ? 'claude' : 'codex'
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
  const candidates = [
    session.latestRecap?.content,
    session.currentTask,
    initialUserMessage(session),
    session.title,
  ]
  for (const candidate of candidates) {
    const title = cleanSessionTitle(candidate)
    if (title) return title
  }
  return session.pluginDisplayName || 'Session'
}

function initialUserMessage(session: Session): string | null {
  for (const entry of session.recentMessages) {
    if (entry.role.toLowerCase() === 'user' && entry.text.trim()) return entry.text
  }
  return null
}

function cleanSessionTitle(raw: string | null | undefined): string {
  const value = raw
    ?.replace(/\[[^\]]+\]\([^)]+\)/g, '')
    .replace(/\s+/g, ' ')
    .trim() ?? ''
  if (!value) return ''
  const firstSentence = value.split(/\n|。|[.!?]\s/)[0]?.trim() ?? value
  const withoutSpeaker = firstSentence.replace(/^(user|assistant|human|system)\s*:\s*/i, '').trim()
  const genericProviderTitle = /^(codex|claude code|claude)\s+-\s+[^/\\]+$/i
  const internalNodeTitle = /^node\s+(?:node-)?[a-z0-9][a-z0-9-]{10,}(?:-transcript)?$/i
  if (genericProviderTitle.test(withoutSpeaker)) return ''
  if (internalNodeTitle.test(withoutSpeaker)) return ''
  return withoutSpeaker.length > 56 ? `${withoutSpeaker.slice(0, 54).trim()}...` : withoutSpeaker
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

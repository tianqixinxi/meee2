import {
  Archive,
  AlertCircle,
  ArrowUp,
  ChevronDown,
  CheckCircle2,
  Edit3,
  FileText,
  Folder,
  FolderPlus,
  FolderOpen,
  Loader2,
  MessageSquarePlus,
  MoreHorizontal,
  PanelLeftClose,
  PanelLeftOpen,
  Paperclip,
  PencilLine,
  Pin,
  PinOff,
  Trash2,
  X,
} from 'lucide-react'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type {
  CSSProperties,
  ClipboardEvent as ReactClipboardEvent,
  Dispatch,
  FormEvent,
  KeyboardEvent as ReactKeyboardEvent,
  MouseEvent as ReactMouseEvent,
  PointerEvent as ReactPointerEvent,
  ReactNode,
  SetStateAction,
} from 'react'
import {
  createProjectSession,
  createSessionProject,
  createTemporarySession,
  fetchSessionProjects,
  forgetSessionProject,
  pickSessionProjectDirectory,
  pickSessionLaunchAttachments,
  renameSessionProject,
  reopenLauncherSession,
  revealSessionProjectInFinder,
  syncNativeSessionsWorkspace,
  updateSessionControl,
  uploadSessionLaunchAttachment,
  type NativeTerminalRect,
} from '../api'
import { nativeTerminalTargetForSession } from '../lib/sessionTerminal'
import { useTheme } from '../lib/theme'
import { useI18n, type TranslationKey } from '../lib/i18n'
import { spawnProviderLabel } from '../preferences'
import { loadPinnedSet, loadTitleOverrides, saveTitleOverride, togglePinned } from '../sessionOverrides'
import type { AgentPermissionMode, BoardState, Session, SessionLaunchAttachment, SessionProject, SpawnProvider } from '../types'

interface Props {
  state: BoardState | null
  onSessionCreated?: () => void
  onOpenSessionArtifacts?: (session: Session, title: string, filter: SessionArtifactFilterPayload) => void
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

export type SessionArtifactFilterPayload = {
  sessionId: string
  title: string
  providerResumeSessionId?: string | null
  surfaceId?: string | null
  project?: string | null
  projectName?: string | null
}

const DEFAULT_PROMPT = ''
const PROVIDERS: SpawnProvider[] = ['codex', 'claude']
const DEFAULT_PERMISSION_MODE: AgentPermissionMode = 'fullAccess'
const DEFAULT_VISIBLE_SESSIONS = 8
const TEMPORARY_GROUP_ID = 'temporary'
const SIDEBAR_WIDTH_KEY = 'meee2.sessionLauncher.sidebarWidth'
const SIDEBAR_COLLAPSED_KEY = 'meee2.sessionLauncher.sidebarCollapsed'
const LAST_SELECTION_KEY = 'meee2.sessionLauncher.lastSelection'
const LEGACY_DEFAULT_SIDEBAR_WIDTH = 324
const DEFAULT_SIDEBAR_WIDTH = 280
const MIN_SIDEBAR_WIDTH = 248
const MAX_SIDEBAR_WIDTH = 520
const ENTER_SUBMIT_ARM_MS = 1800
const SESSION_CONTEXT_MENU_WIDTH = 190
const SESSION_CONTEXT_MENU_HEIGHT = 152

function readStoredSidebarWidth(): number {
  if (typeof window === 'undefined') return DEFAULT_SIDEBAR_WIDTH
  const raw = window.localStorage.getItem(SIDEBAR_WIDTH_KEY)
  const parsed = raw ? Number.parseInt(raw, 10) : Number.NaN
  if (parsed === LEGACY_DEFAULT_SIDEBAR_WIDTH) return DEFAULT_SIDEBAR_WIDTH
  return Number.isFinite(parsed) ? clampSidebarWidth(parsed) : DEFAULT_SIDEBAR_WIDTH
}

function readStoredSidebarCollapsed(): boolean {
  if (typeof window === 'undefined') return false
  return window.localStorage.getItem(SIDEBAR_COLLAPSED_KEY) === '1'
}

function clampSidebarWidth(width: number): number {
  return Math.min(MAX_SIDEBAR_WIDTH, Math.max(MIN_SIDEBAR_WIDTH, Math.round(width)))
}

function mergeLaunchAttachments(
  current: SessionLaunchAttachment[],
  additions: SessionLaunchAttachment[],
): SessionLaunchAttachment[] {
  const next = [...current]
  const seen = new Set(next.map((item) => item.path))
  for (const attachment of additions) {
    const path = attachment.path?.trim()
    if (!path || seen.has(path)) continue
    seen.add(path)
    const parts = path.split('/').filter(Boolean)
    next.push({
      ...attachment,
      path,
      filename: attachment.filename || parts[parts.length - 1] || path,
    })
  }
  return next
}

function removeLaunchAttachment(
  current: SessionLaunchAttachment[],
  path: string,
): SessionLaunchAttachment[] {
  return current.filter((attachment) => attachment.path !== path)
}

function truncateAttachmentName(name: string, max = 28): string {
  return name.length <= max ? name : `${name.slice(0, max - 3)}...`
}

function readStoredSelection(): Selection | null {
  if (typeof window === 'undefined') return null
  const raw = window.localStorage.getItem(LAST_SELECTION_KEY)
  if (!raw) return null
  try {
    const parsed = JSON.parse(raw) as Partial<Selection> | null
    if (!parsed || typeof parsed !== 'object') return null
    if (parsed.kind === 'temporaryDraft') return { kind: 'temporaryDraft' }
    if (parsed.kind === 'project' && typeof parsed.projectId === 'string' && parsed.projectId.trim()) {
      return { kind: 'project', projectId: parsed.projectId }
    }
    if (parsed.kind === 'session' && typeof parsed.sessionId === 'string' && parsed.sessionId.trim()) {
      return {
        kind: 'session',
        sessionId: parsed.sessionId,
        surfaceId: null,
      }
    }
  } catch {
    window.localStorage.removeItem(LAST_SELECTION_KEY)
  }
  return null
}

type PermissionOption = {
  value: AgentPermissionMode
  labelKey: TranslationKey
  command: string
}

type SessionContextMenu = {
  session: Session
  x: number
  y: number
}

const PERMISSION_OPTIONS: Record<SpawnProvider, PermissionOption[]> = {
  codex: [
    {
      value: 'fullAccess',
      labelKey: 'sessions.launcher.permission.codexFullAccess',
      command: 'codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust',
    },
    {
      value: 'onRequest',
      labelKey: 'sessions.launcher.permission.codexOnRequest',
      command: 'codex --sandbox workspace-write --ask-for-approval on-request --dangerously-bypass-hook-trust',
    },
    {
      value: 'readOnly',
      labelKey: 'sessions.launcher.permission.codexReadOnly',
      command: 'codex --sandbox read-only --ask-for-approval on-request --dangerously-bypass-hook-trust',
    },
  ],
  claude: [
    {
      value: 'fullAccess',
      labelKey: 'sessions.launcher.permission.claudeFullAccess',
      command: 'claude --dangerously-skip-permissions',
    },
    {
      value: 'default',
      labelKey: 'sessions.launcher.permission.claudeDefault',
      command: 'claude --permission-mode default',
    },
    {
      value: 'acceptEdits',
      labelKey: 'sessions.launcher.permission.claudeAcceptEdits',
      command: 'claude --permission-mode acceptEdits',
    },
  ],
}

export function SessionLauncherView({
  state,
  onSessionCreated,
  onOpenSessionArtifacts,
  onToast,
}: Props) {
  const { t } = useI18n()
  const { resolvedTheme } = useTheme()
  const [initialSelection] = useState<Selection | null>(() => readStoredSelection())
  const [projects, setProjects] = useState<SessionProject[]>([])
  const [projectsLoading, setProjectsLoading] = useState(true)
  const [projectsError, setProjectsError] = useState<string | null>(null)
  const [selection, setSelection] = useState<Selection | null>(initialSelection)
  const [expandedProjectIds, setExpandedProjectIds] = useState<Set<string>>(() => (
    initialSelection?.kind === 'project' ? new Set([initialSelection.projectId]) : new Set()
  ))
  const [expandedSessionGroups, setExpandedSessionGroups] = useState<Set<string>>(() => new Set())
  const [promptByProjectId, setPromptByProjectId] = useState<Record<string, string>>({})
  const [providerByProjectId, setProviderByProjectId] = useState<Record<string, SpawnProvider>>({})
  const [permissionModeByProjectId, setPermissionModeByProjectId] = useState<Record<string, AgentPermissionMode>>({})
  const [planModeByProjectId, setPlanModeByProjectId] = useState<Record<string, boolean>>({})
  const [attachmentsByProjectId, setAttachmentsByProjectId] = useState<Record<string, SessionLaunchAttachment[]>>({})
  const [temporaryPrompt, setTemporaryPrompt] = useState(DEFAULT_PROMPT)
  const [temporaryProvider, setTemporaryProvider] = useState<SpawnProvider>('codex')
  const [temporaryPermissionMode, setTemporaryPermissionMode] = useState<AgentPermissionMode>(DEFAULT_PERMISSION_MODE)
  const [temporaryPlanMode, setTemporaryPlanMode] = useState(false)
  const [temporaryAttachments, setTemporaryAttachments] = useState<SessionLaunchAttachment[]>([])
  const [pinnedSessionIds, setPinnedSessionIds] = useState<Set<string>>(() => loadPinnedSet())
  const [titleOverrides, setTitleOverrides] = useState<Record<string, string>>(() => loadTitleOverrides())
  const [addingFolder, setAddingFolder] = useState(false)
  const [startingProjectId, setStartingProjectId] = useState<string | null>(null)
  const [startingTemporary, setStartingTemporary] = useState(false)
  const [projectMenuId, setProjectMenuId] = useState<string | null>(null)
  const [renameProject, setRenameProject] = useState<SessionProject | null>(null)
  const [forgetProject, setForgetProject] = useState<SessionProject | null>(null)
  const [archiveSession, setArchiveSession] = useState<Session | null>(null)
  const [sessionMenu, setSessionMenu] = useState<SessionContextMenu | null>(null)
  const [renameSession, setRenameSession] = useState<Session | null>(null)
  const [renameValue, setRenameValue] = useState('')
  const [renameSessionValue, setRenameSessionValue] = useState('')
  const [renamingProjectId, setRenamingProjectId] = useState<string | null>(null)
  const [forgettingProjectId, setForgettingProjectId] = useState<string | null>(null)
  const [revealingProjectId, setRevealingProjectId] = useState<string | null>(null)
  const [archivingSessionId, setArchivingSessionId] = useState<string | null>(null)
  const [reopeningSessionId, setReopeningSessionId] = useState<string | null>(null)
  const [locallyArchivedSessionIds, setLocallyArchivedSessionIds] = useState<Set<string>>(() => new Set())
  const [restoredSessionTargets, setRestoredSessionTargets] = useState<Record<string, RestoredTerminalTarget>>({})
  const [sidebarWidth, setSidebarWidth] = useState(() => readStoredSidebarWidth())
  const [sidebarCollapsed, setSidebarCollapsed] = useState(() => readStoredSidebarCollapsed())
  const initializedSelectionRef = useRef(initialSelection !== null)
  const autoRestoreAttemptedRef = useRef<Set<string>>(new Set())
  const pointerSidebarResizeActiveRef = useRef(false)
  const sessions = state?.sessions ?? []

  const refreshProjects = useCallback(() => {
    setProjectsLoading(true)
    setProjectsError(null)
    fetchSessionProjects()
      .then((result) => {
        const projectList = Array.isArray(result?.projects) ? result.projects : []
        setProjects(projectList.filter((project) => project.explicit))
      })
      .catch((err: Error) => setProjectsError(err.message || t('sessions.launcher.projectsLoadFailed')))
      .finally(() => setProjectsLoading(false))
  }, [t])

  useEffect(() => {
    refreshProjects()
  }, [refreshProjects])

  useEffect(() => {
    const refreshOverrides = () => {
      setPinnedSessionIds(loadPinnedSet())
      setTitleOverrides(loadTitleOverrides())
    }
    window.addEventListener('meee2:session-overrides-changed', refreshOverrides)
    return () => window.removeEventListener('meee2:session-overrides-changed', refreshOverrides)
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

  useEffect(() => {
    if (!sessionMenu) return undefined
    const closeMenu = () => setSessionMenu(null)
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setSessionMenu(null)
    }
    document.addEventListener('pointerdown', closeMenu)
    document.addEventListener('keydown', closeOnEscape)
    return () => {
      document.removeEventListener('pointerdown', closeMenu)
      document.removeEventListener('keydown', closeOnEscape)
    }
  }, [sessionMenu])

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
    () => sessions.filter((session) => (
      session.controlState !== 'archived'
      && session.controlState !== 'hidden'
      && !locallyArchivedSessionIds.has(session.id)
      && sessionIsVisibleInLauncher(session)
    )),
    [locallyArchivedSessionIds, sessions],
  )
  const launcherSessions = useMemo(
    () => collapseRestoredLauncherSessions(activeSessions, selection, restoredSessionTargets),
    [activeSessions, restoredSessionTargets, selection],
  )

  const grouped = useMemo(() => {
    const byProject = new Map<string, Session[]>()
    for (const project of explicitProjects) byProject.set(project.id, [])
    const pinned: Session[] = []
    const temporary: Session[] = []
    const external: Session[] = []

    for (const session of launcherSessions) {
      if (pinnedSessionIds.has(session.id)) {
        pinned.push(session)
        continue
      }
      if (sessionScope(session) === 'external') {
        external.push(session)
        continue
      }
      const project = projectByPath.get(normalizePath(session.project))
      if (project) byProject.get(project.id)?.push(session)
      else temporary.push(session)
    }

    for (const list of byProject.values()) list.sort(compareSessions)
    pinned.sort(compareSessions)
    temporary.sort(compareSessions)
    external.sort(compareSessions)
    return { byProject, pinned, temporary, external }
  }, [explicitProjects, launcherSessions, pinnedSessionIds, projectByPath])

  const latestProjectSessionTimes = useMemo(() => {
    const times = new Map<string, number>()
    for (const session of launcherSessions) {
      const project = projectByPath.get(normalizePath(session.project))
      if (!project) continue
      times.set(project.id, Math.max(times.get(project.id) ?? 0, sessionTime(session)))
    }
    return times
  }, [launcherSessions, projectByPath])

  const sortedProjects = useMemo(() => {
    return [...explicitProjects].sort((a, b) => {
      const aTime = latestProjectSessionTimes.get(a.id) ?? projectTime(a)
      const bTime = latestProjectSessionTimes.get(b.id) ?? projectTime(b)
      if (aTime !== bTime) return bTime - aTime
      return a.name.localeCompare(b.name, undefined, { sensitivity: 'base' })
    })
  }, [explicitProjects, latestProjectSessionTimes])

  const reopenLauncherSessionForSession = useCallback((session: Session) => {
    const resumeSessionId = providerResumeTargetForSession(session)
    if (!sessionCanBeReopened(session) || reopeningSessionId === session.id) return
    setReopeningSessionId(session.id)
    reopenLauncherSession({
      sessionId: session.id,
      providerResumeSessionId: resumeSessionId,
      provider: launcherProviderForSession(session),
      cwd: session.project || undefined,
    })
      .then((result) => {
        setRestoredSessionTargets((current) => ({
          ...current,
          [session.id]: {
            sessionId: result.surface.sessionId,
            surfaceId: result.surface.surfaceId,
          },
        }))
        setSelection((current) => current?.kind === 'session' && current.sessionId === session.id
          ? { kind: 'session', sessionId: session.id, surfaceId: result.surface.surfaceId }
          : current)
        onSessionCreated?.()
        const title = sessionDisplayTitle(session, titleOverrides)
        const toastKey = result.action === 'reuse'
          ? 'sessions.launcher.reusedSession'
          : result.action === 'resume'
            ? 'sessions.launcher.resumedSession'
            : 'sessions.launcher.recreatedSession'
        onToast?.('success', t(toastKey, { title }))
      })
      .catch((err: Error) => {
        onToast?.('error', err.message || t('sessions.launcher.noTerminalSurface'))
      })
      .finally(() => setReopeningSessionId((current) => current === session.id ? null : current))
  }, [onSessionCreated, onToast, reopeningSessionId, t, titleOverrides])

  useEffect(() => {
    if (selection || initializedSelectionRef.current || state === null) return
    const latestSession = [...launcherSessions].sort(compareSessions)[0]
    if (latestSession) {
      initializedSelectionRef.current = true
      setSelection({ kind: 'session', sessionId: latestSession.id, surfaceId: latestSession.surfaceId })
      reopenLauncherSessionForSession(latestSession)
      return
    }
    const first = sortedProjects[0]
    if (first) {
      initializedSelectionRef.current = true
      setSelection({ kind: 'project', projectId: first.id })
      setExpandedProjectIds(new Set([first.id]))
    }
  }, [launcherSessions, reopenLauncherSessionForSession, selection, sortedProjects, state])

  useEffect(() => {
    window.localStorage.setItem(SIDEBAR_WIDTH_KEY, String(sidebarWidth))
  }, [sidebarWidth])

  useEffect(() => {
    window.localStorage.setItem(SIDEBAR_COLLAPSED_KEY, sidebarCollapsed ? '1' : '0')
  }, [sidebarCollapsed])

  useEffect(() => {
    if (!selection) {
      window.localStorage.removeItem(LAST_SELECTION_KEY)
      return
    }
    window.localStorage.setItem(LAST_SELECTION_KEY, JSON.stringify(selection))
  }, [selection])

  useEffect(() => {
    if (selection?.kind !== 'session') return
    const session = launcherSessions.find((item) => sessionMatchesSelection(item, selection))
    if (!session) return
    if (pinnedSessionIds.has(session.id)) {
      setExpandedSessionGroups((current) => addToSet(current, 'pinned'))
      return
    }
    if (sessionScope(session) === 'external') {
      setExpandedSessionGroups((current) => addToSet(current, 'external'))
      return
    }
    const project = projectByPath.get(normalizePath(session.project))
    if (project) {
      setExpandedProjectIds((current) => addToSet(current, project.id))
      setExpandedSessionGroups((current) => addToSet(current, `project:${project.id}`))
      return
    }
    setExpandedSessionGroups((current) => addToSet(current, TEMPORARY_GROUP_ID))
  }, [launcherSessions, pinnedSessionIds, projectByPath, selection])

  const selectedProject = useMemo(() => {
    if (selection?.kind !== 'project') return null
    return explicitProjects.find((project) => project.id === selection.projectId) ?? null
  }, [explicitProjects, selection])

  const selectedSession = useMemo(() => {
    if (selection?.kind !== 'session') return null
    return selectedSessionForSelection(sessions, selection)
  }, [selection, sessions])
  const selectedLiveTarget = nativeTerminalTargetForSession(selectedSession)
  const selectedRestoredTarget = selection?.kind === 'session'
    ? restoredSessionTargets[selection.sessionId] ?? null
    : null
  const selectedRestoredSession = useMemo(() => {
    if (!selectedRestoredTarget) return null
    return sessions.find((session) => {
      if (selectedRestoredTarget.sessionId && session.id === selectedRestoredTarget.sessionId) return true
      return Boolean(selectedRestoredTarget.surfaceId && session.surfaceId === selectedRestoredTarget.surfaceId)
    }) ?? null
  }, [selectedRestoredTarget, sessions])

  useEffect(() => {
    if (selection?.kind !== 'session' || !selectedSession || selectedRestoredTarget) return
    if (!sessionCanBeReopened(selectedSession)) return
    const resumeTarget = providerResumeTargetForSession(selectedSession)
    const restoreKey = `${selection.sessionId}:${resumeTarget ?? ''}`
    if (autoRestoreAttemptedRef.current.has(restoreKey)) return
    autoRestoreAttemptedRef.current.add(restoreKey)
    reopenLauncherSessionForSession(selectedSession)
  }, [reopenLauncherSessionForSession, selectedRestoredTarget, selectedSession, selection])

  const selectedProjectProvider = selectedProject
    ? providerByProjectId[selectedProject.id] ?? selectedProject.preferredProvider
    : temporaryProvider
  const selectedProjectPermissionMode = selectedProject
    ? normalizePermissionMode(selectedProjectProvider, permissionModeByProjectId[selectedProject.id])
    : normalizePermissionMode(temporaryProvider, temporaryPermissionMode)
  const selectedProjectPlanMode = selectedProject
    ? planModeByProjectId[selectedProject.id] === true
    : temporaryPlanMode
  const currentProjectPrompt = selectedProject
    ? promptByProjectId[selectedProject.id] ?? DEFAULT_PROMPT
    : DEFAULT_PROMPT
  const currentProjectAttachments = selectedProject
    ? attachmentsByProjectId[selectedProject.id] ?? []
    : []

  const selectProject = useCallback((project: SessionProject) => {
    setSelection({ kind: 'project', projectId: project.id })
    setExpandedProjectIds((current) => addToSet(current, project.id))
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
      setExpandedProjectIds((current) => addToSet(current, project.id))
      onToast?.('success', t('sessions.launcher.projectAdded', { name: project.name }))
    } catch (err) {
      onToast?.('error', (err as Error).message || t('sessions.launcher.addFolderFailed'))
    } finally {
      setAddingFolder(false)
    }
  }, [onToast, selectedProjectProvider, t])

  const handleForgetProject = useCallback(async (project: SessionProject) => {
    setProjectMenuId(null)
    setForgettingProjectId(project.id)
    try {
      await forgetSessionProject(project.id)
      setProjects((current) => current.filter((item) => item.id !== project.id))
      setSelection((current) => current?.kind === 'project' && current.projectId === project.id ? null : current)
      setExpandedProjectIds((current) => {
        const next = new Set(current)
        next.delete(project.id)
        return next
      })
      onToast?.('success', t('sessions.launcher.projectForgotten', { name: project.name }))
    } catch (err) {
      onToast?.('error', (err as Error).message || t('sessions.launcher.forgetProjectFailed'))
    } finally {
      setForgettingProjectId(null)
      setForgetProject(null)
    }
  }, [onToast, t])

  const openRenameProject = useCallback((project: SessionProject) => {
    setProjectMenuId(null)
    setRenameProject(project)
    setRenameValue(project.name)
  }, [])

  const openForgetProject = useCallback((project: SessionProject) => {
    setProjectMenuId(null)
    setForgetProject(project)
  }, [])

  const handleRenameProject = useCallback(async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (!renameProject) return
    const nextName = renameValue.trim()
    if (!nextName) {
      onToast?.('error', t('sessions.launcher.projectNameRequired'))
      return
    }
    setRenamingProjectId(renameProject.id)
    try {
      const updated = await renameSessionProject(renameProject.id, { name: nextName })
      setProjects((current) => current.map((item) => item.id === updated.id ? updated : item))
      setRenameProject(null)
      setRenameValue('')
      onToast?.('success', t('sessions.launcher.projectRenamed', { name: updated.name }))
    } catch (err) {
      onToast?.('error', (err as Error).message || t('sessions.launcher.renameProjectFailed'))
    } finally {
      setRenamingProjectId(null)
    }
  }, [onToast, renameProject, renameValue, t])

  const handleRevealProject = useCallback(async (project: SessionProject) => {
    setProjectMenuId(null)
    setRevealingProjectId(project.id)
    try {
      await revealSessionProjectInFinder(project.id)
      onToast?.('success', t('sessions.launcher.projectRevealed', { name: project.name }))
    } catch (err) {
      onToast?.('error', (err as Error).message || t('sessions.launcher.revealProjectFailed'))
    } finally {
      setRevealingProjectId(null)
    }
  }, [onToast, t])

  const handlePickProjectAttachments = useCallback(async (projectId: string) => {
    const result = await pickSessionLaunchAttachments()
    if (!result.attachments?.length) return
    setAttachmentsByProjectId((current) => ({
      ...current,
      [projectId]: mergeLaunchAttachments(current[projectId] ?? [], result.attachments),
    }))
  }, [])

  const handleUploadProjectAttachment = useCallback(async (projectId: string, file: File) => {
    const attachment = await uploadSessionLaunchAttachment(file)
    setAttachmentsByProjectId((current) => ({
      ...current,
      [projectId]: mergeLaunchAttachments(current[projectId] ?? [], [attachment]),
    }))
  }, [])

  const handlePickTemporaryAttachments = useCallback(async () => {
    const result = await pickSessionLaunchAttachments()
    if (!result.attachments?.length) return
    setTemporaryAttachments((current) => mergeLaunchAttachments(current, result.attachments))
  }, [])

  const handleUploadTemporaryAttachment = useCallback(async (file: File) => {
    const attachment = await uploadSessionLaunchAttachment(file)
    setTemporaryAttachments((current) => mergeLaunchAttachments(current, [attachment]))
  }, [])

  const handleStartProjectSession = useCallback(async () => {
    if (!selectedProject) return
    const prompt = currentProjectPrompt.trim()
    const attachments = currentProjectAttachments
    setStartingProjectId(selectedProject.id)
    try {
      const launchInput: Parameters<typeof createProjectSession>[0] = {
        projectId: selectedProject.id,
        provider: selectedProjectProvider,
        permissionMode: selectedProjectPermissionMode,
        planMode: selectedProjectPlanMode,
        initialPrompt: prompt || undefined,
      }
      if (attachments.length > 0) launchInput.attachments = attachments
      const result = await createProjectSession(launchInput)
      setProjects((current) => [result.project, ...current.filter((item) => item.id !== result.project.id)])
      setProviderByProjectId((current) => ({ ...current, [result.project.id]: result.project.preferredProvider }))
      setPromptByProjectId((current) => ({ ...current, [result.project.id]: DEFAULT_PROMPT }))
      setAttachmentsByProjectId((current) => ({ ...current, [result.project.id]: [] }))
      setSelection({
        kind: 'session',
        sessionId: result.surface.sessionId,
        surfaceId: result.surface.surfaceId,
      })
      setExpandedProjectIds((current) => addToSet(current, result.project.id))
      onSessionCreated?.()
      onToast?.('success', t('sessions.launcher.startedInProject', {
        provider: spawnProviderLabel(selectedProjectProvider),
        project: result.project.name,
      }))
    } catch (err) {
      onToast?.('error', (err as Error).message || t('sessions.launcher.startSessionFailed'))
    } finally {
      setStartingProjectId(null)
    }
  }, [currentProjectAttachments, currentProjectPrompt, onSessionCreated, onToast, selectedProject, selectedProjectPermissionMode, selectedProjectPlanMode, selectedProjectProvider, t])

  const handleStartTemporarySession = useCallback(async () => {
    const prompt = temporaryPrompt.trim()
    const attachments = temporaryAttachments
    setStartingTemporary(true)
    try {
      const launchInput: Parameters<typeof createTemporarySession>[0] = {
        provider: temporaryProvider,
        permissionMode: temporaryPermissionMode,
        planMode: temporaryPlanMode,
        initialPrompt: prompt || undefined,
      }
      if (attachments.length > 0) launchInput.attachments = attachments
      const result = await createTemporarySession(launchInput)
      setSelection({
        kind: 'session',
        sessionId: result.surface.sessionId,
        surfaceId: result.surface.surfaceId,
      })
      setTemporaryPrompt(DEFAULT_PROMPT)
      setTemporaryAttachments([])
      setExpandedSessionGroups((current) => new Set([...current, TEMPORARY_GROUP_ID]))
      onSessionCreated?.()
      onToast?.('success', t('sessions.launcher.startedTemporary', { provider: spawnProviderLabel(temporaryProvider) }))
    } catch (err) {
      onToast?.('error', (err as Error).message || t('sessions.launcher.startTemporaryFailed'))
    } finally {
      setStartingTemporary(false)
    }
  }, [onSessionCreated, onToast, temporaryAttachments, temporaryPermissionMode, temporaryPlanMode, temporaryPrompt, temporaryProvider, t])

  const handleSelectSession = useCallback((session: Session) => {
    setSessionMenu(null)
    setSelection({ kind: 'session', sessionId: session.id, surfaceId: session.surfaceId })
    reopenLauncherSessionForSession(session)
  }, [reopenLauncherSessionForSession])

  const handleTogglePinned = useCallback((session: Session) => {
    setSessionMenu(null)
    const pinned = togglePinned(session.id)
    setPinnedSessionIds(loadPinnedSet())
    onToast?.('success', pinned ? t('sessions.launcher.sessionPinned') : t('sessions.launcher.sessionUnpinned'))
  }, [onToast, t])

  const openSessionMenuAt = useCallback((session: Session, clientX: number, clientY: number) => {
    const viewportWidth = typeof window === 'undefined' ? 1024 : window.innerWidth
    const viewportHeight = typeof window === 'undefined' ? 768 : window.innerHeight
    setProjectMenuId(null)
    setSessionMenu({
      session,
      x: Math.max(8, Math.min(clientX, viewportWidth - SESSION_CONTEXT_MENU_WIDTH - 8)),
      y: Math.max(8, Math.min(clientY, viewportHeight - SESSION_CONTEXT_MENU_HEIGHT - 8)),
    })
  }, [])

  const handleOpenSessionMenu = useCallback((session: Session, event: ReactMouseEvent<HTMLElement>) => {
    event.preventDefault()
    event.stopPropagation()
    openSessionMenuAt(session, event.clientX, event.clientY)
  }, [openSessionMenuAt])

  const openRenameSession = useCallback((session: Session) => {
    setSessionMenu(null)
    setRenameSession(session)
    setRenameSessionValue(sessionDisplayTitle(session, titleOverrides))
  }, [titleOverrides])

  const handleRenameSession = useCallback((event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (!renameSession) return
    const title = renameSessionValue.trim()
    if (!title) {
      onToast?.('error', t('sessions.launcher.sessionNameRequired'))
      return
    }
    saveTitleOverride(renameSession.id, title)
    setTitleOverrides(loadTitleOverrides())
    setRenameSession(null)
    setRenameSessionValue('')
    onToast?.('success', t('sessions.launcher.sessionRenamed', { title }))
  }, [onToast, renameSession, renameSessionValue, t])

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
      onToast?.('success', t('sessions.archived'))
    } catch (err) {
      setLocallyArchivedSessionIds((current) => {
        const next = new Set(current)
        next.delete(session.id)
        return next
      })
      setSelection(previousSelection)
      onToast?.('error', (err as Error).message || t('sessions.launcher.archiveSessionFailed'))
    } finally {
      setArchivingSessionId(null)
      setArchiveSession(null)
    }
  }, [explicitProjects, onSessionCreated, onToast, selection, t])

  const handleSidebarResizeStart = useCallback((event: ReactPointerEvent<HTMLButtonElement>) => {
    event.preventDefault()
    pointerSidebarResizeActiveRef.current = true
    if (Number.isFinite(event.pointerId)) {
      event.currentTarget.setPointerCapture?.(event.pointerId)
    }
    setSidebarCollapsed(false)
    const startX = Number.isFinite(event.clientX) ? event.clientX : sidebarWidth
    const startWidth = sidebarWidth
    const onPointerMove = (moveEvent: PointerEvent) => {
      const nextX = Number.isFinite(moveEvent.clientX) ? moveEvent.clientX : startX
      setSidebarWidth(clampSidebarWidth(startWidth + nextX - startX))
    }
    const onPointerUp = () => {
      window.removeEventListener('pointermove', onPointerMove)
      window.removeEventListener('pointerup', onPointerUp)
      window.removeEventListener('pointercancel', onPointerUp)
      document.body.classList.remove('session-launcher-sidebar-resizing')
      pointerSidebarResizeActiveRef.current = false
    }
    document.body.classList.add('session-launcher-sidebar-resizing')
    window.addEventListener('pointermove', onPointerMove)
    window.addEventListener('pointerup', onPointerUp)
    window.addEventListener('pointercancel', onPointerUp)
  }, [sidebarWidth])

  const handleSidebarMouseResizeStart = useCallback((event: ReactMouseEvent<HTMLButtonElement>) => {
    if (pointerSidebarResizeActiveRef.current) return
    event.preventDefault()
    setSidebarCollapsed(false)
    const startX = Number.isFinite(event.clientX) ? event.clientX : sidebarWidth
    const startWidth = sidebarWidth
    const onMouseMove = (moveEvent: MouseEvent) => {
      const nextX = Number.isFinite(moveEvent.clientX) ? moveEvent.clientX : startX
      setSidebarWidth(clampSidebarWidth(startWidth + nextX - startX))
    }
    const onMouseUp = () => {
      window.removeEventListener('mousemove', onMouseMove)
      window.removeEventListener('mouseup', onMouseUp)
      document.body.classList.remove('session-launcher-sidebar-resizing')
    }
    document.body.classList.add('session-launcher-sidebar-resizing')
    window.addEventListener('mousemove', onMouseMove)
    window.addEventListener('mouseup', onMouseUp)
  }, [sidebarWidth])

  const handleSidebarResizeKeyDown = useCallback((event: ReactKeyboardEvent<HTMLButtonElement>) => {
    const step = event.shiftKey ? 64 : 24
    if (event.key === 'ArrowLeft') {
      event.preventDefault()
      setSidebarCollapsed(false)
      setSidebarWidth((current) => clampSidebarWidth(current - step))
    } else if (event.key === 'ArrowRight') {
      event.preventDefault()
      setSidebarCollapsed(false)
      setSidebarWidth((current) => clampSidebarWidth(current + step))
    } else if (event.key === 'Home') {
      event.preventDefault()
      setSidebarCollapsed(false)
      setSidebarWidth(MIN_SIDEBAR_WIDTH)
    } else if (event.key === 'End') {
      event.preventDefault()
      setSidebarCollapsed(false)
      setSidebarWidth(MAX_SIDEBAR_WIDTH)
    }
  }, [])

  const launcherStyle = {
    '--session-launcher-sidebar-width': `${sidebarWidth}px`,
  } as CSSProperties

  return (
    <>
    <section
      className={`session-launcher${sidebarCollapsed ? ' session-launcher--sidebar-collapsed' : ''}`}
      style={launcherStyle}
      aria-label={t('rail.session')}
    >
      <button
        type="button"
        className="session-launcher__sidebar-toggle"
        onClick={() => setSidebarCollapsed((current) => !current)}
        aria-label={sidebarCollapsed ? t('sessions.launcher.expandSidebar') : t('sessions.launcher.collapseSidebar')}
        title={sidebarCollapsed ? t('sessions.launcher.expandSidebar') : t('sessions.launcher.collapseSidebar')}
      >
        {sidebarCollapsed ? <PanelLeftOpen size={15} aria-hidden /> : <PanelLeftClose size={15} aria-hidden />}
      </button>
      <aside className="session-launcher__sidebar" aria-hidden={sidebarCollapsed}>
        <button
          type="button"
          className="session-launcher__sidebar-resize"
          aria-label={t('sessions.launcher.resizeSidebar')}
          title={t('sessions.launcher.resizeSidebar')}
          onPointerDown={handleSidebarResizeStart}
          onMouseDown={handleSidebarMouseResizeStart}
          onKeyDown={handleSidebarResizeKeyDown}
          tabIndex={sidebarCollapsed ? -1 : 0}
        />
        {projectsError && <div className="session-launcher__error">{projectsError}</div>}
        <div className="session-launcher__project-list">
          <SessionGroupHeader title={t('sessions.launcher.pinned')} />
          {grouped.pinned.length > 0 ? (
            <SessionList
              groupId="pinned"
              sessions={grouped.pinned}
              selection={selection}
              expandedSessionGroups={expandedSessionGroups}
              onToggleExpanded={setExpandedSessionGroups}
              onSelectSession={(session) => void handleSelectSession(session)}
              onTogglePinned={handleTogglePinned}
              onArchiveSession={setArchiveSession}
              onOpenSessionMenu={handleOpenSessionMenu}
              onOpenSessionMenuAt={openSessionMenuAt}
              titleOverrides={titleOverrides}
              pinnedSessionIds={pinnedSessionIds}
              archivingSessionId={archivingSessionId}
            />
          ) : (
            <div className="session-launcher__empty session-launcher__empty--compact">{t('sessions.launcher.noPinned')}</div>
          )}

          <SessionGroupHeader
            title={t('sessions.launcher.projects')}
            action={(
              <button
                type="button"
                className="session-launcher__group-action"
                onClick={handleAddFolder}
                disabled={addingFolder}
                aria-label={t('sessions.launcher.addFolder')}
                title={t('sessions.launcher.addFolder')}
              >
                {addingFolder ? <Loader2 size={14} className="spin" /> : <FolderPlus size={14} />}
              </button>
            )}
          />
          {projectsLoading ? (
            <div className="session-launcher__empty">{t('sessions.launcher.loadingProjects')}</div>
          ) : sortedProjects.length === 0 ? (
            <div className="session-launcher__empty">{t('sessions.launcher.addFolderToStart')}</div>
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
                  onForget={() => openForgetProject(project)}
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
                    onArchiveSession={setArchiveSession}
                    onOpenSessionMenu={handleOpenSessionMenu}
                    onOpenSessionMenuAt={openSessionMenuAt}
                    titleOverrides={titleOverrides}
                    pinnedSessionIds={pinnedSessionIds}
                    archivingSessionId={archivingSessionId}
                    nested
                  />
                )}
              </div>
            )
          })}

          <SessionGroupHeader
            title={t('sessions.launcher.temporary')}
            action={(
              <button
                type="button"
                className="session-launcher__group-action"
                onClick={() => setSelection({ kind: 'temporaryDraft' })}
                aria-label={t('sessions.launcher.newTemporarySession')}
                title={t('sessions.launcher.newTemporarySession')}
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
            onArchiveSession={setArchiveSession}
            onOpenSessionMenu={handleOpenSessionMenu}
            onOpenSessionMenuAt={openSessionMenuAt}
            titleOverrides={titleOverrides}
            pinnedSessionIds={pinnedSessionIds}
            archivingSessionId={archivingSessionId}
          />

          {grouped.external.length > 0 && (
            <>
              <SessionGroupHeader title={t('sessions.launcher.history')} />
              <SessionList
                groupId="external"
                sessions={grouped.external}
                selection={selection}
                expandedSessionGroups={expandedSessionGroups}
                onToggleExpanded={setExpandedSessionGroups}
                onSelectSession={(session) => void handleSelectSession(session)}
                onTogglePinned={handleTogglePinned}
                onArchiveSession={setArchiveSession}
                onOpenSessionMenu={handleOpenSessionMenu}
                onOpenSessionMenuAt={openSessionMenuAt}
                titleOverrides={titleOverrides}
                pinnedSessionIds={pinnedSessionIds}
                archivingSessionId={archivingSessionId}
              />
            </>
          )}
        </div>
      </aside>
      <main className="session-launcher__main">
        {selection?.kind === 'session' ? (
          <SessionLauncherTerminal
            session={selectedSession}
            statusSession={selectedRestoredSession}
            sessionId={selectedRestoredTarget?.sessionId ?? selectedLiveTarget.sessionId ?? selection.sessionId}
            surfaceId={selectedRestoredTarget?.surfaceId ?? selectedLiveTarget.surfaceId ?? selection.surfaceId ?? null}
            usingRestoredSurface={Boolean(selectedRestoredTarget)}
            reopening={reopeningSessionId === selection.sessionId && !selectedRestoredTarget}
            titleOverrides={titleOverrides}
            theme={resolvedTheme}
            onOpenSessionArtifacts={onOpenSessionArtifacts}
          />
        ) : selection?.kind === 'temporaryDraft' ? (
          <SessionComposer
            title={t('sessions.launcher.temporaryPromptTitle')}
            prompt={temporaryPrompt}
            provider={temporaryProvider}
            permissionMode={temporaryPermissionMode}
            planMode={temporaryPlanMode}
            attachments={temporaryAttachments}
            starting={startingTemporary}
            onPromptChange={setTemporaryPrompt}
            onProviderChange={(provider) => {
              setTemporaryProvider(provider)
              setTemporaryPermissionMode((current) => normalizePermissionMode(provider, current))
            }}
            onPermissionModeChange={(permissionMode) => setTemporaryPermissionMode(normalizePermissionMode(temporaryProvider, permissionMode))}
            onPlanModeChange={setTemporaryPlanMode}
            onPickAttachments={handlePickTemporaryAttachments}
            onUploadPastedImage={handleUploadTemporaryAttachment}
            onRemoveAttachment={(path) => setTemporaryAttachments((current) => removeLaunchAttachment(current, path))}
            onStart={() => void handleStartTemporarySession()}
          />
        ) : selectedProject ? (
          <SessionComposer
            title={t('sessions.launcher.projectPromptTitle', { project: selectedProject.name })}
            prompt={currentProjectPrompt}
            provider={selectedProjectProvider}
            permissionMode={selectedProjectPermissionMode}
            planMode={selectedProjectPlanMode}
            attachments={currentProjectAttachments}
            starting={startingProjectId === selectedProject.id}
            onPromptChange={(value) => setPromptByProjectId((current) => ({
              ...current,
              [selectedProject.id]: value,
            }))}
            onProviderChange={(provider) => {
              setProviderByProjectId((current) => ({ ...current, [selectedProject.id]: provider }))
              setPermissionModeByProjectId((current) => ({
                ...current,
                [selectedProject.id]: normalizePermissionMode(provider, current[selectedProject.id]),
              }))
            }}
            onPermissionModeChange={(permissionMode) => setPermissionModeByProjectId((current) => ({
              ...current,
              [selectedProject.id]: normalizePermissionMode(selectedProjectProvider, permissionMode),
            }))}
            onPlanModeChange={(planMode) => setPlanModeByProjectId((current) => ({
              ...current,
              [selectedProject.id]: planMode,
            }))}
            onPickAttachments={() => handlePickProjectAttachments(selectedProject.id)}
            onUploadPastedImage={(file) => handleUploadProjectAttachment(selectedProject.id, file)}
            onRemoveAttachment={(path) => setAttachmentsByProjectId((current) => ({
              ...current,
              [selectedProject.id]: removeLaunchAttachment(current[selectedProject.id] ?? [], path),
            }))}
            onStart={() => void handleStartProjectSession()}
          />
        ) : (
          <div className="session-launcher__empty-main">
            <button type="button" onClick={handleAddFolder} disabled={addingFolder}>
              {addingFolder ? <Loader2 size={16} className="spin" /> : <FolderPlus size={16} />}
              <span>{t('sessions.launcher.addFolder')}</span>
            </button>
          </div>
        )}
      </main>
    </section>
    {sessionMenu && typeof document !== 'undefined' && createPortal(
      <SessionContextMenuView
        title={sessionDisplayTitle(sessionMenu.session, titleOverrides)}
        pinned={pinnedSessionIds.has(sessionMenu.session.id)}
        x={sessionMenu.x}
        y={sessionMenu.y}
        onTogglePinned={() => handleTogglePinned(sessionMenu.session)}
        onRename={() => openRenameSession(sessionMenu.session)}
        onArchive={() => {
          setSessionMenu(null)
          setArchiveSession(sessionMenu.session)
        }}
        onOpenArtifacts={() => {
          const title = sessionDisplayTitle(sessionMenu.session, titleOverrides)
          setSessionMenu(null)
          onOpenSessionArtifacts?.(sessionMenu.session, title, sessionArtifactFilter(sessionMenu.session, title))
        }}
      />,
      document.body,
    )}
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
    {renameSession && (
      <RenameSessionModal
        session={renameSession}
        title={sessionDisplayTitle(renameSession, titleOverrides)}
        value={renameSessionValue}
        onValueChange={setRenameSessionValue}
        onCancel={() => {
          setRenameSession(null)
          setRenameSessionValue('')
        }}
        onSubmit={(event) => handleRenameSession(event)}
      />
    )}
    {forgetProject && (
      <ConfirmSessionLauncherModal
        title={t('sessions.launcher.forgetProjectTitle')}
        detail={t('sessions.launcher.forgetProjectDetail', { name: forgetProject.name })}
        confirmLabel={t('sessions.launcher.forgetProject')}
        busy={forgettingProjectId === forgetProject.id}
        danger
        onCancel={() => setForgetProject(null)}
        onConfirm={() => void handleForgetProject(forgetProject)}
      />
    )}
    {archiveSession && (
      <ConfirmSessionLauncherModal
        title={t('sessions.launcher.archiveSessionTitle')}
        detail={t('sessions.launcher.archiveSessionDetail', { title: sessionDisplayTitle(archiveSession, titleOverrides) })}
        confirmLabel={t('sessions.launcher.archiveSession')}
        busy={archivingSessionId === archiveSession.id}
        onCancel={() => setArchiveSession(null)}
        onConfirm={() => void handleArchiveSession(archiveSession)}
      />
    )}
    </>
  )
}

function SessionContextMenuView({
  title,
  pinned,
  x,
  y,
  onTogglePinned,
  onRename,
  onArchive,
  onOpenArtifacts,
}: {
  title: string
  pinned: boolean
  x: number
  y: number
  onTogglePinned: () => void
  onRename: () => void
  onArchive: () => void
  onOpenArtifacts: () => void
}) {
  const { t } = useI18n()
  return (
    <div
      className="session-launcher__context-menu"
      role="menu"
      aria-label={t('sessions.launcher.sessionMenu', { title })}
      style={{ left: x, top: y }}
      onPointerDown={(event) => event.stopPropagation()}
      onContextMenu={(event) => event.preventDefault()}
    >
      <button type="button" role="menuitem" onClick={onArchive}>
        <Archive size={13} aria-hidden />
        <span>{t('sessions.launcher.archiveSession')}</span>
      </button>
      <button type="button" role="menuitem" onClick={onOpenArtifacts}>
        <FileText size={13} aria-hidden />
        <span>{t('sessions.launcher.openArtifacts')}</span>
      </button>
      <button type="button" role="menuitem" onClick={onTogglePinned}>
        {pinned ? <PinOff size={13} aria-hidden /> : <Pin size={13} aria-hidden />}
        <span>{pinned ? t('sessions.launcher.unpin') : t('sessions.launcher.pin')}</span>
      </button>
      <button type="button" role="menuitem" onClick={onRename}>
        <Edit3 size={13} aria-hidden />
        <span>{t('sessions.launcher.rename')}</span>
      </button>
    </div>
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
  const { t } = useI18n()
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
        </span>
      </button>
      <div className="session-launcher__project-actions" data-session-project-menu-root>
        <button
          type="button"
          onClick={onToggleExpanded}
          aria-label={expanded ? t('sessions.launcher.collapseProject', { name: project.name }) : t('sessions.launcher.expandProject', { name: project.name })}
          title={expanded ? t('sessions.launcher.collapse') : t('sessions.launcher.expand')}
        >
          <ChevronDown size={14} className={expanded ? 'is-open' : ''} />
        </button>
        <div className="session-launcher__project-menu-wrap">
          <button
            type="button"
            onClick={onToggleMenu}
            aria-haspopup="menu"
            aria-expanded={menuOpen}
            aria-label={t('sessions.launcher.moreActionsFor', { name: project.name })}
            title={t('sessions.launcher.moreActions')}
          >
            <MoreHorizontal size={15} />
          </button>
          {menuOpen && (
            <div className="session-launcher__project-menu" role="menu">
              <button type="button" role="menuitem" onClick={onRename}>
                <Edit3 size={13} aria-hidden />
                <span>{t('sessions.launcher.rename')}</span>
              </button>
              <button type="button" role="menuitem" onClick={onReveal} disabled={revealing}>
                {revealing ? <Loader2 size={13} className="spin" aria-hidden /> : <FolderOpen size={13} aria-hidden />}
                <span>{t('sessions.launcher.revealInFinder')}</span>
              </button>
              <button type="button" role="menuitem" className="is-danger" onClick={onForget}>
                <Trash2 size={13} aria-hidden />
                <span>{t('sessions.launcher.forgetProjectKeepsFiles')}</span>
              </button>
            </div>
          )}
        </div>
        <button
          type="button"
          onClick={onCompose}
          aria-label={t('sessions.launcher.composeInProject', { name: project.name })}
          title={t('sessions.launcher.newSession')}
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
  const { t } = useI18n()
  const trimmed = value.trim()
  return (
    <div className="session-launcher-modal" role="presentation" onMouseDown={(event) => {
      if (event.target === event.currentTarget) onCancel()
    }}>
      <form className="session-launcher-modal__dialog" role="dialog" aria-modal="true" aria-label={t('sessions.launcher.renameProjectNamed', { name: project.name })} onSubmit={onSubmit}>
        <header>
          <strong>{t('sessions.launcher.renameProject')}</strong>
          <span>{project.path}</span>
        </header>
        <label>
          <span>{t('sessions.launcher.displayName')}</span>
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
          <button type="button" className="ghost" onClick={onCancel} disabled={busy}>{t('common.cancel')}</button>
          <button type="submit" disabled={busy || trimmed.length === 0}>
            {busy ? <Loader2 size={14} className="spin" /> : null}
            <span>{t('sessions.launcher.rename')}</span>
          </button>
        </footer>
      </form>
    </div>
  )
}

function RenameSessionModal({
  session,
  title,
  value,
  onValueChange,
  onCancel,
  onSubmit,
}: {
  session: Session
  title: string
  value: string
  onValueChange: (value: string) => void
  onCancel: () => void
  onSubmit: (event: FormEvent<HTMLFormElement>) => void
}) {
  const { t } = useI18n()
  const trimmed = value.trim()
  return (
    <div className="session-launcher-modal" role="presentation" onMouseDown={(event) => {
      if (event.target === event.currentTarget) onCancel()
    }}>
      <form className="session-launcher-modal__dialog" role="dialog" aria-modal="true" aria-label={t('sessions.launcher.renameSessionNamed', { title })} onSubmit={onSubmit}>
        <header>
          <strong>{t('sessions.launcher.renameSession')}</strong>
          <span>{session.project || session.pluginDisplayName}</span>
        </header>
        <label>
          <span>{t('sessions.launcher.displayName')}</span>
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
          <button type="button" className="ghost" onClick={onCancel}>{t('common.cancel')}</button>
          <button type="submit" disabled={trimmed.length === 0}>
            <span>{t('sessions.launcher.rename')}</span>
          </button>
        </footer>
      </form>
    </div>
  )
}

function ConfirmSessionLauncherModal({
  title,
  detail,
  confirmLabel,
  busy,
  danger = false,
  onCancel,
  onConfirm,
}: {
  title: string
  detail: string
  confirmLabel: string
  busy: boolean
  danger?: boolean
  onCancel: () => void
  onConfirm: () => void
}) {
  const { t } = useI18n()
  return (
    <div className="session-launcher-modal" role="presentation" onMouseDown={(event) => {
      if (event.target === event.currentTarget && !busy) onCancel()
    }}>
      <div
        className="session-launcher-modal__dialog session-launcher-modal__dialog--confirm"
        role="dialog"
        aria-modal="true"
        aria-label={title}
      >
        <header>
          <strong>{title}</strong>
          <span>{detail}</span>
        </header>
        <footer>
          <button type="button" className="ghost" onClick={onCancel} disabled={busy}>{t('common.cancel')}</button>
          <button
            type="button"
            className={danger ? 'danger' : undefined}
            onClick={onConfirm}
            disabled={busy}
          >
            {busy ? <Loader2 size={14} className="spin" /> : null}
            <span>{confirmLabel}</span>
          </button>
        </footer>
      </div>
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
  onOpenSessionMenu,
  onOpenSessionMenuAt,
  titleOverrides,
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
  onOpenSessionMenu: (session: Session, event: ReactMouseEvent<HTMLElement>) => void
  onOpenSessionMenuAt: (session: Session, clientX: number, clientY: number) => void
  titleOverrides: Record<string, string>
  pinnedSessionIds: Set<string>
  archivingSessionId: string | null
  nested?: boolean
}) {
  const { t } = useI18n()
  const expanded = expandedSessionGroups.has(groupId)
  const visible = expanded ? sessions : sessions.slice(0, DEFAULT_VISIBLE_SESSIONS)
  if (sessions.length === 0) {
    return <div className="session-launcher__empty session-launcher__empty--compact">{t('sessions.launcher.noSessions')}</div>
  }
  return (
    <div className={`session-launcher__session-list${nested ? ' session-launcher__session-list--nested' : ''}`}>
      {visible.map((session) => {
        const active = selection?.kind === 'session' && session.id === selection.sessionId
        return (
          <SessionRow
            key={session.id}
            session={session}
            active={active}
            pinned={pinnedSessionIds.has(session.id)}
            archiving={archivingSessionId === session.id}
            title={sessionDisplayTitle(session, titleOverrides)}
            onSelect={() => onSelectSession(session)}
            onTogglePinned={() => onTogglePinned(session)}
            onArchive={() => onArchiveSession(session)}
            onContextMenu={(event) => onOpenSessionMenu(session, event)}
            onOpenMenuAt={(clientX, clientY) => onOpenSessionMenuAt(session, clientX, clientY)}
          />
        )
      })}
      {sessions.length > DEFAULT_VISIBLE_SESSIONS && (
        <button
          type="button"
          className="session-launcher__show-more"
          onClick={() => onToggleExpanded((current) => toggleSet(current, groupId))}
        >
          {expanded ? t('sessions.launcher.showLess') : t('sessions.launcher.showMore')}
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
  title,
  onSelect,
  onTogglePinned,
  onArchive,
  onContextMenu,
  onOpenMenuAt,
}: {
  session: Session
  active: boolean
  pinned: boolean
  archiving: boolean
  title: string
  onSelect: () => void
  onTogglePinned: () => void
  onArchive: () => void
  onContextMenu: (event: ReactMouseEvent<HTMLElement>) => void
  onOpenMenuAt: (clientX: number, clientY: number) => void
}) {
  const { t } = useI18n()
  const age = compactSessionAge(session)
  const state = sessionRowState(session, t)
  const tooltip = sessionRowTooltip(session, title, state?.label, age)
  const handleMouseDown = (event: ReactMouseEvent<HTMLElement>) => {
    if (event.button === 2) onContextMenu(event)
  }
  const handleKeyDown = (event: ReactKeyboardEvent<HTMLElement>) => {
    if (event.key !== 'ContextMenu' && !(event.shiftKey && event.key === 'F10')) return
    event.preventDefault()
    event.stopPropagation()
    const rect = event.currentTarget.getBoundingClientRect()
    onOpenMenuAt(rect.left + 14, rect.top + 14)
  }
  return (
    <div className={[
      'session-launcher__session-item',
      active ? 'is-selected' : '',
      state?.tone === 'attention' ? 'session-launcher__session-item--attention' : '',
      state?.tone === 'done' ? 'session-launcher__session-item--done' : '',
    ].filter(Boolean).join(' ')}
      onContextMenu={onContextMenu}
      onMouseDown={handleMouseDown}
      onKeyDown={handleKeyDown}
    >
      <button
        type="button"
        className="session-launcher__session-row"
        onClick={onSelect}
        onContextMenu={onContextMenu}
        onMouseDown={handleMouseDown}
        onKeyDown={handleKeyDown}
        aria-label={state ? `${title} · ${state.label}` : title}
        title={tooltip}
      >
        <span>
          <strong>{title}</strong>
          {state && (
            <em className={`session-launcher__session-state is-${state.tone}`}>
              {state.tone === 'done' ? <CheckCircle2 size={11} aria-hidden /> : <AlertCircle size={11} aria-hidden />}
              {state.label}
            </em>
          )}
        </span>
        {age && <time aria-hidden dateTime={session.lastActivity ?? session.startedAt ?? undefined}>{age}</time>}
      </button>
      <div className="session-launcher__session-actions">
        <button
          type="button"
          className="session-launcher__pin-button"
          onClick={onTogglePinned}
          aria-label={pinned ? t('sessions.launcher.unpinSessionNamed', { title }) : t('sessions.launcher.pinSessionNamed', { title })}
          title={pinned ? t('sessions.launcher.unpin') : t('sessions.launcher.pin')}
        >
          {pinned ? <PinOff size={13} /> : <Pin size={13} />}
        </button>
        <button
          type="button"
          className="session-launcher__archive-button"
          onClick={onArchive}
          disabled={archiving}
          aria-label={t('sessions.launcher.archiveSessionNamed', { title })}
          title={t('sessions.archive')}
        >
          {archiving ? <Loader2 size={13} className="spin" /> : <Archive size={13} />}
        </button>
      </div>
    </div>
  )
}

function sessionRowState(session: Session, t: ReturnType<typeof useI18n>['t']): { tone: 'attention' | 'done'; label: string } | null {
  if (sessionNeedsAttention(session)) return { tone: 'attention', label: sessionAttentionLabel(session, t) }
  if (session.status === 'completed' || session.status === 'done') return { tone: 'done', label: t('common.done') }
  return null
}

function sessionNeedsAttention(session: Session): boolean {
  return session.status === 'permissionRequired'
    || session.status === 'waitingForUser'
    || session.inboxPending > 0
    || Boolean(session.pendingPermissionTool || session.pendingPermissionMessage)
}

function sessionAttentionLabel(session: Session, t: ReturnType<typeof useI18n>['t']): string {
  if (session.pendingPermissionTool || session.status === 'permissionRequired') return t('sessions.permissionRequired')
  if (session.inboxPending > 0) return t('sessions.pendingMessages', { count: session.inboxPending })
  return t('sessions.waitingUser')
}

function sessionRowTooltip(session: Session, title: string, stateLabel: string | undefined, age: string): string {
  return [
    title,
    sessionRuntimeLabel(session),
    session.project?.trim(),
    stateLabel || session.status,
    age,
  ]
    .map((item) => item?.trim())
    .filter((item): item is string => Boolean(item))
    .join('\n')
}

function SessionComposer({
  title,
  prompt,
  provider,
  permissionMode,
  planMode,
  attachments,
  starting,
  onPromptChange,
  onProviderChange,
  onPermissionModeChange,
  onPlanModeChange,
  onPickAttachments,
  onUploadPastedImage,
  onRemoveAttachment,
  onStart,
}: {
  title: string
  prompt: string
  provider: SpawnProvider
  permissionMode: AgentPermissionMode
  planMode: boolean
  attachments: SessionLaunchAttachment[]
  starting: boolean
  onPromptChange: (value: string) => void
  onProviderChange: (provider: SpawnProvider) => void
  onPermissionModeChange: (permissionMode: AgentPermissionMode) => void
  onPlanModeChange: (planMode: boolean) => void
  onPickAttachments: () => Promise<void>
  onUploadPastedImage: (file: File) => Promise<void>
  onRemoveAttachment: (path: string) => void
  onStart: () => void
}) {
  const { t } = useI18n()
  const [permissionOpen, setPermissionOpen] = useState(false)
  const [enterSubmitArmed, setEnterSubmitArmed] = useState(false)
  const [attachmentBusy, setAttachmentBusy] = useState(false)
  const [attachmentError, setAttachmentError] = useState<string | null>(null)
  const permissionMenuRef = useRef<HTMLDivElement | null>(null)
  const enterSubmitTimerRef = useRef<number | null>(null)
  const permissionOptions = PERMISSION_OPTIONS[provider]
  const normalizedPermissionMode = normalizePermissionMode(provider, permissionMode)
  const selectedPermissionOption = permissionOptions.find((option) => option.value === normalizedPermissionMode) ?? permissionOptions[0]
  const selectedPermissionLabel = selectedPermissionOption ? t(selectedPermissionOption.labelKey) : ''

  const clearEnterSubmitArm = useCallback(() => {
    if (enterSubmitTimerRef.current !== null) {
      window.clearTimeout(enterSubmitTimerRef.current)
      enterSubmitTimerRef.current = null
    }
    setEnterSubmitArmed(false)
  }, [])

  const armEnterSubmit = useCallback(() => {
    if (enterSubmitTimerRef.current !== null) {
      window.clearTimeout(enterSubmitTimerRef.current)
    }
    setEnterSubmitArmed(true)
    enterSubmitTimerRef.current = window.setTimeout(() => {
      enterSubmitTimerRef.current = null
      setEnterSubmitArmed(false)
    }, ENTER_SUBMIT_ARM_MS)
  }, [])

  const startSession = useCallback(() => {
    clearEnterSubmitArm()
    onStart()
  }, [clearEnterSubmitArm, onStart])

  const handlePromptChange = useCallback((value: string) => {
    clearEnterSubmitArm()
    onPromptChange(value)
  }, [clearEnterSubmitArm, onPromptChange])

  const pickAttachments = useCallback(async () => {
    if (starting || attachmentBusy) return
    clearEnterSubmitArm()
    setAttachmentBusy(true)
    setAttachmentError(null)
    try {
      await onPickAttachments()
    } catch (err) {
      setAttachmentError((err as Error).message || t('sessions.launcher.attachmentFailed'))
    } finally {
      setAttachmentBusy(false)
    }
  }, [attachmentBusy, clearEnterSubmitArm, onPickAttachments, starting, t])

  const handlePromptPaste = useCallback(async (event: ReactClipboardEvent<HTMLTextAreaElement>) => {
    const items = event.clipboardData?.items
    if (!items?.length) return
    const files: File[] = []
    for (let index = 0; index < items.length; index += 1) {
      const item = items[index]
      if (item.kind === 'file' && item.type.startsWith('image/')) {
        const file = item.getAsFile()
        if (file) files.push(file)
      }
    }
    if (files.length === 0) return
    event.preventDefault()
    clearEnterSubmitArm()
    setAttachmentBusy(true)
    setAttachmentError(null)
    try {
      for (const file of files) {
        await onUploadPastedImage(file)
      }
    } catch (err) {
      setAttachmentError((err as Error).message || t('sessions.launcher.attachmentFailed'))
    } finally {
      setAttachmentBusy(false)
    }
  }, [clearEnterSubmitArm, onUploadPastedImage, t])

  const handlePromptKeyDown = useCallback((event: ReactKeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key !== 'Enter' || event.nativeEvent.isComposing) return
    if (event.shiftKey || event.altKey) return
    event.preventDefault()
    if (starting) return
    if (event.metaKey || event.ctrlKey || enterSubmitArmed) {
      startSession()
      return
    }
    armEnterSubmit()
  }, [armEnterSubmit, enterSubmitArmed, startSession, starting])

  useEffect(() => {
    if (!permissionOpen) return undefined
    const closeMenu = (event: PointerEvent) => {
      if (event.target instanceof Element && permissionMenuRef.current?.contains(event.target)) return
      setPermissionOpen(false)
    }
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setPermissionOpen(false)
    }
    document.addEventListener('pointerdown', closeMenu)
    document.addEventListener('keydown', closeOnEscape)
    return () => {
      document.removeEventListener('pointerdown', closeMenu)
      document.removeEventListener('keydown', closeOnEscape)
    }
  }, [permissionOpen])

  useEffect(() => () => {
    if (enterSubmitTimerRef.current !== null) {
      window.clearTimeout(enterSubmitTimerRef.current)
    }
  }, [])

  return (
    <div className="session-launcher__composer-shell">
      <div className="session-launcher__composer">
        <h2>{title}</h2>
        <div className="session-launcher__prompt-tray">
          <div className="session-launcher__prompt-card">
            {attachments.length > 0 && (
              <div className="session-launcher__attachments" aria-label={t('sessions.launcher.attachments')}>
                {attachments.map((attachment) => (
                  <span key={attachment.path} className="session-launcher__attachment-chip" title={attachment.path}>
                    <FileText size={13} aria-hidden />
                    <span>{truncateAttachmentName(attachment.filename || attachment.path)}</span>
                    <button
                      type="button"
                      onClick={() => onRemoveAttachment(attachment.path)}
                      disabled={starting}
                      aria-label={t('sessions.launcher.removeAttachment', { name: attachment.filename || attachment.path })}
                      title={t('sessions.launcher.removeAttachment', { name: attachment.filename || attachment.path })}
                    >
                      <X size={12} aria-hidden />
                    </button>
                  </span>
                ))}
              </div>
            )}
            <textarea
              value={prompt}
              onChange={(event) => handlePromptChange(event.target.value)}
              onKeyDown={handlePromptKeyDown}
              onPaste={(event) => void handlePromptPaste(event)}
              placeholder={t('sessions.launcher.promptPlaceholder')}
              rows={4}
            />
            {attachmentError && (
              <div className="session-launcher__attachment-error" role="alert">{attachmentError}</div>
            )}
            <div className="session-launcher__composer-footer">
              <div className="session-launcher__composer-left">
                <button
                  type="button"
                  className="session-launcher__attach-button"
                  onClick={() => void pickAttachments()}
                  disabled={starting || attachmentBusy}
                  aria-label={t('sessions.launcher.attachFiles')}
                  title={t('sessions.launcher.attachFiles')}
                >
                  {attachmentBusy ? <Loader2 size={14} className="spin" aria-hidden /> : <Paperclip size={14} aria-hidden />}
                </button>
                <div className="session-launcher__access-mode" ref={permissionMenuRef}>
                  <button
                    type="button"
                    className="session-launcher__access-mode-trigger"
                    aria-label={t('sessions.launcher.permissionMode')}
                    aria-haspopup="listbox"
                    aria-expanded={permissionOpen}
                    title={selectedPermissionOption?.command}
                    onClick={() => setPermissionOpen((current) => !current)}
                  >
                    <span className="session-launcher__access-mode-label">{selectedPermissionLabel}</span>
                    <ChevronDown size={14} aria-hidden />
                  </button>
                  {permissionOpen && (
                    <div className="session-launcher__access-menu" role="listbox" aria-label={t('sessions.launcher.permissionMode')}>
                      {permissionOptions.map((option) => (
                        <button
                          key={option.value}
                          type="button"
                          role="option"
                          aria-selected={option.value === normalizedPermissionMode}
                          title={option.command}
                          onClick={() => {
                            onPermissionModeChange(option.value)
                            setPermissionOpen(false)
                          }}
                        >
                          <span>{t(option.labelKey)}</span>
                          <code>{option.command}</code>
                        </button>
                      ))}
                    </div>
                  )}
                </div>
                <button
                  type="button"
                  className={`session-launcher__plan-mode${planMode ? ' is-on' : ''}`}
                  role="switch"
                  aria-checked={planMode}
                  onClick={() => onPlanModeChange(!planMode)}
                  title={t('sessions.launcher.planModeHint', { runtime: spawnProviderLabel(provider) })}
                >
                  <span>{t('sessions.launcher.planMode')}</span>
                  <i aria-hidden />
                </button>
              </div>
              <div className="session-launcher__composer-right">
                <div className="session-launcher__runtime" role="group" aria-label={t('sessions.launcher.runtime')}>
                  {PROVIDERS.map((item) => (
                    <button
                      key={item}
                      type="button"
                      className={provider === item ? 'is-selected' : ''}
                      aria-pressed={provider === item}
                      onClick={() => onProviderChange(item)}
                      title={t('sessions.launcher.useRuntime', { runtime: spawnProviderLabel(item) })}
                    >
                      <span>{spawnProviderLabel(item)}</span>
                    </button>
                  ))}
                </div>
                <div className="session-launcher__start-wrap">
                  {enterSubmitArmed && (
                    <div
                      id="session-launcher-enter-submit-hint"
                      className="session-launcher__enter-submit-hint"
                      role="status"
                    >
                      {t('sessions.launcher.enterSubmitHint')}
                    </div>
                  )}
                  <button
                    type="button"
                    className={`session-launcher__start${enterSubmitArmed ? ' is-armed' : ''}`}
                    onClick={startSession}
                    disabled={starting}
                    aria-label={t('sessions.launcher.startSession')}
                    aria-describedby={enterSubmitArmed ? 'session-launcher-enter-submit-hint' : undefined}
                    title={t('sessions.launcher.startSession')}
                  >
                    {starting ? <Loader2 size={18} className="spin" /> : <ArrowUp size={20} />}
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}

function SessionLauncherTerminal({
  session,
  statusSession,
  sessionId,
  surfaceId,
  usingRestoredSurface,
  reopening,
  titleOverrides,
  theme,
  onOpenSessionArtifacts,
}: {
  session: Session | null
  statusSession?: Session | null
  sessionId: string
  surfaceId?: string | null
  usingRestoredSurface?: boolean
  reopening: boolean
  titleOverrides: Record<string, string>
  theme: 'light' | 'dark'
  onOpenSessionArtifacts?: (session: Session, title: string, filter: SessionArtifactFilterPayload) => void
}) {
  const { t } = useI18n()
  const hostRef = useRef<HTMLDivElement | null>(null)
  const layoutFrameRef = useRef<number | null>(null)
  const lastRectRef = useRef<NativeTerminalRect | null>(null)
  const switchTraceIdRef = useRef<string>('')
  const switchStartedAtRef = useRef<number>(Date.now())
  const liveTarget = nativeTerminalTargetForSession(session)
  const suppliedSurfaceId = surfaceId?.trim() || undefined
  const targetSurfaceId = liveTarget.surfaceId ?? suppliedSurfaceId
  const targetSessionId = liveTarget.sessionId ?? (targetSurfaceId ? sessionId : undefined)
  const canOpenNativeTerminal = Boolean(targetSurfaceId && targetSessionId)
  const targetKey = `${targetSessionId ?? 'missing'}:${targetSurfaceId ?? 'missing'}`

  useLayoutEffect(() => {
    const startedAt = Date.now()
    const targetPrefix = (targetSurfaceId || targetSessionId || 'missing').slice(0, 8)
    switchStartedAtRef.current = startedAt
    switchTraceIdRef.current = `launcher-${targetPrefix}-${startedAt.toString(36)}`
    lastRectRef.current = null
  }, [canOpenNativeTerminal, targetKey, targetSessionId, targetSurfaceId])

  const syncTerminal = useCallback((phase: 'show' | 'layout' | 'focus' = 'layout', force = false) => {
    const traceId = switchTraceIdRef.current
    const clickStartedAtMs = switchStartedAtRef.current
    const host = hostRef.current
    if (!host || !canOpenNativeTerminal) {
      syncNativeSessionsWorkspace({
        phase: 'hide',
        mode: 'terminal',
        theme,
        traceId,
        clickStartedAtMs,
        sentAtMs: Date.now(),
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
      theme,
      rect: nextRect,
      traceId,
      clickStartedAtMs,
      sentAtMs: Date.now(),
      webPhase: `sessionLauncher.${phase}`,
    })
  }, [canOpenNativeTerminal, targetSessionId, targetSurfaceId, theme])

  const scheduleLayout = useCallback(() => {
    if (layoutFrameRef.current !== null) return
    layoutFrameRef.current = window.requestAnimationFrame(() => {
      layoutFrameRef.current = null
      syncTerminal('layout')
    })
  }, [syncTerminal])

  useLayoutEffect(() => {
    syncTerminal('show', true)
    scheduleLayout()
    const host = hostRef.current
    if (!host) return undefined
    const resizeObserver = new ResizeObserver(() => scheduleLayout())
    resizeObserver.observe(host)
    const handleWindowLayout = () => scheduleLayout()
    window.addEventListener('resize', handleWindowLayout)
    window.addEventListener('meee2:layout-native-sessions-workspace', handleWindowLayout)
    return () => {
      if (layoutFrameRef.current !== null) window.cancelAnimationFrame(layoutFrameRef.current)
      resizeObserver.disconnect()
      window.removeEventListener('resize', handleWindowLayout)
      window.removeEventListener('meee2:layout-native-sessions-workspace', handleWindowLayout)
      lastRectRef.current = null
    }
  }, [scheduleLayout, syncTerminal, targetSessionId, targetSurfaceId])

  useEffect(() => {
    return () => {
      syncNativeSessionsWorkspace({
        phase: 'hide',
        mode: 'terminal',
        theme,
        traceId: switchTraceIdRef.current,
        clickStartedAtMs: switchStartedAtRef.current,
        sentAtMs: Date.now(),
        webPhase: 'sessionLauncher.hide.unmount',
      })
    }
  }, [theme])

  if (!canOpenNativeTerminal) {
    const fallbackMessage = sessionLauncherTerminalFallbackMessage(session, reopening, t)
    return (
      <div className="session-launcher__terminal-empty">
        <strong>{session ? sessionDisplayTitle(session, titleOverrides) : t('rail.session')}</strong>
        {reopening ? <Loader2 size={16} className="spin" aria-hidden /> : null}
        <span>{fallbackMessage}</span>
      </div>
    )
  }

  const title = session ? sessionDisplayTitle(session, titleOverrides) : t('sessions.launcher.startingSession')
  const runtime = sessionRuntimeLabel(session)
  const project = sessionProjectLabel(session)
  const fallbackRunningSession = usingRestoredSurface && session
    ? { ...session, status: 'running', surfaceStatus: 'running' }
    : session
  const status = sessionTerminalStatus(statusSession ?? fallbackRunningSession, t)
  const canOpenArtifacts = Boolean(session && onOpenSessionArtifacts)

  return (
    <div className="session-launcher-terminal">
      <header className="session-launcher-terminal__header">
        <div className="session-launcher-terminal__identity">
          <strong>{title}</strong>
          <span title={session?.project || undefined}>
            {runtime ? <b>{runtime}</b> : null}
            {runtime && project ? <i aria-hidden>·</i> : null}
            {project || t('sessions.launcher.waitingForTerminalSurface')}
          </span>
        </div>
        <div className="session-launcher-terminal__actions">
          <em className={`session-launcher-terminal__status is-${status.tone}`}>{status.label}</em>
          {canOpenArtifacts && session && (
            <button
              type="button"
              className="session-launcher-terminal__artifact-button"
              onClick={() => onOpenSessionArtifacts?.(session, title, sessionArtifactFilter(session, title))}
              aria-label={t('sessions.launcher.openArtifactsForSession', { title })}
              title={t('sessions.launcher.openArtifacts')}
            >
              <FileText size={13} aria-hidden />
            </button>
          )}
        </div>
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

function addToSet(values: Set<string>, value: string): Set<string> {
  if (values.has(value)) return values
  return new Set([...values, value])
}

function sessionMatchesSelection(session: Session, selection: Extract<Selection, { kind: 'session' }>): boolean {
  if (session.id === selection.sessionId) return true
  return Boolean(selection.surfaceId && session.surfaceId && selection.surfaceId === session.surfaceId)
}

function selectedSessionForSelection(
  sessions: readonly Session[],
  selection: Extract<Selection, { kind: 'session' }>,
): Session | null {
  return sessions.find((session) => session.id === selection.sessionId)
    ?? sessions.find((session) => sessionMatchesSelection(session, selection))
    ?? null
}

function collapseRestoredLauncherSessions(
  sessions: Session[],
  selection: Selection | null,
  restoredTargets: Record<string, RestoredTerminalTarget>,
): Session[] {
  const hiddenSessionIds = new Set<string>()
  const hiddenSurfaceIds = new Set<string>()

  const addRestoredTarget = (sourceSessionId: string | undefined, target: RestoredTerminalTarget | null | undefined) => {
    if (!sourceSessionId || !target) return
    if (target.sessionId && target.sessionId !== sourceSessionId) hiddenSessionIds.add(target.sessionId)
    if (target.surfaceId) hiddenSurfaceIds.add(target.surfaceId)
  }

  for (const [sourceSessionId, target] of Object.entries(restoredTargets)) {
    addRestoredTarget(sourceSessionId, target)
  }
  if (selection?.kind === 'session') {
    addRestoredTarget(selection.sessionId, selection.surfaceId
      ? { sessionId: '', surfaceId: selection.surfaceId }
      : restoredTargets[selection.sessionId])
  }

  if (hiddenSessionIds.size === 0 && hiddenSurfaceIds.size === 0) return sessions
  const sourceSessionIds = new Set(
    [
      ...Object.keys(restoredTargets),
      selection?.kind === 'session' ? selection.sessionId : null,
    ].filter((id): id is string => Boolean(id)),
  )
  const hasSourceSession = sessions.some((session) => sourceSessionIds.has(session.id))
  if (!hasSourceSession) return sessions

  return sessions.filter((session) => {
    if (sourceSessionIds.has(session.id)) return true
    if (hiddenSessionIds.has(session.id)) return false
    return !(session.surfaceId && hiddenSurfaceIds.has(session.surfaceId))
  })
}

function sessionScope(session: Session): 'meee2' | 'canvas' | 'node' | 'external' {
  switch (session.sessionScope) {
  case 'meee2':
  case 'canvas':
  case 'node':
    return session.sessionScope
  default:
    return 'external'
  }
}

function sessionCanBeReopened(session: Session): boolean {
  if (nativeTerminalTargetForSession(session).surfaceId) return false
  return Boolean(providerResumeTargetForSession(session))
}

function sessionIsVisibleInLauncher(session: Session): boolean {
  if (nativeTerminalTargetForSession(session).surfaceId) return true
  if (providerResumeTargetForSession(session)) return true
  const raw = (session.surfaceStatus ?? session.status ?? '').toLowerCase()
  if (session.terminalBackend === 'ghostty-surface' && (raw === 'exited' || raw === 'dead' || raw === 'failed')) {
    return false
  }
  return true
}

function providerResumeTargetForSession(session: Session): string | null {
  const candidates = [session.providerResumeSessionId, session.id]
  for (const candidate of candidates) {
    const trimmed = candidate?.trim()
    if (trimmed && isLikelyProviderResumeSessionId(trimmed)) return trimmed
  }
  return null
}

function isLikelyProviderResumeSessionId(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
}

function sessionArtifactFilter(session: Session, title: string): SessionArtifactFilterPayload {
  const project = session.project?.trim() || null
  return {
    sessionId: session.id,
    title,
    providerResumeSessionId: session.providerResumeSessionId ?? null,
    surfaceId: session.surfaceId ?? null,
    project,
    projectName: project ? basename(project) : null,
  }
}

function launcherProviderForSession(session: Session): SpawnProvider | undefined {
  const haystack = `${session.pluginId} ${session.pluginDisplayName}`.toLowerCase()
  if (haystack.includes('codex')) return 'codex'
  if (haystack.includes('claude')) return 'claude'
  return undefined
}

function projectForSession(session: Session, projects: SessionProject[]): SessionProject | null {
  const path = normalizePath(session.project || '')
  if (!path) return null
  return projects.find((project) => normalizePath(project.path) === path) ?? null
}

function normalizePath(path: string): string {
  return path.trim().replace(/\/+$/, '')
}

function basename(path: string): string {
  const normalized = normalizePath(path)
  return normalized.split('/').filter(Boolean).pop() ?? normalized
}

function normalizePermissionMode(provider: SpawnProvider, mode: AgentPermissionMode | undefined): AgentPermissionMode {
  const options = PERMISSION_OPTIONS[provider]
  return options.some((option) => option.value === mode) ? mode as AgentPermissionMode : DEFAULT_PERMISSION_MODE
}

function compareSessions(a: Session, b: Session): number {
  return sessionTime(b) - sessionTime(a)
}

function sessionTime(session: Session): number {
  const raw = session.lastActivity ?? session.startedAt ?? ''
  const parsed = Date.parse(raw)
  return Number.isNaN(parsed) ? 0 : parsed
}

function compactSessionAge(session: Session): string {
  const raw = session.lastActivity ?? session.startedAt ?? ''
  const parsed = Date.parse(raw)
  if (Number.isNaN(parsed)) return ''
  const delta = Math.max(0, Date.now() - parsed)
  if (delta < 60_000) return '刚刚'
  if (delta < 3_600_000) return `${Math.floor(delta / 60_000)}分`
  if (delta < 86_400_000) return `${Math.floor(delta / 3_600_000)}小时`
  return `${Math.floor(delta / 86_400_000)}天`
}

function projectTime(project: SessionProject): number {
  const raw = project.lastUsedAt ?? project.updatedAt ?? project.createdAt
  const parsed = Date.parse(raw)
  return Number.isNaN(parsed) ? 0 : parsed
}

function sessionRuntimeLabel(session: Session | null): string {
  const label = session?.pluginDisplayName || session?.pluginId || ''
  return label.replace(/^com\.meee2\.plugin\./, '').trim()
}

function sessionProjectLabel(session: Session | null): string {
  const raw = session?.project?.trim() ?? ''
  if (!raw) return ''
  const normalized = raw.replace(/\/+$/, '')
  const parts = normalized.split('/').filter(Boolean)
  return parts[parts.length - 1] || normalized
}

function sessionTerminalStatus(
  session: Session | null,
  t: ReturnType<typeof useI18n>['t'],
): { label: string; tone: 'running' | 'attention' | 'done' | 'failed' | 'idle' } {
  const raw = (session?.surfaceStatus ?? session?.status ?? '').toLowerCase()
  if (raw === 'starting' || raw === 'running' || raw === 'active' || raw.includes('tool')) {
    return { label: t('sessions.launcher.statusRunning'), tone: 'running' }
  }
  if (raw === 'permissionrequired' || raw === 'waitingforuser' || (session ? sessionNeedsAttention(session) : false)) {
    return { label: t('sessions.launcher.statusNeedsInput'), tone: 'attention' }
  }
  if (raw === 'completed' || raw === 'done' || raw === 'idle') {
    return { label: t('sessions.launcher.statusDone'), tone: 'done' }
  }
  if (raw === 'failed' || raw.includes('error') || raw.includes('blocked')) {
    return { label: t('sessions.launcher.statusFailed'), tone: 'failed' }
  }
  if (raw === 'exited' || raw === 'dead') {
    return { label: t('sessions.launcher.statusExited'), tone: 'idle' }
  }
  return { label: t('sessions.launcher.starting'), tone: 'running' }
}

function sessionLauncherTerminalFallbackMessage(
  session: Session | null,
  reopening: boolean,
  t: ReturnType<typeof useI18n>['t'],
): string {
  if (reopening) return t('sessions.launcher.reopeningTerminal')
  if (!session) return t('sessions.launcher.noTerminalSurface')
  const raw = (session.surfaceStatus ?? session.status ?? '').toLowerCase()
  if (raw === 'exited' || raw === 'dead' || raw === 'failed') {
    return providerResumeTargetForSession(session)
      ? t('sessions.launcher.exitedResumeAvailable')
      : t('sessions.launcher.noTerminalSurface')
  }
  return t('sessions.launcher.waitingForTerminalSurface')
}

function sessionDisplayTitle(session: Session, titleOverrides: Record<string, string>): string {
  const override = titleOverrides[session.id]?.replace(/\s+/g, ' ').trim()
  return override || sessionTitle(session)
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
  const rawValue = raw ?? ''
  const planModeUserRequest = extractPlanModeUserRequest(rawValue)
  if (planModeUserRequest) return cleanSessionTitle(planModeUserRequest)
  if (/^\s*Plan mode is enabled for this Codex session\./i.test(rawValue)) return ''
  const value = rawValue
    .replace(/\[[^\]]+\]\([^)]+\)/g, '')
    .replace(/\s+/g, ' ')
    .trim()
  if (!value) return ''
  const firstSentence = value.split(/\n|。|[.!?]\s/)[0]?.trim() ?? value
  const withoutSpeaker = firstSentence.replace(/^(user|assistant|human|system)\s*:\s*/i, '').trim()
  const withoutPlanSlash = withoutSpeaker.replace(/^\/plan(?:\s+|$)/i, '').trim()
  const genericProviderTitle = /^(codex|claude code|claude)\s+-\s+[^/\\]+$/i
  const internalNodeTitle = /^node\s+(?:node-)?[a-z0-9][a-z0-9-]{10,}(?:-transcript)?$/i
  if (!withoutPlanSlash) return ''
  if (genericProviderTitle.test(withoutPlanSlash)) return ''
  if (internalNodeTitle.test(withoutPlanSlash)) return ''
  return withoutPlanSlash.length > 56 ? `${withoutPlanSlash.slice(0, 54).trim()}...` : withoutPlanSlash
}

function extractPlanModeUserRequest(raw: string): string | null {
  if (!/^\s*Plan mode is enabled for this Codex session\./i.test(raw)) return null
  const match = raw.match(/\bUser request:\s*([\s\S]+)$/i)
  return match?.[1]?.trim() || null
}

function sameRect(a: NativeTerminalRect | null, b: NativeTerminalRect): boolean {
  if (!a) return false
  return a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height
}

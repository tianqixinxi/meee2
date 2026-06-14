import { useCallback, useEffect, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from 'react'
import { Archive, CheckCircle2, CircleAlert, RotateCcw } from 'lucide-react'
import { NotificationSettings } from './NotificationSettings'
import { ReadinessChecklist } from './ReadinessChecklist'
import {
  DEFAULT_SPAWN_PROVIDER,
  loadAllowCloud,
  loadBoardGridEnabled,
  loadCanvasRecapIntervalMinutes,
  loadLockViewportOnSwitch,
  loadSpawnProvider,
  saveAllowCloud,
  saveBoardGridEnabled,
  saveCanvasRecapIntervalMinutes,
  saveLockViewportOnSwitch,
  saveSpawnProvider,
  spawnProviderLabel,
} from '../preferences'
import type { Meee2AgentRuntimeStatus, ReadinessReport, SpawnProvider } from '../types'
import {
  DEFAULT_BASE_URL,
  DEFAULT_MODEL,
  providerLabel,
  readLlmSettings,
  writeLlmSettings,
  type LlmProvider,
  type LlmSettings,
} from '../lib/llmSettings'
import { useI18n, type Locale, type TranslationKey } from '../lib/i18n'
import { useTheme, type ThemeMode } from '../lib/theme'
import {
  deleteLocalData,
  disconnectMeee2Online,
  exportDebugBundle,
  fetchAppSettings,
  fetchDevPerf,
  fetchStorageStats,
  fetchUserProfile,
  openMeee2OnlineConnect,
  openMeee2OnlineDashboard,
  requestDeleteLocalDataToken,
  resetDevPerf,
  updateAppSettings,
  updateSessionControl,
  type AppSettings,
  type StorageStats,
  type UserProfile,
} from '../api'
import type { BoardPerfSnapshot, Session } from '../types'

interface Props {
  onSaved?: (provider: SpawnProvider) => void
  onToast?: (kind: 'info' | 'error' | 'success', text: string) => void
  agentRuntimeStatus?: Meee2AgentRuntimeStatus | null
  onOpenAgentRuntime?: (target: SpawnProvider) => void
  onRefreshAgentRuntime?: () => void
  readinessReport?: ReadinessReport | null
  readinessRepairAction?: string | null
  readinessRepairError?: string | null
  readinessRepairLogs?: string[]
  onRepairReadiness?: (actionId: string) => void
  onRefreshReadiness?: () => void
  sessions?: Session[]
  onSessionControlChanged?: () => void
  devMode?: boolean
  onRestartOnboarding?: () => void
}

type SettingsCategory = 'general' | 'account' | 'privacy' | 'archivedSessions' | 'notifications' | 'runtime' | 'models' | 'developer'

const DEFAULT_APP_SETTINGS: AppSettings = {
  theme: 'system',
  locale: 'en',
  devMode: false,
  showIsland: true,
  selectedScreenId: 'builtin',
  availableScreens: [{ id: 'builtin', name: 'Built-in Display', hasNotch: false }],
  autoExpandEnabled: true,
  autoCloseInterval: 8,
  showSessionInCompact: true,
  carouselInterval: 10,
  quickOpenShortcut: 'cmd+option+KeyP',
  quickOpenShortcutLabel: '⌘⌥P',
  quickOpenShortcutConflict: null,
}

const MODIFIER_CODES = new Set([
  'MetaLeft',
  'MetaRight',
  'AltLeft',
  'AltRight',
  'ControlLeft',
  'ControlRight',
  'ShiftLeft',
  'ShiftRight',
])

const KEY_LABELS: Record<string, string> = {
  Backquote: '`',
  Backslash: '\\',
  Backspace: 'Delete',
  BracketLeft: '[',
  BracketRight: ']',
  Comma: ',',
  Digit0: '0',
  Digit1: '1',
  Digit2: '2',
  Digit3: '3',
  Digit4: '4',
  Digit5: '5',
  Digit6: '6',
  Digit7: '7',
  Digit8: '8',
  Digit9: '9',
  Enter: 'Return',
  Equal: '=',
  Escape: 'Esc',
  Minus: '-',
  Period: '.',
  Quote: "'",
  Semicolon: ';',
  Slash: '/',
  Space: 'Space',
  Tab: 'Tab',
  ArrowLeft: 'Left',
  ArrowRight: 'Right',
  ArrowDown: 'Down',
  ArrowUp: 'Up',
}

function formatShortcut(raw: string | null | undefined): string {
  if (!raw || raw === 'disabled') return 'Disabled'
  const parts = raw.split('+')
  const key = parts.length > 0 ? parts[parts.length - 1] : ''
  const modifiers = parts.slice(0, -1).map((part) => {
    if (part === 'cmd') return '⌘'
    if (part === 'option') return '⌥'
    if (part === 'control') return '⌃'
    if (part === 'shift') return '⇧'
    return ''
  }).join('')
  const label = key.startsWith('Key')
    ? key.slice(3)
    : KEY_LABELS[key] ?? key.replace(/^Digit/, '')
  return `${modifiers}${label}`
}

function compareSettingsSessions(a: Session, b: Session): number {
  return timestampForSettingsSession(b) - timestampForSettingsSession(a)
}

function timestampForSettingsSession(session: Session): number {
  const raw = session.lastActivity || session.startedAt || ''
  const parsed = Date.parse(raw)
  return Number.isFinite(parsed) ? parsed : 0
}

function settingsSessionTitle(session: Session): string {
  const recap = session.latestRecap?.content?.trim()
  if (recap) return truncateSettingsSessionTitle(recap)
  const firstUser = session.recentMessages.find((entry) => entry.role.toLowerCase() === 'user' && entry.text.trim())
  if (firstUser) return truncateSettingsSessionTitle(firstUser.text)
  if (session.currentTask?.trim()) return truncateSettingsSessionTitle(session.currentTask)
  return truncateSettingsSessionTitle(session.title || session.id)
}

function truncateSettingsSessionTitle(value: string): string {
  const compact = value.replace(/\s+/g, ' ').trim()
  return compact.length > 72 ? `${compact.slice(0, 71)}...` : compact
}

type ShortcutKeyboardInput = Pick<KeyboardEvent, 'altKey' | 'code' | 'ctrlKey' | 'key' | 'metaKey' | 'shiftKey'>

function shortcutFromKeyboardEvent(event: ShortcutKeyboardInput): string | null {
  if (event.key === 'Escape') return null
  if (MODIFIER_CODES.has(event.code)) return null
  const modifiers = [
    event.ctrlKey ? 'control' : '',
    event.altKey ? 'option' : '',
    event.shiftKey ? 'shift' : '',
    event.metaKey ? 'cmd' : '',
  ].filter(Boolean)
  const hasPrimaryModifier = event.metaKey || event.ctrlKey || event.altKey
  if (!hasPrimaryModifier || modifiers.length === 0) return null
  return [...modifiers, event.code].join('+')
}

export function SettingsView({
  onSaved,
  onToast,
  agentRuntimeStatus = null,
  onOpenAgentRuntime,
  onRefreshAgentRuntime,
  readinessReport = null,
  readinessRepairAction = null,
  readinessRepairError = null,
  readinessRepairLogs = [],
  onRepairReadiness,
  onRefreshReadiness,
  sessions = [],
  onSessionControlChanged,
  devMode = false,
  onRestartOnboarding,
}: Props) {
  const { t, locale, setLocale } = useI18n()
  const { mode, setMode } = useTheme()
  const [spawnProvider, setSpawnProvider] = useState<SpawnProvider>(loadSpawnProvider)
  const [boardGridEnabled, setBoardGridEnabled] = useState(loadBoardGridEnabled)
  const [lockViewportOnSwitch, setLockViewportOnSwitch] = useState(loadLockViewportOnSwitch)
  const [canvasRecapIntervalMinutes, setCanvasRecapIntervalMinutes] = useState(loadCanvasRecapIntervalMinutes)
  const [llm, setLlm] = useState<LlmSettings>(() => readLlmSettings())
  const [profile, setProfile] = useState<UserProfile | null>(null)
  const [appSettings, setAppSettings] = useState<AppSettings>(DEFAULT_APP_SETTINGS)
  const [activeSettingsCategory, setActiveSettingsCategory] = useState<SettingsCategory>('general')
  const [recordingQuickOpenShortcut, setRecordingQuickOpenShortcut] = useState(false)
  const quickOpenRecorderRef = useRef<HTMLButtonElement | null>(null)
  const recordingPreviousShortcutRef = useRef<string | null>(null)
  const [debugExporting, setDebugExporting] = useState(false)
  const [debugExportPath, setDebugExportPath] = useState<string | null>(null)
  // Chunk E (Privacy UI)
  const [storageStats, setStorageStats] = useState<StorageStats | null>(null)
  const [storageStatsError, setStorageStatsError] = useState<string | null>(null)
  const [storageStatsLoading, setStorageStatsLoading] = useState(false)
  const [allowCloud, setAllowCloud] = useState(loadAllowCloud)
  const [deleteConfirmOpen, setDeleteConfirmOpen] = useState(false)
  const [deleteConfirmAcknowledged, setDeleteConfirmAcknowledged] = useState(false)
  const [deletingLocalData, setDeletingLocalData] = useState(false)
  const [perfSnapshot, setPerfSnapshot] = useState<BoardPerfSnapshot | null>(null)
  const [perfLoading, setPerfLoading] = useState(false)
  const [perfError, setPerfError] = useState<string | null>(null)
  const [restoringArchivedSessionId, setRestoringArchivedSessionId] = useState<string | null>(null)
  const [locallyRestoredArchivedIds, setLocallyRestoredArchivedIds] = useState<Set<string>>(() => new Set())
  const effectiveAppSettings = normalizeAppSettings(appSettings)
  const settingsCategories: Array<{ id: SettingsCategory; label: string }> = [
    { id: 'general', label: t('settings.categoryGeneral') },
    { id: 'account', label: t('settings.categoryAccount') },
    { id: 'privacy', label: t('settings.categoryPrivacy') },
    { id: 'archivedSessions', label: t('settings.categoryArchivedSessions') },
    { id: 'notifications', label: t('settings.categoryNotifications') },
    { id: 'runtime', label: t('settings.categoryRuntime') },
    { id: 'models', label: t('settings.categoryModels') },
    ...(devMode || effectiveAppSettings.devMode
      ? [{ id: 'developer' as SettingsCategory, label: t('settings.categoryDeveloper') }]
      : []),
  ]

  const notify = useCallback((kind: 'info' | 'error' | 'success', text: string) => {
    onToast?.(kind, text)
  }, [onToast])

  const notifySaved = useCallback(() => {
    notify('success', t('common.saved'))
  }, [notify, t])

  const archivedSessions = sessions
    .filter((session) => session.controlState === 'archived' && !locallyRestoredArchivedIds.has(session.id))
    .sort(compareSettingsSessions)

  const restoreArchivedSession = useCallback(async (session: Session) => {
    setRestoringArchivedSessionId(session.id)
    setLocallyRestoredArchivedIds((current) => new Set([...current, session.id]))
    try {
      await updateSessionControl(session.id, 'restore')
      onSessionControlChanged?.()
      notify('success', t('sessions.restored'))
    } catch (err) {
      setLocallyRestoredArchivedIds((current) => {
        const next = new Set(current)
        next.delete(session.id)
        return next
      })
      notify('error', (err as Error).message || t('sessions.controlActionFailed'))
    } finally {
      setRestoringArchivedSessionId(null)
    }
  }, [notify, onSessionControlChanged, t])

  const loadProfile = useCallback(() => {
    fetchUserProfile()
      .then(setProfile)
      .catch(() => setProfile(null))
  }, [])

  const loadAppSettings = useCallback(() => {
    fetchAppSettings()
      .then((settings) => setAppSettings(normalizeAppSettings(settings)))
      .catch(() => setAppSettings(DEFAULT_APP_SETTINGS))
  }, [])

  const loadStorageStats = useCallback(() => {
    setStorageStatsLoading(true)
    setStorageStatsError(null)
    fetchStorageStats()
      .then((stats) => setStorageStats(stats))
      .catch((err: Error) => setStorageStatsError(err.message || 'storage stats unavailable'))
      .finally(() => setStorageStatsLoading(false))
  }, [])

  const loadPerfSnapshot = useCallback(() => {
    setPerfLoading(true)
    setPerfError(null)
    fetchDevPerf()
      .then(setPerfSnapshot)
      .catch((err: Error) => setPerfError(err.message || 'performance diagnostics unavailable'))
      .finally(() => setPerfLoading(false))
  }, [])

  useEffect(() => {
    loadProfile()
    loadAppSettings()
    loadStorageStats()
    window.addEventListener('focus', loadProfile)
    window.addEventListener('focus', loadAppSettings)
    return () => {
      window.removeEventListener('focus', loadProfile)
      window.removeEventListener('focus', loadAppSettings)
    }
  }, [loadAppSettings, loadProfile, loadStorageStats])

  useEffect(() => {
    if (activeSettingsCategory === 'developer' && (devMode || effectiveAppSettings.devMode)) {
      loadPerfSnapshot()
    }
  }, [activeSettingsCategory, devMode, effectiveAppSettings.devMode, loadPerfSnapshot])

  const runDebugExport = async () => {
    setDebugExporting(true)
    setDebugExportPath(null)
    try {
      const result = await exportDebugBundle()
      setDebugExportPath(result.path)
      notify('success', t('settings.debugExportReady'))
    } catch (err) {
      notify('error', (err as Error).message || t('settings.debugExportFailed'))
    } finally {
      setDebugExporting(false)
    }
  }

  const toggleAllowCloud = (next: boolean) => {
    setAllowCloud(next)
    saveAllowCloud(next)
    notifySaved()
  }

  const openDeleteConfirm = () => {
    setDeleteConfirmAcknowledged(false)
    setDeleteConfirmOpen(true)
  }

  const closeDeleteConfirm = () => {
    if (deletingLocalData) return // 删除进行中不允许 dismiss
    setDeleteConfirmOpen(false)
    setDeleteConfirmAcknowledged(false)
  }

  const confirmDeleteLocalData = async () => {
    if (!deleteConfirmAcknowledged) return
    setDeletingLocalData(true)
    try {
      // 二次确认 = 这里先 GET token,再立刻 POST。token 服务端是一次性的,
      // backdrop-click 走不到这里(closeDeleteConfirm 在 deletingLocalData 时
      // 也不会触发关闭),所以只有按下确认按钮才会真的 fire。
      const tokenResult = await requestDeleteLocalDataToken()
      const result = await deleteLocalData(tokenResult.token)
      notify(
        'success',
        t('settings.privacyDeleteSuccess', { bytes: formatBytes(result.removedBytes) }),
      )
      setDeleteConfirmOpen(false)
      setDeleteConfirmAcknowledged(false)
      loadStorageStats()
    } catch (err) {
      notify('error', (err as Error).message || t('settings.privacyDeleteFailed'))
    } finally {
      setDeletingLocalData(false)
    }
  }

  const updateAppSettingsDraft = useCallback((patch: Partial<AppSettings>) => {
    setAppSettings((current) => ({ ...normalizeAppSettings(current), ...patch }))
  }, [])

  const applyAppSettingsPatch = useCallback(async (patch: Partial<AppSettings>) => {
    updateAppSettingsDraft(patch)
    try {
      const next = await updateAppSettings(patch)
      setAppSettings(normalizeAppSettings(next))
      notifySaved()
    } catch (err) {
      notify('error', (err as Error).message || 'Failed to save settings')
      loadAppSettings()
    }
  }, [loadAppSettings, notify, notifySaved, updateAppSettingsDraft])

  const applyThemeMode = useCallback((nextMode: ThemeMode) => {
    setMode(nextMode)
    void applyAppSettingsPatch({ theme: nextMode })
  }, [applyAppSettingsPatch, setMode])

  const applyLocale = useCallback((nextLocale: Locale) => {
    setLocale(nextLocale)
    void applyAppSettingsPatch({ locale: nextLocale })
  }, [applyAppSettingsPatch, setLocale])

  const applySpawnProvider = useCallback((provider: SpawnProvider) => {
    setSpawnProvider(provider)
    saveSpawnProvider(provider)
    notifySaved()
    onSaved?.(provider)
  }, [notifySaved, onSaved])

  const applyBoardGridEnabled = useCallback((enabled: boolean) => {
    setBoardGridEnabled(enabled)
    saveBoardGridEnabled(enabled)
    notifySaved()
  }, [notifySaved])

  const applyLockViewportOnSwitch = useCallback((enabled: boolean) => {
    setLockViewportOnSwitch(enabled)
    saveLockViewportOnSwitch(enabled)
    notifySaved()
  }, [notifySaved])

  const applyCanvasRecapIntervalMinutes = useCallback((minutes: number) => {
    const normalized = Math.max(0, Math.min(120, minutes))
    setCanvasRecapIntervalMinutes(normalized)
    saveCanvasRecapIntervalMinutes(normalized)
    notifySaved()
  }, [notifySaved])

  const saveLlmDraft = useCallback((next: LlmSettings) => {
    writeLlmSettings(next)
    notifySaved()
  }, [notifySaved])

  const applyLlmProvider = useCallback((provider: LlmProvider) => {
    const next = { ...llm, provider }
    setLlm(next)
    saveLlmDraft(next)
  }, [llm, saveLlmDraft])

  const updateLlmDraft = useCallback((patch: Partial<LlmSettings>) => {
    setLlm((current) => ({ ...current, ...patch }))
  }, [])

  const applyQuickOpenShortcut = useCallback(async (shortcut: string) => {
    const label = formatShortcut(shortcut)
    recordingPreviousShortcutRef.current = null
    updateAppSettingsDraft({
      quickOpenShortcut: shortcut,
      quickOpenShortcutLabel: label,
      quickOpenShortcutConflict: null,
    })
    try {
      const next = await updateAppSettings({ quickOpenShortcut: shortcut })
      setAppSettings((current) => ({
        ...normalizeAppSettings(current),
        quickOpenShortcut: next.quickOpenShortcut,
        quickOpenShortcutLabel: next.quickOpenShortcutLabel,
        quickOpenShortcutConflict: next.quickOpenShortcutConflict,
      }))
    } catch (err) {
      notify('error', (err as Error).message || 'Failed to update shortcut')
    }
  }, [notify, updateAppSettingsDraft])

  const restoreQuickOpenShortcutRecording = useCallback(() => {
    const previousShortcut = recordingPreviousShortcutRef.current
    recordingPreviousShortcutRef.current = null
    setRecordingQuickOpenShortcut(false)
    if (previousShortcut) {
      void applyQuickOpenShortcut(previousShortcut)
    }
  }, [applyQuickOpenShortcut])

  const handleQuickOpenShortcutKey = useCallback((event: ShortcutKeyboardInput) => {
    if (event.key === 'Escape') {
      restoreQuickOpenShortcutRecording()
      return
    }
    if (event.key === 'Backspace' || event.key === 'Delete') {
      recordingPreviousShortcutRef.current = null
      void applyQuickOpenShortcut('disabled')
      setRecordingQuickOpenShortcut(false)
      return
    }
    const shortcut = shortcutFromKeyboardEvent(event)
    if (!shortcut) {
      notify('info', t('settings.quickOpenShortcutNeedsModifier'))
      return
    }
    void applyQuickOpenShortcut(shortcut)
    setRecordingQuickOpenShortcut(false)
  }, [applyQuickOpenShortcut, notify, restoreQuickOpenShortcutRecording, t])

  const recordQuickOpenShortcut = (event: ReactKeyboardEvent<HTMLButtonElement>) => {
    event.preventDefault()
    event.stopPropagation()
    handleQuickOpenShortcutKey(event)
  }

  const startQuickOpenShortcutRecording = () => {
    if (!recordingQuickOpenShortcut) {
      recordingPreviousShortcutRef.current = effectiveAppSettings.quickOpenShortcut
      void updateAppSettings({ quickOpenShortcut: 'disabled' }).catch((err: Error) => {
        notify('error', err.message || 'Failed to prepare shortcut recorder')
      })
    }
    setRecordingQuickOpenShortcut(true)
    window.requestAnimationFrame(() => quickOpenRecorderRef.current?.focus())
  }

  useEffect(() => {
    if (!recordingQuickOpenShortcut) return
    const handleKeyDown = (event: KeyboardEvent) => {
      event.preventDefault()
      event.stopPropagation()
      handleQuickOpenShortcutKey(event)
    }
    window.addEventListener('keydown', handleKeyDown, true)
    quickOpenRecorderRef.current?.focus()
    return () => {
      window.removeEventListener('keydown', handleKeyDown, true)
      const previousShortcut = recordingPreviousShortcutRef.current
      if (previousShortcut) {
        recordingPreviousShortcutRef.current = null
        void applyQuickOpenShortcut(previousShortcut)
      }
    }
  }, [applyQuickOpenShortcut, handleQuickOpenShortcutKey, recordingQuickOpenShortcut])

  const connectOnline = async () => {
    try {
      await openMeee2OnlineConnect()
    } catch (err) {
      notify('error', (err as Error).message || 'Failed to open Meee2 Online')
    }
  }

  const openOnline = async () => {
    try {
      await openMeee2OnlineDashboard()
    } catch (err) {
      notify('error', (err as Error).message || 'Failed to open Meee2 Online')
    }
  }

  const logoutOnline = async () => {
    try {
      await disconnectMeee2Online()
      loadProfile()
      notify('success', 'Disconnected from Meee2 Online')
    } catch (err) {
      notify('error', (err as Error).message || 'Failed to disconnect')
    }
  }

  const clearPerfSnapshot = async () => {
    setPerfLoading(true)
    setPerfError(null)
    try {
      const next = await resetDevPerf()
      setPerfSnapshot(next)
      notify('success', t('settings.perfResetDone'))
    } catch (err) {
      setPerfError((err as Error).message || 'performance diagnostics reset failed')
    } finally {
      setPerfLoading(false)
    }
  }

  const currentTeam = currentTeamForProfile(profile)

  return (
    <main className="settings-page" aria-label={t('settings.title')}>
      <header className="settings-page__header">
        <div>
          <h1>{t('settings.title')}</h1>
          <p>{t('settings.subtitle')}</p>
        </div>
      </header>

      <div className="settings-page__main">
        <aside className="settings-category-rail" aria-label={t('settings.categoryLabel')}>
          {settingsCategories.map((category) => (
            <button
              key={category.id}
              type="button"
              className={activeSettingsCategory === category.id ? 'active' : ''}
              onClick={() => setActiveSettingsCategory(category.id)}
            >
              {category.label}
            </button>
          ))}
        </aside>

        <div className="settings-page__content settings-body">
        {activeSettingsCategory === 'general' && (
          <>
        <section className="settings-section">
          <div className="settings-section-header">
            <div>
              <div className="settings-section-title">{t('settings.appearance')}</div>
              <div className="settings-section-caption">{t('settings.appearanceCaption')}</div>
            </div>
          </div>
          <label className="settings-field-row settings-panel">
            <span>
              <strong>{t('settings.theme')}</strong>
            </span>
            <span className="segment">
              {(['system', 'light', 'dark'] as ThemeMode[]).map((value) => (
                <button
                  key={value}
                  type="button"
                  className={mode === value ? 'active' : ''}
                  onClick={() => applyThemeMode(value)}
                >
                  {value === 'system' ? t('settings.themeSystem') : value === 'light' ? t('settings.themeLight') : t('settings.themeDark')}
                </button>
              ))}
            </span>
          </label>
          <label className="settings-field-row settings-panel">
            <span>
              <strong>{t('settings.language')}</strong>
              <small>{t('settings.languageSystemCaption')}</small>
            </span>
            <span className="segment">
              {(['en', 'zh-CN'] as Locale[]).map((value) => (
                <button
                  key={value}
                  type="button"
                  className={locale === value ? 'active' : ''}
                  onClick={() => applyLocale(value)}
                >
                  {value === 'en' ? t('settings.languageEnglish') : t('settings.languageChinese')}
                </button>
              ))}
            </span>
          </label>
        </section>

        <section className="settings-section">
          <div className="settings-section-header">
            <div>
              <div className="settings-section-title">{t('settings.dynamicIsland')}</div>
              <div className="settings-section-caption">{t('settings.dynamicIslandCaption')}</div>
            </div>
          </div>
          <label className="settings-toggle-row settings-panel">
            <span>
              <strong>{t('settings.showIsland')}</strong>
              <small>{t('settings.showIslandHelp')}</small>
            </span>
            <input
              type="checkbox"
              checked={effectiveAppSettings.showIsland}
              onChange={(event) => void applyAppSettingsPatch({ showIsland: event.target.checked })}
            />
          </label>
          <label className="settings-field-row settings-panel">
            <span>
              <strong>{t('settings.displayIslandOn')}</strong>
            </span>
            <select
              value={effectiveAppSettings.selectedScreenId}
              disabled={!effectiveAppSettings.showIsland}
              onChange={(event) => void applyAppSettingsPatch({ selectedScreenId: event.target.value })}
            >
              {effectiveAppSettings.availableScreens.map((screen) => (
                <option key={screen.id} value={screen.id}>
                  {screen.name}{screen.hasNotch ? ' • notch' : ''}
                </option>
              ))}
            </select>
          </label>
          <label className="settings-toggle-row settings-panel">
            <span>
              <strong>{t('settings.autoExpand')}</strong>
            </span>
            <input
              type="checkbox"
              disabled={!effectiveAppSettings.showIsland}
              checked={effectiveAppSettings.autoExpandEnabled}
              onChange={(event) => void applyAppSettingsPatch({ autoExpandEnabled: event.target.checked })}
            />
          </label>
          <SettingSlider
            label={t('settings.autoCloseAfter')}
            disabled={!effectiveAppSettings.showIsland}
            min={3}
            max={30}
            value={effectiveAppSettings.autoCloseInterval}
            valueLabel={t('settings.seconds', { value: effectiveAppSettings.autoCloseInterval })}
            onChange={(value) => void applyAppSettingsPatch({ autoCloseInterval: value })}
          />
          <div className="settings-field-row settings-panel settings-shortcut-row">
            <span>
              <strong>{t('settings.quickOpenShortcut')}</strong>
              <small>{t('settings.quickOpenShortcutHelp')}</small>
              {effectiveAppSettings.quickOpenShortcutConflict && (
                <small className="settings-shortcut-warning">
                  {t('settings.quickOpenShortcutConflict')}
                </small>
              )}
            </span>
            <span className="settings-shortcut-controls">
              <button
                ref={quickOpenRecorderRef}
                type="button"
                className="settings-shortcut-recorder"
                data-recording={recordingQuickOpenShortcut ? 'true' : 'false'}
                onClick={startQuickOpenShortcutRecording}
                onKeyDown={recordQuickOpenShortcut}
                onBlur={() => {
                  if (recordingQuickOpenShortcut) restoreQuickOpenShortcutRecording()
                }}
              >
                {recordingQuickOpenShortcut
                  ? t('settings.quickOpenShortcutRecording')
                  : (effectiveAppSettings.quickOpenShortcut === 'disabled'
                    ? t('common.disabled')
                    : (effectiveAppSettings.quickOpenShortcutLabel || formatShortcut(effectiveAppSettings.quickOpenShortcut)))}
              </button>
              <button
                type="button"
                className="ghost"
                onClick={() => void applyQuickOpenShortcut('disabled')}
              >
                {t('common.disabled')}
              </button>
            </span>
          </div>
        </section>

          </>
        )}

        {activeSettingsCategory === 'account' && (
        <section className="settings-section">
          <div className="settings-section-header">
            <div>
              <div className="settings-section-title">{t('settings.online')}</div>
              <div className="settings-section-caption">{t('settings.onlineCaption')}</div>
            </div>
          </div>
          <div className="settings-panel settings-account-panel">
            <div className="row" style={{ gap: 10 }}>
              <span className="settings-avatar" aria-hidden>
                {profile?.userAvatarUrl ? <img src={profile.userAvatarUrl} alt="" /> : <span>{profile?.initials ?? '?'}</span>}
              </span>
              <div className="col" style={{ gap: 2, minWidth: 0, flex: 1 }}>
                <strong className="truncate">
                  {profile?.connected ? profile.displayName : t('settings.notConnected')}
                </strong>
                <span className="muted truncate" style={{ fontSize: 11 }}>
                  {profile?.connected
                    ? (profile.userEmail || currentTeam?.name || 'Meee2 Online')
                    : t('settings.connectOnlineHelp')}
                </span>
              </div>
              {profile?.connected ? (
                <>
                  <button className="ghost" type="button" onClick={() => void openOnline()}>
                    {t('settings.openOnline')}
                  </button>
                  <button className="ghost" type="button" onClick={() => void logoutOnline()}>
                    {t('common.logout')}
                  </button>
                </>
              ) : (
                <button className="primary" type="button" onClick={() => void connectOnline()}>
                  {t('common.connect')}
                </button>
              )}
            </div>
            {profile?.connected && (
              <div className="col" style={{ gap: 8, marginTop: 10 }}>
                {currentTeam && (
                  <div className="settings-meta-row">
                    <span>{t('settings.team')}</span>
                    <strong>{currentTeam.name}</strong>
                  </div>
                )}
                <small className="muted">{t('settings.teamCanvasRuntimeSync')}</small>
              </div>
            )}
          </div>
        </section>
        )}

        {activeSettingsCategory === 'privacy' && (
          <>
        <section className="settings-section">
          <div className="settings-section-header">
            <div>
              <div className="settings-section-title">{t('settings.debugExport')}</div>
              <div className="settings-section-caption">{t('settings.debugExportCaption')}</div>
            </div>
            <button type="button" className="ghost" onClick={() => void runDebugExport()} disabled={debugExporting}>
              {debugExporting ? t('common.loading') : t('settings.exportDebug')}
            </button>
          </div>
          {debugExportPath && (
            <div className="settings-panel settings-debug-export">
              <span>{t('settings.debugExportSaved')}</span>
              <code>{debugExportPath}</code>
            </div>
          )}
        </section>

        <section className="settings-section" data-testid="settings-privacy">
          <div className="settings-section-header">
            <div>
              <div className="settings-section-title">{t('settings.privacy')}</div>
              <div className="settings-section-caption">{t('settings.privacyCaption')}</div>
            </div>
            <button
              type="button"
              className="ghost"
              onClick={loadStorageStats}
              disabled={storageStatsLoading}
            >
              {storageStatsLoading ? t('common.loading') : t('common.refresh')}
            </button>
          </div>

          {/* 1. 本地存储路径 + size 统计 */}
          <div className="settings-panel">
            <div className="col" style={{ gap: 6 }}>
              <strong>{t('settings.privacyStorageRoot')}</strong>
              <code style={{ fontSize: 11, wordBreak: 'break-all' }}>
                {storageStats?.root ?? '~/.meee2'}
              </code>
              <small className="muted">{t('settings.privacyStorageHelp')}</small>
              {storageStatsError && (
                <small className="muted" style={{ color: 'var(--accent-warn, #e07b5e)' }}>
                  {storageStatsError}
                </small>
              )}
              <div className="col" style={{ gap: 4, marginTop: 6 }}>
                <div className="settings-meta-row">
                  <span>{t('settings.privacyCanvases')}</span>
                  <strong>{formatBytes(storageStats?.canvases)}</strong>
                </div>
                <div className="settings-meta-row">
                  <span>{t('settings.privacySessions')}</span>
                  <strong>{formatBytes(storageStats?.sessions)}</strong>
                </div>
                <div className="settings-meta-row">
                  <span>{t('settings.privacyRunbooks')}</span>
                  <strong>{formatBytes(storageStats?.runbooks)}</strong>
                </div>
                <div className="settings-meta-row">
                  <span>{t('settings.privacyTotal')}</span>
                  <strong>{formatBytes(storageStats?.total)}</strong>
                </div>
              </div>
            </div>
          </div>

          {/* 2. 导出全部数据 */}
          <div className="settings-panel">
            <div className="settings-section-header" style={{ alignItems: 'center', gap: 12 }}>
              <div>
                <strong>{t('settings.privacyExportAll')}</strong>
                <div className="muted" style={{ fontSize: 11 }}>
                  {t('settings.privacyExportAllHelp')}
                </div>
              </div>
              <button
                type="button"
                className="ghost"
                onClick={() => void runDebugExport()}
                disabled={debugExporting}
              >
                {debugExporting ? t('settings.privacyExportRunning') : t('settings.privacyExportAll')}
              </button>
            </div>
          </div>

          {/* 3. 删除本地数据 */}
          <div className="settings-panel">
            <div className="settings-section-header" style={{ alignItems: 'center', gap: 12 }}>
              <div>
                <strong>{t('settings.privacyDeleteAll')}</strong>
                <div className="muted" style={{ fontSize: 11 }}>
                  {t('settings.privacyDeleteAllHelp')}
                </div>
              </div>
              <button
                type="button"
                className="ghost"
                onClick={openDeleteConfirm}
                disabled={deletingLocalData}
                style={{ color: 'var(--danger, #b94c45)' }}
              >
                {t('settings.privacyDeleteAll')}
              </button>
            </div>
          </div>

          {/* 4. Summarizer 数据流向说明 */}
          <div className="settings-panel">
            <div className="col" style={{ gap: 6 }}>
              <strong>{t('settings.privacySummarizer')}</strong>
              <small className="muted" style={{ lineHeight: 1.5 }}>
                {t('settings.privacySummarizerBody')}
              </small>
            </div>
          </div>

          {/* 5. 允许 cloud / model 调用 toggle */}
          <label className="settings-toggle-row settings-panel">
            <span>
              <strong>{t('settings.privacyAllowCloud')}</strong>
              <small>{t('settings.privacyAllowCloudHelp')}</small>
              {!allowCloud && (
                <small style={{ color: 'var(--accent-warn, #e07b5e)', display: 'block', marginTop: 4 }}>
                  {t('settings.privacyAllowCloudOffNote')}
                </small>
              )}
            </span>
            <input
              type="checkbox"
              checked={allowCloud}
              onChange={(event) => toggleAllowCloud(event.target.checked)}
            />
          </label>
        </section>

        {deleteConfirmOpen && (
          <PrivacyDeleteConfirmModal
            t={t}
            acknowledged={deleteConfirmAcknowledged}
            onToggleAck={setDeleteConfirmAcknowledged}
            onCancel={closeDeleteConfirm}
            onConfirm={() => void confirmDeleteLocalData()}
            deleting={deletingLocalData}
          />
        )}
          </>
        )}

        {activeSettingsCategory === 'archivedSessions' && (
          <section className="settings-section">
            <div className="settings-section-header">
              <div>
                <div className="settings-section-title">{t('settings.archivedSessions')}</div>
                <div className="settings-section-caption">{t('settings.archivedSessionsCaption')}</div>
              </div>
            </div>
            {archivedSessions.length === 0 ? (
              <div className="settings-panel settings-archived-sessions__empty">
                <Archive size={18} aria-hidden />
                <span>{t('settings.archivedSessionsEmpty')}</span>
              </div>
            ) : (
              <div className="settings-panel settings-archived-sessions">
                {archivedSessions.map((session) => (
                  <div key={session.id} className="settings-archived-session">
                    <div className="settings-archived-session__main">
                      <strong>{settingsSessionTitle(session)}</strong>
                      <span>{session.project || t('sessions.noProject')}</span>
                    </div>
                    <button
                      type="button"
                      className="ghost"
                      onClick={() => void restoreArchivedSession(session)}
                      disabled={restoringArchivedSessionId === session.id}
                    >
                      {restoringArchivedSessionId === session.id ? (
                        t('common.loading')
                      ) : (
                        <>
                          <RotateCcw size={14} aria-hidden />
                          {t('sessions.restore')}
                        </>
                      )}
                    </button>
                  </div>
                ))}
              </div>
            )}
          </section>
        )}

        {activeSettingsCategory === 'general' && (
        <section className="settings-section">
          <div className="settings-section-header">
            <div>
              <div className="settings-section-title">{t('settings.canvasDisplay')}</div>
              <div className="settings-section-caption">{t('settings.canvasDisplayCaption')}</div>
            </div>
          </div>
          <label className="settings-toggle-row settings-panel">
            <span>
              <strong>{t('settings.showGrid')}</strong>
              <small>{t('settings.showGridHelp')}</small>
            </span>
            <input type="checkbox" checked={boardGridEnabled} onChange={(event) => applyBoardGridEnabled(event.target.checked)} />
          </label>
          <label className="settings-toggle-row settings-panel">
            <span>
              <strong>{t('settings.lockViewport')}</strong>
              <small>{t('settings.lockViewportHelp')}</small>
            </span>
            <input type="checkbox" checked={lockViewportOnSwitch} onChange={(event) => applyLockViewportOnSwitch(event.target.checked)} />
          </label>
          <label className="settings-field-row settings-panel">
            <span>
              <strong>{t('settings.recapInterval')}</strong>
              <small>{t('settings.recapIntervalHelp')}</small>
            </span>
            <span className="settings-number-field">
              <input
                type="number"
                min={0}
                max={120}
                step={1}
                value={canvasRecapIntervalMinutes}
                onChange={(event) => {
                  const next = Number.parseInt(event.target.value, 10)
                  applyCanvasRecapIntervalMinutes(Number.isFinite(next) ? next : 0)
                }}
              />
              <small>{t('settings.minutes')}</small>
            </span>
          </label>
        </section>
        )}

        {activeSettingsCategory === 'notifications' && (
          <NotificationSettings onToast={onToast} />
        )}

        {activeSettingsCategory === 'runtime' && (
          <>
        <section className="settings-section">
          <div className="settings-section-header">
            <div>
              <div className="settings-section-title">Local session readiness</div>
              <div className="settings-section-caption">Provider hooks, socket, BoardServer, runtime, and local state.</div>
            </div>
            <button type="button" className="ghost" onClick={onRefreshReadiness}>
              {t('common.check')}
            </button>
          </div>
          <div className="settings-panel settings-readiness-panel">
            <ReadinessChecklist
              report={readinessReport}
              repairingAction={readinessRepairAction}
              onRepair={(actionId) => onRepairReadiness?.(actionId)}
              compact
            />
            {readinessRepairError && (
              <div className="first-run__error" role="alert">{readinessRepairError}</div>
            )}
            {readinessRepairLogs.length > 0 && (
              <details className="first-run__logs">
                <summary>Repair log</summary>
                <pre>{readinessRepairLogs.join('\n')}</pre>
              </details>
            )}
          </div>
        </section>

        <section className="settings-section">
          <div className="settings-section-header">
            <div>
              <div className="settings-section-title">{t('settings.agentRuntime')}</div>
              <div className="settings-section-caption">{t('settings.agentRuntimeCaption')}</div>
            </div>
          </div>
          <div className="segment">
            {(['claude', 'codex'] as SpawnProvider[]).map((provider) => (
              <button key={provider} type="button" className={spawnProvider === provider ? 'active' : ''} onClick={() => applySpawnProvider(provider)}>
                {spawnProviderLabel(provider)}
              </button>
            ))}
          </div>
          <RuntimeStatusPanel
            provider={spawnProvider}
            status={agentRuntimeStatus}
            onSetUp={() => onOpenAgentRuntime?.(spawnProvider)}
            onRefresh={onRefreshAgentRuntime}
          />
          <button className="ghost" style={{ alignSelf: 'flex-start', fontSize: 11, padding: '2px 8px' }} onClick={() => applySpawnProvider(DEFAULT_SPAWN_PROVIDER)}>
            {t('common.reset')}
          </button>
        </section>

          </>
        )}

        {activeSettingsCategory === 'models' && (
        <section className="settings-section">
          <div className="settings-section-header">
            <div>
              <div className="settings-section-title">{t('settings.assistantLlm')}</div>
              <div className="settings-section-caption">{t('settings.assistantLlmCaption')}</div>
            </div>
          </div>
          <div className="segment">
            {(['local', 'openai', 'anthropic'] as LlmProvider[]).map((p) => (
              <button key={p} className={p === llm.provider ? 'active' : ''} onClick={() => applyLlmProvider(p)} type="button">
                {providerLabel(p)}
              </button>
            ))}
          </div>
          {llm.provider !== 'local' && (
            <div className="col" style={{ gap: 6 }}>
              <SettingsTextInput label={t('settings.apiKey')} type="password" value={llm.apiKey} placeholder={llm.provider === 'openai' ? 'sk-...' : 'sk-ant-...'} onChange={(value) => updateLlmDraft({ apiKey: value })} onBlur={() => saveLlmDraft(llm)} />
              <SettingsTextInput label={`${t('settings.baseUrl')} (${t('settings.blankDefault')})`} value={llm.baseUrl} placeholder={DEFAULT_BASE_URL[llm.provider]} onChange={(value) => updateLlmDraft({ baseUrl: value })} onBlur={() => saveLlmDraft(llm)} />
              <SettingsTextInput label={`${t('settings.model')} (${t('settings.blankDefault')})`} value={llm.model} placeholder={DEFAULT_MODEL[llm.provider]} onChange={(value) => updateLlmDraft({ model: value })} onBlur={() => saveLlmDraft(llm)} />
            </div>
          )}
          {llm.provider === 'local' && (
            <div className="muted" style={{ fontSize: 11, lineHeight: 1.4 }}>
              {t('settings.localModeHelp')}
            </div>
          )}
        </section>
        )}

        {activeSettingsCategory === 'developer' && (devMode || effectiveAppSettings.devMode) && (
          <>
          <section className="settings-section">
            <div className="settings-section-header">
              <div>
                <div className="settings-section-title">{t('settings.developer')}</div>
                <div className="settings-section-caption">{t('settings.developerCaption')}</div>
              </div>
            </div>
            <label className="settings-field-row settings-panel">
              <span>
                <strong>{t('settings.restartOnboarding')}</strong>
                <small>{t('settings.restartOnboardingHelp')}</small>
              </span>
              <button
                className="ghost"
                type="button"
                onClick={onRestartOnboarding}
              >
                {t('settings.restartOnboarding')}
              </button>
            </label>
          </section>

          <section className="settings-section">
            <div className="settings-section-header">
              <div>
                <div className="settings-section-title">{t('settings.perfDiagnostics')}</div>
                <div className="settings-section-caption">{t('settings.perfDiagnosticsCaption')}</div>
              </div>
              <div className="row" style={{ gap: 8 }}>
                <button
                  type="button"
                  className="ghost"
                  onClick={loadPerfSnapshot}
                  disabled={perfLoading}
                >
                  {perfLoading ? t('common.loading') : t('common.refresh')}
                </button>
                <button
                  type="button"
                  className="ghost"
                  onClick={() => void clearPerfSnapshot()}
                  disabled={perfLoading}
                >
                  {t('common.reset')}
                </button>
              </div>
            </div>
            <PerfDiagnosticsPanel
              snapshot={perfSnapshot}
              loading={perfLoading}
              error={perfError}
            />
          </section>
          </>
        )}
        </div>
      </div>
    </main>
  )
}

function normalizeAppSettings(settings: AppSettings | null | undefined): AppSettings {
  if (!settings || typeof settings !== 'object') return DEFAULT_APP_SETTINGS
  return {
    ...DEFAULT_APP_SETTINGS,
    ...settings,
    availableScreens: Array.isArray(settings.availableScreens) && settings.availableScreens.length > 0
      ? settings.availableScreens
      : DEFAULT_APP_SETTINGS.availableScreens,
  }
}

function currentTeamForProfile(profile: UserProfile | null): UserProfile['teams'][number] | null {
  if (!profile?.connected) return null
  return profile.teams.find((team) => team.isDefault) ?? profile.teams[0] ?? null
}

function PerfDiagnosticsPanel({
  snapshot,
  loading,
  error,
}: {
  snapshot: BoardPerfSnapshot | null
  loading: boolean
  error: string | null
}) {
  const { t } = useI18n()
  const metrics = snapshot?.metrics ?? []
  const recentEvents = snapshot?.recentEvents ?? []
  const hotMetrics = [...metrics]
    .sort((a, b) => {
      const left = b.totalMs - a.totalMs
      if (left !== 0) return left
      return b.count - a.count
    })
    .slice(0, 10)

  return (
    <div className="settings-panel settings-perf-panel">
      <div className="settings-perf-summary">
        <div>
          <span>{t('settings.perfPid')}</span>
          <strong>{snapshot?.pid ?? '-'}</strong>
        </div>
        <div>
          <span>{t('settings.perfMetrics')}</span>
          <strong>{metrics.length}</strong>
        </div>
        <div>
          <span>{t('settings.perfEvents')}</span>
          <strong>{recentEvents.length}</strong>
        </div>
        <div>
          <span>{t('settings.perfEnabled')}</span>
          <strong>{snapshot ? (snapshot.enabled ? 'on' : 'off') : '-'}</strong>
        </div>
      </div>
      {loading && !snapshot && <small className="muted">{t('common.loading')}</small>}
      {error && <small className="settings-shortcut-warning">{error}</small>}
      {!loading && !error && !snapshot && (
        <small className="muted">{t('settings.perfEmpty')}</small>
      )}
      {hotMetrics.length > 0 && (
        <div className="settings-perf-table" role="table" aria-label={t('settings.perfHotMetrics')}>
          <div role="row" className="settings-perf-table__row settings-perf-table__head">
            <span>{t('settings.perfMetric')}</span>
            <span>{t('settings.perfCount')}</span>
            <span>{t('settings.perfP95')}</span>
            <span>{t('settings.perfTotal')}</span>
            <span>{t('settings.perfBytes')}</span>
          </div>
          {hotMetrics.map((metric) => (
            <div role="row" className="settings-perf-table__row" key={metric.id}>
              <span title={metric.lastDetail ?? metric.id}>
                <strong>{metric.title}</strong>
                <small>{metric.category}{metric.lastDetail ? ` · ${metric.lastDetail}` : ''}</small>
              </span>
              <span>{metric.count}</span>
              <span>{formatMs(metric.p95Ms)}</span>
              <span>{formatMs(metric.totalMs)}</span>
              <span>{formatBytes(metric.totalBytes)}</span>
            </div>
          ))}
        </div>
      )}
      {recentEvents.length > 0 && (
        <details className="settings-perf-events">
          <summary>{t('settings.perfRecentEvents')}</summary>
          <div className="settings-perf-event-list">
            {recentEvents.slice(-12).reverse().map((event) => (
              <div key={event.id} className="settings-perf-event">
                <span>
                  <strong>{event.title}</strong>
                  <small>{event.category}{event.detail ? ` · ${event.detail}` : ''}</small>
                </span>
                <code>{formatMs(event.durationMs)}{event.bytes ? ` · ${formatBytes(event.bytes)}` : ''}</code>
              </div>
            ))}
          </div>
        </details>
      )}
      {snapshot && (
        <small className="muted">
          {t('settings.perfCapturedAt')}: {formatTimestamp(snapshot.capturedAt)}
        </small>
      )}
    </div>
  )
}

function SettingSlider({
  label,
  disabled,
  min,
  max,
  value,
  valueLabel,
  onChange,
}: {
  label: string
  disabled: boolean
  min: number
  max: number
  value: number
  valueLabel: string
  onChange: (value: number) => void
}) {
  return (
    <label className="settings-field-row settings-panel">
      <span>
        <strong>{label}</strong>
      </span>
      <span className="settings-range-field">
        <input
          type="range"
          min={min}
          max={max}
          step={1}
          disabled={disabled}
          value={value}
          onChange={(event) => onChange(Number(event.target.value))}
        />
        <small>{valueLabel}</small>
      </span>
    </label>
  )
}

function SettingsTextInput({
  label,
  type = 'text',
  value,
  placeholder,
  onChange,
  onBlur,
}: {
  label: string
  type?: string
  value: string
  placeholder?: string
  onChange: (value: string) => void
  onBlur?: () => void
}) {
  return (
    <div className="col" style={{ gap: 2 }}>
      <label className="muted" style={{ fontSize: 11 }}>{label}</label>
      <input
        className="mono"
        type={type}
        value={value}
        placeholder={placeholder}
        onChange={(event) => onChange(event.target.value)}
        autoCapitalize="off"
        autoCorrect="off"
        spellCheck={false}
        onBlur={onBlur}
      />
    </div>
  )
}

function RuntimeStatusPanel({
  provider,
  status,
  onSetUp,
  onRefresh,
}: {
  provider: SpawnProvider
  status: Meee2AgentRuntimeStatus | null
  onSetUp?: () => void
  onRefresh?: () => void
}) {
  const { t } = useI18n()
  const runtime = provider === 'codex' ? status?.codex : status?.claude
  const ready = runtime?.configured === true
  const available = runtime?.available !== false
  return (
    <div className="settings-runtime-panel" data-ready={ready}>
      <div className="settings-runtime-panel__status" aria-hidden>
        {ready ? <CheckCircle2 size={16} /> : <CircleAlert size={16} />}
      </div>
      <div className="settings-runtime-panel__copy">
        <strong>{spawnProviderLabel(provider)} runtime</strong>
        <span>{runtime?.detail ?? (status ? t('settings.runtimeStatusUnavailable') : t('settings.runtimeChecking'))}</span>
        {runtime && (
          <small>
            {t('settings.runtimeCliApp', {
              cli: runtime.cliAvailable ? t('settings.found') : t('settings.missing'),
              app: runtime.appAvailable ? t('settings.found') : t('settings.missing'),
            })}
          </small>
        )}
      </div>
      <div className="settings-runtime-panel__actions">
        <button type="button" className="ghost" onClick={onRefresh}>{t('common.check')}</button>
        <button type="button" className="primary" disabled={!available} onClick={onSetUp}>
          {ready ? t('common.manage') : t('common.setUp')}
        </button>
      </div>
    </div>
  )
}

// Chunk E (Privacy UI) helpers --------------------------------------------

function formatBytes(value: number | null | undefined): string {
  if (value == null || !Number.isFinite(value) || value <= 0) return '0 B'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let v = value
  let i = 0
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024
    i += 1
  }
  // < 10 → 显示一位小数,>= 10 → 整数
  const formatted = v < 10 && i > 0 ? v.toFixed(1) : Math.round(v).toString()
  return `${formatted} ${units[i]}`
}

function formatMs(value: number | null | undefined): string {
  if (value == null || !Number.isFinite(value)) return '-'
  if (value < 1) return `${value.toFixed(1)}ms`
  if (value < 100) return `${value.toFixed(1)}ms`
  return `${Math.round(value)}ms`
}

function formatTimestamp(value: string | null | undefined): string {
  if (!value) return '-'
  const timestamp = Date.parse(value)
  if (Number.isNaN(timestamp)) return value
  return new Date(timestamp).toLocaleTimeString()
}

function PrivacyDeleteConfirmModal({
  t,
  acknowledged,
  onToggleAck,
  onCancel,
  onConfirm,
  deleting,
}: {
  t: (key: TranslationKey, params?: Record<string, string | number>) => string
  acknowledged: boolean
  onToggleAck: (value: boolean) => void
  onCancel: () => void
  onConfirm: () => void
  deleting: boolean
}) {
  // 二次确认 modal:
  //   - 点 backdrop 不算确认(我们在 backdrop 上只触发 cancel,不触发 delete)
  //   - 删除按钮 disabled 直到用户主动勾选 acknowledged
  //   - 删除中不可关闭(防止 token 已签发但 UI 进入未知状态)
  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="privacy-delete-confirm-title"
      style={{
        position: 'fixed',
        inset: 0,
        zIndex: 1000,
        background: 'rgba(0, 0, 0, 0.45)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
      onClick={(event) => {
        // backdrop click → 只 cancel,不视为确认
        if (event.target === event.currentTarget) onCancel()
      }}
    >
      <div
        className="settings-panel"
        style={{
          maxWidth: 460,
          width: 'min(92vw, 460px)',
          padding: 20,
          background: 'var(--surface, #1c1c1f)',
          border: '1px solid var(--border, #2a2a2e)',
          borderRadius: 12,
          boxShadow: '0 14px 40px rgba(0,0,0,0.5)',
        }}
      >
        <h2
          id="privacy-delete-confirm-title"
          style={{ fontSize: 16, fontWeight: 600, margin: 0, marginBottom: 10 }}
        >
          {t('settings.privacyDeleteConfirmTitle')}
        </h2>
        <p style={{ fontSize: 12, lineHeight: 1.5, margin: 0, marginBottom: 14 }}>
          {t('settings.privacyDeleteConfirmBody')}
        </p>
        <label className="settings-toggle-row" style={{ padding: '6px 0', marginBottom: 12 }}>
          <span>
            <strong style={{ fontSize: 12 }}>{t('settings.privacyDeleteConfirmAck')}</strong>
          </span>
          <input
            type="checkbox"
            checked={acknowledged}
            onChange={(event) => onToggleAck(event.target.checked)}
          />
        </label>
        <div className="row" style={{ gap: 8, justifyContent: 'flex-end' }}>
          <button type="button" className="ghost" onClick={onCancel} disabled={deleting}>
            {t('common.cancel')}
          </button>
          <button
            type="button"
            className="primary"
            onClick={onConfirm}
            disabled={!acknowledged || deleting}
            style={{ background: 'var(--danger, #b94c45)' }}
          >
            {deleting ? t('common.loading') : t('settings.privacyDeleteConfirmAction')}
          </button>
        </div>
      </div>
    </div>
  )
}

import { useCallback, useEffect, useState } from 'react'
import { CheckCircle2, CircleAlert } from 'lucide-react'
import { ReadinessChecklist } from './ReadinessChecklist'
import {
  DEFAULT_SPAWN_PROVIDER,
  loadBoardGridEnabled,
  loadCanvasRecapIntervalMinutes,
  loadLockViewportOnSwitch,
  loadSpawnProvider,
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
import { useI18n, type Locale } from '../lib/i18n'
import { useTheme, type ThemeMode } from '../lib/theme'
import {
  disconnectMeee2Online,
  fetchAppSettings,
  fetchUserProfile,
  openMeee2OnlineConnect,
  openMeee2OnlineDashboard,
  updateAppSettings,
  updateUserProfile,
  type AppSettings,
  type UserProfile,
} from '../api'

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
  devMode?: boolean
  onRestartOnboarding?: () => void
}

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
  const [saving, setSaving] = useState(false)
  const effectiveAppSettings = normalizeAppSettings(appSettings)

  const notify = useCallback((kind: 'info' | 'error' | 'success', text: string) => {
    onToast?.(kind, text)
  }, [onToast])

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

  useEffect(() => {
    loadProfile()
    loadAppSettings()
    window.addEventListener('focus', loadProfile)
    window.addEventListener('focus', loadAppSettings)
    return () => {
      window.removeEventListener('focus', loadProfile)
      window.removeEventListener('focus', loadAppSettings)
    }
  }, [loadAppSettings, loadProfile])

  const save = async () => {
    setSaving(true)
    const settingsToSave = normalizeAppSettings(appSettings)
    try {
      saveSpawnProvider(spawnProvider)
      saveBoardGridEnabled(boardGridEnabled)
      saveLockViewportOnSwitch(lockViewportOnSwitch)
      saveCanvasRecapIntervalMinutes(canvasRecapIntervalMinutes)
      writeLlmSettings(llm)
      const next = await updateAppSettings({
        theme: mode,
        locale,
        showIsland: settingsToSave.showIsland,
        selectedScreenId: settingsToSave.selectedScreenId,
        autoExpandEnabled: settingsToSave.autoExpandEnabled,
        autoCloseInterval: settingsToSave.autoCloseInterval,
        showSessionInCompact: settingsToSave.showSessionInCompact,
        carouselInterval: settingsToSave.carouselInterval,
      })
      setAppSettings(normalizeAppSettings(next))
      notify('success', t('toast.settingsSaved'))
      onSaved?.(spawnProvider)
    } catch (err) {
      notify('error', (err as Error).message || 'Failed to save settings')
    } finally {
      setSaving(false)
    }
  }

  const setProvider = (p: LlmProvider) => {
    setLlm((s) => ({ ...s, provider: p }))
  }

  const updateAppSettingsDraft = (patch: Partial<AppSettings>) => {
    setAppSettings((current) => ({ ...normalizeAppSettings(current), ...patch }))
  }

  const setDefaultSync = async (enabled: boolean) => {
    try {
      setProfile(await updateUserProfile({ defaultSyncEnabled: enabled }))
    } catch (err) {
      notify('error', (err as Error).message || 'Failed to update sync setting')
    }
  }

  const setSessionSync = async (sessionId: string, enabled: boolean) => {
    try {
      setProfile(await updateUserProfile({ sessionSync: { sessionId, enabled } }))
    } catch (err) {
      notify('error', (err as Error).message || 'Failed to update session sync')
    }
  }

  const connectOnline = async () => {
    try {
      await openMeee2OnlineConnect()
    } catch (err) {
      notify('error', (err as Error).message || 'Failed to open meee2 Online')
    }
  }

  const openOnline = async () => {
    try {
      await openMeee2OnlineDashboard()
    } catch (err) {
      notify('error', (err as Error).message || 'Failed to open meee2 Online')
    }
  }

  const logoutOnline = async () => {
    try {
      await disconnectMeee2Online()
      loadProfile()
      notify('success', 'Disconnected from meee2 Online')
    } catch (err) {
      notify('error', (err as Error).message || 'Failed to disconnect')
    }
  }

  const sessionSync = profile?.sessionSync ?? []

  return (
    <main className="settings-page" aria-label={t('settings.title')}>
      <header className="settings-page__header">
        <div>
          <h1>{t('settings.title')}</h1>
          <p>{t('settings.subtitle')}</p>
        </div>
        <button className="primary" type="button" onClick={() => void save()} disabled={saving}>
          {saving ? t('common.loading') : t('common.save')}
        </button>
      </header>

      <div className="settings-page__content settings-body">
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
                  onClick={() => setMode(value)}
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
                  onClick={() => setLocale(value)}
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
              onChange={(event) => updateAppSettingsDraft({ showIsland: event.target.checked })}
            />
          </label>
          <label className="settings-field-row settings-panel">
            <span>
              <strong>{t('settings.displayIslandOn')}</strong>
            </span>
            <select
              value={effectiveAppSettings.selectedScreenId}
              disabled={!effectiveAppSettings.showIsland}
              onChange={(event) => updateAppSettingsDraft({ selectedScreenId: event.target.value })}
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
              onChange={(event) => updateAppSettingsDraft({ autoExpandEnabled: event.target.checked })}
            />
          </label>
          <label className="settings-toggle-row settings-panel">
            <span>
              <strong>{t('settings.showCompactSession')}</strong>
            </span>
            <input
              type="checkbox"
              disabled={!effectiveAppSettings.showIsland}
              checked={effectiveAppSettings.showSessionInCompact}
              onChange={(event) => updateAppSettingsDraft({ showSessionInCompact: event.target.checked })}
            />
          </label>
          <SettingSlider
            label={t('settings.autoCloseAfter')}
            disabled={!effectiveAppSettings.showIsland}
            min={3}
            max={30}
            value={effectiveAppSettings.autoCloseInterval}
            valueLabel={t('settings.seconds', { value: effectiveAppSettings.autoCloseInterval })}
            onChange={(value) => updateAppSettingsDraft({ autoCloseInterval: value })}
          />
          <SettingSlider
            label={t('settings.carouselInterval')}
            disabled={!effectiveAppSettings.showIsland || !effectiveAppSettings.showSessionInCompact}
            min={3}
            max={30}
            value={effectiveAppSettings.carouselInterval}
            valueLabel={t('settings.seconds', { value: effectiveAppSettings.carouselInterval })}
            onChange={(value) => updateAppSettingsDraft({ carouselInterval: value })}
          />
        </section>

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
                    ? (profile.userEmail || profile.defaultSyncTeamName || 'meee2 Online')
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
                {profile.defaultSyncTeamName && (
                  <div className="settings-meta-row">
                    <span>{t('settings.team')}</span>
                    <strong>{profile.defaultSyncTeamName}</strong>
                  </div>
                )}
                <label className="settings-toggle-row">
                  <span>
                    <strong>{t('settings.syncNewDefault')}</strong>
                    <small>{t('settings.syncNewDefaultHelp')}</small>
                  </span>
                  <input
                    type="checkbox"
                    checked={profile.defaultSyncEnabled}
                    onChange={(event) => void setDefaultSync(event.target.checked)}
                  />
                </label>
                {sessionSync.length > 0 && (
                  <div className="settings-session-sync-list">
                    {sessionSync.map((session) => (
                      <label key={session.sessionId} className="settings-session-sync-row">
                        <span>
                          <strong>{session.title}</strong>
                          <small>{session.pluginDisplayName}{session.project ? ` · ${session.project}` : ''}</small>
                        </span>
                        <input
                          type="checkbox"
                          checked={session.enabled}
                          onChange={(event) => void setSessionSync(session.sessionId, event.target.checked)}
                        />
                      </label>
                    ))}
                  </div>
                )}
              </div>
            )}
          </div>
        </section>

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
            <input type="checkbox" checked={boardGridEnabled} onChange={(event) => setBoardGridEnabled(event.target.checked)} />
          </label>
          <label className="settings-toggle-row settings-panel">
            <span>
              <strong>{t('settings.lockViewport')}</strong>
              <small>{t('settings.lockViewportHelp')}</small>
            </span>
            <input type="checkbox" checked={lockViewportOnSwitch} onChange={(event) => setLockViewportOnSwitch(event.target.checked)} />
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
                  setCanvasRecapIntervalMinutes(Number.isFinite(next) ? Math.max(0, Math.min(120, next)) : 0)
                }}
              />
              <small>{t('settings.minutes')}</small>
            </span>
          </label>
        </section>

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
              <button key={provider} type="button" className={spawnProvider === provider ? 'active' : ''} onClick={() => setSpawnProvider(provider)}>
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
          <button className="ghost" style={{ alignSelf: 'flex-start', fontSize: 11, padding: '2px 8px' }} onClick={() => setSpawnProvider(DEFAULT_SPAWN_PROVIDER)}>
            {t('common.reset')}
          </button>
        </section>

        <section className="settings-section">
          <div className="settings-section-header">
            <div>
              <div className="settings-section-title">{t('settings.assistantLlm')}</div>
              <div className="settings-section-caption">{t('settings.assistantLlmCaption')}</div>
            </div>
          </div>
          <div className="segment">
            {(['local', 'openai', 'anthropic'] as LlmProvider[]).map((p) => (
              <button key={p} className={p === llm.provider ? 'active' : ''} onClick={() => setProvider(p)} type="button">
                {providerLabel(p)}
              </button>
            ))}
          </div>
          {llm.provider !== 'local' && (
            <div className="col" style={{ gap: 6 }}>
              <SettingsTextInput label={t('settings.apiKey')} type="password" value={llm.apiKey} placeholder={llm.provider === 'openai' ? 'sk-...' : 'sk-ant-...'} onChange={(value) => setLlm((s) => ({ ...s, apiKey: value }))} />
              <SettingsTextInput label={`${t('settings.baseUrl')} (${t('settings.blankDefault')})`} value={llm.baseUrl} placeholder={DEFAULT_BASE_URL[llm.provider]} onChange={(value) => setLlm((s) => ({ ...s, baseUrl: value }))} />
              <SettingsTextInput label={`${t('settings.model')} (${t('settings.blankDefault')})`} value={llm.model} placeholder={DEFAULT_MODEL[llm.provider]} onChange={(value) => setLlm((s) => ({ ...s, model: value }))} />
            </div>
          )}
          {llm.provider === 'local' && (
            <div className="muted" style={{ fontSize: 11, lineHeight: 1.4 }}>
              {t('settings.localModeHelp')}
            </div>
          )}
        </section>

        {(devMode || effectiveAppSettings.devMode) && (
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
        )}
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
}: {
  label: string
  type?: string
  value: string
  placeholder?: string
  onChange: (value: string) => void
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

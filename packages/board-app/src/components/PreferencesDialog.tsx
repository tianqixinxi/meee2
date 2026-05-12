import { useCallback, useEffect, useState } from 'react'
import {
  DEFAULT_SPAWN_PROVIDER,
  loadBoardGridEnabled,
  loadSpawnProvider,
  saveBoardGridEnabled,
  saveSpawnProvider,
  spawnProviderLabel,
} from '../preferences'
import type { SpawnProvider } from '../types'
import type { SyncPolicy } from '../types'
import { SYNC_POLICY_OPTIONS } from '../workLayer'
import {
  readLlmSettings,
  writeLlmSettings,
  DEFAULT_BASE_URL,
  DEFAULT_MODEL,
  ALL_TOOLS,
  providerLabel,
  type LlmSettings,
  type LlmProvider,
  type ToolName,
} from '../lib/llmSettings'
import {
  disconnectMeee2Online,
  fetchFeishuConfig,
  fetchUserProfile,
  openMeee2OnlineConnect,
  openMeee2OnlineDashboard,
  testFeishuNotification,
  updateFeishuConfig,
  updateUserProfile,
  type FeishuConfig,
  type UserProfile,
} from '../api'
import { useI18n, type Locale } from '../i18n'
import { useTheme, type ThemeMode } from '../theme'

interface Props {
  onClose: () => void
  onSaved?: (provider: SpawnProvider) => void
  onToast?: (kind: 'info' | 'error' | 'success', text: string) => void
}

/**
 * 偏好设置面板。两个 section：
 *   1. 新 session 的默认 provider（Claude / Codex）。
 *   2. Global assistant 的 LLM 设置：provider / apiKey / baseUrl / model /
 *      enabled tools。默认 provider='local' 走 `claude -p`（不需要 key）。
 */
export function PreferencesDialog({ onClose, onSaved, onToast }: Props) {
  const { t, locale, setLocale } = useI18n()
  const { mode, setMode } = useTheme()
  const [spawnProvider, setSpawnProvider] = useState<SpawnProvider>(loadSpawnProvider)
  const [boardGridEnabled, setBoardGridEnabled] = useState(loadBoardGridEnabled)
  const [llm, setLlm] = useState<LlmSettings>(() => readLlmSettings())
  const [profile, setProfile] = useState<UserProfile | null>(null)
  const [feishu, setFeishu] = useState<FeishuConfig | null>(null)
  const [feishuGroupId, setFeishuGroupId] = useState('')
  const [feishuGroupName, setFeishuGroupName] = useState('')
  const notify = useCallback((kind: 'info' | 'error' | 'success', text: string) => {
    onToast?.(kind, text)
  }, [onToast])

  const loadProfile = useCallback(() => {
    fetchUserProfile()
      .then(setProfile)
      .catch(() => setProfile(null))
  }, [])

  const loadFeishu = useCallback(() => {
    fetchFeishuConfig()
      .then((result) => {
        setFeishu(result.feishu)
        setFeishuGroupId(result.feishu.defaultGroupId)
        setFeishuGroupName(result.feishu.defaultGroupName)
      })
      .catch(() => setFeishu(null))
  }, [])

  useEffect(() => {
    loadProfile()
    loadFeishu()
    window.addEventListener('focus', loadProfile)
    window.addEventListener('focus', loadFeishu)
    return () => {
      window.removeEventListener('focus', loadProfile)
      window.removeEventListener('focus', loadFeishu)
    }
  }, [loadFeishu, loadProfile])

  const save = () => {
    saveSpawnProvider(spawnProvider)
    saveBoardGridEnabled(boardGridEnabled)
    writeLlmSettings(llm)
    onSaved?.(spawnProvider)
    onClose()
  }

  const resetSpawn = () => setSpawnProvider(DEFAULT_SPAWN_PROVIDER)

  const setProvider = (p: LlmProvider) => {
    setLlm((s) => ({ ...s, provider: p }))
  }
  const setTool = (t: ToolName, on: boolean) => {
    setLlm((s) => ({ ...s, enabledTools: { ...s.enabledTools, [t]: on } }))
  }

  const setDefaultSync = async (enabled: boolean) => {
    try {
      setProfile(await updateUserProfile({ defaultSyncEnabled: enabled }))
    } catch (err) {
      notify('error', (err as Error).message || 'Failed to update sync setting')
    }
  }

  const setSessionSyncPolicy = async (sessionId: string, syncPolicy: SyncPolicy) => {
    try {
      setProfile(await updateUserProfile({ sessionSync: { sessionId, syncPolicy } }))
    } catch (err) {
      notify('error', (err as Error).message || 'Failed to update session sync')
    }
  }

  const saveFeishu = async () => {
    try {
      const result = await updateFeishuConfig({
        configured: true,
        defaultGroupId: feishuGroupId,
        defaultGroupName: feishuGroupName,
      })
      setFeishu(result.feishu)
      notify('success', 'Feishu delivery settings saved')
    } catch (err) {
      notify('error', (err as Error).message || 'Failed to save Feishu settings')
    }
  }

  const testFeishu = async () => {
    try {
      const result = await testFeishuNotification()
      loadFeishu()
      notify(result.ok ? 'success' : 'error', result.ok ? 'Feishu test sent' : result.error ?? 'Feishu test failed')
    } catch (err) {
      loadFeishu()
      notify('error', (err as Error).message || 'Feishu test failed')
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
    <div
      className="modal-backdrop"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div
        className="modal settings-modal"
        role="dialog"
        aria-modal="true"
        aria-label={t('settings.title')}
      >
        <div className="modal-header">
          <div className="modal-title">{t('settings.title')}</div>
          <div className="modal-subtitle">{t('settings.subtitle')}</div>
        </div>
        <div className="modal-body settings-body">
          <section className="settings-section">
            <div className="settings-section-header">
              <div>
                <div className="settings-section-title">{t('settings.appearance')}</div>
                <div className="settings-section-caption">{t('settings.appearanceCaption')}</div>
              </div>
            </div>
            <div className="settings-panel settings-appearance-panel">
              <label className="settings-field">
                <span>{t('settings.theme')}</span>
                <select value={mode} onChange={(event) => setMode(event.target.value as ThemeMode)}>
                  <option value="system">{t('settings.theme.system')}</option>
                  <option value="light">{t('settings.theme.light')}</option>
                  <option value="dark">{t('settings.theme.dark')}</option>
                </select>
              </label>
              <label className="settings-field">
                <span>{t('settings.language')}</span>
                <select value={locale} onChange={(event) => setLocale(event.target.value as Locale)}>
                  <option value="en">{t('settings.language.en')}</option>
                  <option value="zh-CN">{t('settings.language.zh-CN')}</option>
                </select>
              </label>
            </div>
          </section>

          {/* ── meee2 Online account + sync ───────────────────────── */}
          <section className="settings-section">
            <div className="settings-section-header">
              <div>
                <div className="settings-section-title">meee2 Online</div>
                <div className="settings-section-caption">Choose what local work is visible online.</div>
              </div>
            </div>
            <div className="settings-panel settings-account-panel">
              <div className="row" style={{ gap: 10 }}>
                <span className="settings-avatar" aria-hidden>
                  {profile?.userAvatarUrl ? (
                    <img src={profile.userAvatarUrl} alt="" />
                  ) : (
                    <span>{profile?.initials ?? '?'}</span>
                  )}
                </span>
                <div className="col" style={{ gap: 2, minWidth: 0, flex: 1 }}>
                  <strong className="truncate">
                    {profile?.connected ? profile.displayName : 'Not connected'}
                  </strong>
                  <span className="muted truncate" style={{ fontSize: 11 }}>
                    {profile?.connected
                      ? (profile.userEmail || profile.defaultSyncTeamName || 'meee2 Online')
                      : 'Connect to sync local sessions to meee2 Online'}
                  </span>
                </div>
                {profile?.connected ? (
                  <>
                    <button className="ghost" type="button" onClick={() => void openOnline()}>
                      Open meee2 Online
                    </button>
                    <button className="ghost" type="button" onClick={() => void logoutOnline()}>
                      Logout
                    </button>
                  </>
                ) : (
                  <button className="primary" type="button" onClick={() => void connectOnline()}>
                    Connect
                  </button>
                )}
              </div>
              {profile?.connected && (
                <div className="col" style={{ gap: 8, marginTop: 10 }}>
                  {profile.defaultSyncTeamName && (
                    <div className="settings-meta-row">
                      <span>Team</span>
                      <strong>{profile.defaultSyncTeamName}</strong>
                    </div>
                  )}
                  <label className="settings-toggle-row">
                    <span>
                      <strong>Sync new sessions by default</strong>
                      <small>Off means only explicitly enabled sessions sync.</small>
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
                          <select
                            value={session.syncPolicy}
                            onChange={(event) => void setSessionSyncPolicy(session.sessionId, event.target.value as SyncPolicy)}
                          >
                            {SYNC_POLICY_OPTIONS.map((option) => (
                              <option key={option.id} value={option.id}>{option.label}</option>
                            ))}
                          </select>
                        </label>
                      ))}
                    </div>
                  )}
                </div>
              )}
            </div>
          </section>

          {/* ── Feishu delivery ───────────────────────────────────── */}
          <section className="settings-section">
            <div className="settings-section-header">
              <div>
                <div className="settings-section-title">Feishu Delivery</div>
                <div className="settings-section-caption">Cards and docs are sent by meee2 Online using allowed sync payloads.</div>
              </div>
            </div>
            <div className="settings-panel">
              <div className="settings-meta-row">
                <span>Status</span>
                <strong>{feishu?.deliveryStatus ?? 'not configured'}</strong>
              </div>
              {feishu?.lastError && (
                <div className="settings-meta-row">
                  <span>Last error</span>
                  <strong>{feishu.lastError}</strong>
                </div>
              )}
              <label className="settings-field">
                <span>Default group ID</span>
                <input value={feishuGroupId} onChange={(event) => setFeishuGroupId(event.target.value)} placeholder="oc_xxx or chat id from meee2 Online" />
              </label>
              <label className="settings-field">
                <span>Default group name</span>
                <input value={feishuGroupName} onChange={(event) => setFeishuGroupName(event.target.value)} placeholder="AI work radar" />
              </label>
              <div className="row" style={{ gap: 8, marginTop: 10 }}>
                <button className="ghost" type="button" onClick={() => void saveFeishu()}>
                  Save Feishu settings
                </button>
                <button className="ghost" type="button" onClick={() => void testFeishu()} disabled={!profile?.connected}>
                  Test notification
                </button>
              </div>
            </div>
          </section>

          {/* ── Canvas display ─────────────────────────────────────── */}
          <section className="settings-section">
            <div className="settings-section-header">
              <div>
                <div className="settings-section-title">Session Map Display</div>
                <div className="settings-section-caption">Visual guides only; saved card positions stay unchanged.</div>
              </div>
            </div>
            <label className="settings-toggle-row settings-panel">
              <span>
                <strong>Show grid</strong>
                <small>Only changes the canvas background guide; session positions stay unchanged.</small>
              </span>
              <input
                type="checkbox"
                checked={boardGridEnabled}
                onChange={(event) => setBoardGridEnabled(event.target.checked)}
              />
            </label>
          </section>

          {/* ── Spawn command ─────────────────────────────────────── */}
          <section className="settings-section">
            <div className="settings-section-header">
              <div>
                <div className="settings-section-title">Default Spawn Provider</div>
                <div className="settings-section-caption">Used by assistant-created local sessions.</div>
              </div>
            </div>
            <div className="segment">
              {(['claude', 'codex'] as SpawnProvider[]).map((provider) => (
                <button
                  key={provider}
                  type="button"
                  className={spawnProvider === provider ? 'active' : ''}
                  onClick={() => setSpawnProvider(provider)}
                >
                  {spawnProviderLabel(provider)}
                </button>
              ))}
            </div>
            <div className="muted" style={{ fontSize: 11, lineHeight: 1.4 }}>
              Global sessions start in the active canvas workspace with the selected local CLI.
            </div>
            <button
              className="ghost"
              style={{ alignSelf: 'flex-start', fontSize: 11, padding: '2px 8px' }}
              onClick={resetSpawn}
            >
              Reset to default
            </button>
          </section>

          {/* ── LLM provider for the global assistant ─────────────── */}
          <section className="settings-section">
            <div className="settings-section-header">
              <div>
                <div className="settings-section-title">Assistant LLM</div>
                <div className="settings-section-caption">Controls the board assistant and enabled tools.</div>
              </div>
            </div>

            {/* Provider segmented control */}
            <div className="segment">
              {(['local', 'openai', 'anthropic'] as LlmProvider[]).map((p) => (
                <button
                  key={p}
                  className={p === llm.provider ? 'active' : ''}
                  onClick={() => setProvider(p)}
                  type="button"
                >
                  {providerLabel(p)}
                </button>
              ))}
            </div>

            {/* Hosted-provider fields. Skipped for local (no key/baseUrl/model). */}
            {llm.provider !== 'local' && (
              <div className="col" style={{ gap: 6 }}>
                <div className="col" style={{ gap: 2 }}>
                  <label className="muted" style={{ fontSize: 11 }}>API key</label>
                  <input
                    className="mono"
                    type="password"
                    value={llm.apiKey}
                    placeholder={llm.provider === 'openai' ? 'sk-…' : 'sk-ant-…'}
                    onChange={(e) => setLlm((s) => ({ ...s, apiKey: e.target.value }))}
                    autoCapitalize="off"
                    autoCorrect="off"
                    spellCheck={false}
                  />
                </div>
                <div className="col" style={{ gap: 2 }}>
                  <label className="muted" style={{ fontSize: 11 }}>
                    Base URL <span style={{ opacity: 0.6 }}>(blank = default)</span>
                  </label>
                  <input
                    className="mono"
                    value={llm.baseUrl}
                    placeholder={DEFAULT_BASE_URL[llm.provider]}
                    onChange={(e) => setLlm((s) => ({ ...s, baseUrl: e.target.value }))}
                    autoCapitalize="off"
                    autoCorrect="off"
                    spellCheck={false}
                  />
                </div>
                <div className="col" style={{ gap: 2 }}>
                  <label className="muted" style={{ fontSize: 11 }}>
                    Model <span style={{ opacity: 0.6 }}>(blank = default)</span>
                  </label>
                  <input
                    className="mono"
                    value={llm.model}
                    placeholder={DEFAULT_MODEL[llm.provider]}
                    onChange={(e) => setLlm((s) => ({ ...s, model: e.target.value }))}
                    autoCapitalize="off"
                    autoCorrect="off"
                    spellCheck={false}
                  />
                </div>
              </div>
            )}

            {llm.provider === 'local' && (
              <div className="muted" style={{ fontSize: 11, lineHeight: 1.4 }}>
                Local mode shells out to <code>claude -p</code> using your existing
                ~/.claude OAuth — no API key needed. Streams output via the same
                tool-use loop as hosted providers.
              </div>
            )}

            {/* Tools */}
            <div className="col" style={{ gap: 4, marginTop: 4 }}>
              <label className="muted" style={{ fontSize: 11 }}>Enabled tools</label>
              <div className="col" style={{ gap: 2 }}>
                {ALL_TOOLS.map((t) => (
                  <label key={t} className="row" style={{ gap: 8, fontSize: 12, cursor: 'pointer' }}>
                    <input
                      type="checkbox"
                      checked={llm.enabledTools[t]}
                      onChange={(e) => setTool(t, e.target.checked)}
                      style={{ width: 'auto' }}
                    />
                    <span className="mono">{t}</span>
                    <span className="muted" style={{ fontSize: 11 }}>
                      {toolDesc(t)}
                    </span>
                  </label>
                ))}
              </div>
            </div>
          </section>
        </div>
        <div className="modal-footer">
          <span style={{ flex: 1 }} />
          <button className="ghost" onClick={onClose}>{t('action.cancel')}</button>
          <button className="primary" onClick={save}>{t('action.save')}</button>
        </div>
      </div>
    </div>
  )
}

function toolDesc(t: ToolName): string {
  switch (t) {
    case 'get_canvas_context': return 'read the current canvas layout'
    case 'get_session_list': return 'list sessions on the board'
    case 'get_session_info': return 'fetch a session’s state + transcript'
    case 'get_session_transcript': return 'read recent session transcript'
    case 'propose_canvas_patch': return 'prepare Apply-only canvas changes'
    case 'create_session': return 'spawn a new claude session'
    case 'create_coordinator_session': return 'spawn a coordinator for selected sessions'
    case 'get_coordination_state': return 'read coordinator groups and digests'
    case 'update_group_digest': return 'maintain compact coordinator state'
    case 'pause_coordination': return 'pause automatic coordinator wakes'
    case 'resume_coordination': return 'resume automatic coordinator wakes'
    case 'ask_coordinator': return 'wake coordinator with compact context'
  }
}

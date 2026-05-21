import { useCallback, useEffect, useState } from 'react'
import { CheckCircle2, CircleAlert } from 'lucide-react'
import {
  DEFAULT_SPAWN_PROVIDER,
  loadBoardGridEnabled,
  loadSpawnProvider,
  saveBoardGridEnabled,
  saveSpawnProvider,
  spawnProviderLabel,
} from '../preferences'
import type { Meee2AgentRuntimeStatus, SpawnProvider } from '../types'
import {
  readLlmSettings,
  writeLlmSettings,
  DEFAULT_BASE_URL,
  DEFAULT_MODEL,
  providerLabel,
  type LlmSettings,
  type LlmProvider,
} from '../lib/llmSettings'
import {
  disconnectMeee2Online,
  fetchUserProfile,
  openMeee2OnlineConnect,
  openMeee2OnlineDashboard,
  updateUserProfile,
  type UserProfile,
} from '../api'

interface Props {
  onClose: () => void
  onSaved?: (provider: SpawnProvider) => void
  onToast?: (kind: 'info' | 'error' | 'success', text: string) => void
  agentRuntimeStatus?: Meee2AgentRuntimeStatus | null
  onOpenAgentRuntime?: (target: SpawnProvider) => void
  onRefreshAgentRuntime?: () => void
}

/**
 * 偏好设置面板。两个 section：
 *   1. 新 session 的默认 provider（Claude / Codex）。
 *   2. Global assistant 的 LLM 设置：provider / apiKey / baseUrl / model /
 *      enabled tools。默认 provider='local' 走本地 Claude 稳定 session（不需要 key）。
 */
export function PreferencesDialog({
  onClose,
  onSaved,
  onToast,
  agentRuntimeStatus = null,
  onOpenAgentRuntime,
  onRefreshAgentRuntime,
}: Props) {
  const [spawnProvider, setSpawnProvider] = useState<SpawnProvider>(loadSpawnProvider)
  const [boardGridEnabled, setBoardGridEnabled] = useState(loadBoardGridEnabled)
  const [llm, setLlm] = useState<LlmSettings>(() => readLlmSettings())
  const [profile, setProfile] = useState<UserProfile | null>(null)
  const notify = useCallback((kind: 'info' | 'error' | 'success', text: string) => {
    onToast?.(kind, text)
  }, [onToast])

  const loadProfile = useCallback(() => {
    fetchUserProfile()
      .then(setProfile)
      .catch(() => setProfile(null))
  }, [])

  useEffect(() => {
    loadProfile()
    window.addEventListener('focus', loadProfile)
    return () => window.removeEventListener('focus', loadProfile)
  }, [loadProfile])

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
        aria-label="Board Settings"
      >
        <div className="modal-header">
          <div className="modal-title">Board Settings</div>
          <div className="modal-subtitle">Canvas, sync, and assistant behavior for this board.</div>
        </div>
        <div className="modal-body settings-body">
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

          {/* ── Canvas display ─────────────────────────────────────── */}
          <section className="settings-section">
            <div className="settings-section-header">
              <div>
                <div className="settings-section-title">Canvas Display</div>
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

          {/* ── Agent runtime ─────────────────────────────────────── */}
          <section className="settings-section">
            <div className="settings-section-header">
              <div>
                <div className="settings-section-title">Agent Runtime</div>
                <div className="settings-section-caption">Default local agent for planner sessions and global spawns.</div>
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
            <RuntimeStatusPanel
              provider={spawnProvider}
              status={agentRuntimeStatus}
              onSetUp={() => onOpenAgentRuntime?.(spawnProvider)}
              onRefresh={onRefreshAgentRuntime}
            />
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
                <div className="settings-section-caption">Controls the meee2 AI chat model.</div>
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
                Local mode shells out to Claude Code using your existing
                ~/.claude OAuth and a stable local session. Streams output via
                the same tool-use loop as hosted providers.
              </div>
            )}
          </section>
        </div>
        <div className="modal-footer">
          <span style={{ flex: 1 }} />
          <button className="ghost" onClick={onClose}>Cancel</button>
          <button className="primary" onClick={save}>Save</button>
        </div>
      </div>
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
        <span>
          {runtime?.detail
            ?? (status ? 'Runtime status is unavailable.' : 'Checking runtime status...')}
        </span>
        {runtime && (
          <small>CLI {runtime.cliAvailable ? 'found' : 'missing'} · App {runtime.appAvailable ? 'found' : 'missing'}</small>
        )}
      </div>
      <div className="settings-runtime-panel__actions">
        <button type="button" className="ghost" onClick={onRefresh}>Check</button>
        <button type="button" className="primary" disabled={!available} onClick={onSetUp}>
          {ready ? 'Manage' : 'Set up'}
        </button>
      </div>
    </div>
  )
}

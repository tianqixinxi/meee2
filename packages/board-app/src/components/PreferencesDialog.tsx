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
}

/**
 * 偏好设置面板。两个 section：
 *   1. 新 session 的默认 provider（Claude / Codex）。
 *   2. Global assistant 的 LLM 设置：provider / apiKey / baseUrl / model /
 *      enabled tools。默认 provider='local' 走 `claude -p`（不需要 key）。
 */
export function PreferencesDialog({ onClose, onSaved, onToast }: Props) {
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
              Global sessions and planner nodes without an explicit Codex/Claude runtime start in the active canvas workspace with this local CLI.
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
          <button className="ghost" onClick={onClose}>Cancel</button>
          <button className="primary" onClick={save}>Save</button>
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
    case 'list_channels': return 'list A2A channels'
    case 'get_channel_messages': return 'read channel messages'
    case 'propose_canvas_patch': return 'prepare Apply-only canvas changes'
    case 'create_session': return 'spawn a new claude session'
    case 'create_coordinator_session': return 'spawn a coordinator for selected sessions'
    case 'get_coordination_state': return 'read coordinator groups and digests'
    case 'send_to_session': return 'route a message to one session'
    case 'broadcast_to_members': return 'route messages to group members'
    case 'update_group_digest': return 'maintain compact coordinator state'
    case 'pause_coordination': return 'pause automatic coordinator wakes'
    case 'resume_coordination': return 'resume automatic coordinator wakes'
    case 'ask_coordinator': return 'wake coordinator with compact context'
  }
}

import { useEffect, useRef, useState } from 'react'
import {
  loadDefaultSpawnCommand,
  saveDefaultSpawnCommand,
  DEFAULT_SPAWN_COMMAND,
} from '../preferences'
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

interface Props {
  onClose: () => void
  onSaved?: (cmd: string) => void
}

/**
 * 偏好设置面板。两个 section：
 *   1. 新 session 的默认启动命令（Ghostty 里跑啥）。
 *   2. Global assistant 的 LLM 设置：provider / apiKey / baseUrl / model /
 *      enabled tools。默认 provider='local' 走 `claude -p`（不需要 key）。
 */
export function PreferencesDialog({ onClose, onSaved }: Props) {
  const [command, setCommand] = useState<string>(loadDefaultSpawnCommand)
  const [llm, setLlm] = useState<LlmSettings>(() => readLlmSettings())
  const inputRef = useRef<HTMLInputElement | null>(null)

  useEffect(() => {
    inputRef.current?.focus()
    inputRef.current?.select()
  }, [])

  const save = () => {
    saveDefaultSpawnCommand(command)
    writeLlmSettings(llm)
    onSaved?.(command.trim() || DEFAULT_SPAWN_COMMAND)
    onClose()
  }

  const resetSpawn = () => setCommand(DEFAULT_SPAWN_COMMAND)

  const setProvider = (p: LlmProvider) => {
    setLlm((s) => ({ ...s, provider: p }))
  }
  const setTool = (t: ToolName, on: boolean) => {
    setLlm((s) => ({ ...s, enabledTools: { ...s.enabledTools, [t]: on } }))
  }

  return (
    <div
      className="modal-backdrop"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div
        className="modal"
        role="dialog"
        aria-modal="true"
        aria-label="Preferences"
        style={{ width: 540, maxWidth: '92vw' }}
      >
        <div className="modal-header">Preferences</div>
        <div className="modal-body col" style={{ gap: 16 }}>
          {/* ── Spawn command ─────────────────────────────────────── */}
          <div className="col" style={{ gap: 4 }}>
            <label className="muted" style={{ fontSize: 11 }}>
              Default command for new sessions
            </label>
            <input
              ref={inputRef}
              className="mono"
              value={command}
              onChange={(e) => setCommand(e.target.value)}
              placeholder={DEFAULT_SPAWN_COMMAND}
              spellCheck={false}
              autoCapitalize="off"
              autoCorrect="off"
            />
            <div className="muted" style={{ fontSize: 11, lineHeight: 1.4 }}>
              runs in the new Ghostty tab after it opens in the chosen cwd.
              examples: <code>claude</code> · <code>claude --model opus</code> ·{' '}
              <code>aider --model gpt-4o</code>
            </div>
            <button
              className="ghost"
              style={{ alignSelf: 'flex-start', fontSize: 11, padding: '2px 8px' }}
              onClick={resetSpawn}
            >
              Reset to default
            </button>
          </div>

          {/* ── LLM provider for the global assistant ─────────────── */}
          <div className="col" style={{ gap: 8 }}>
            <label className="muted" style={{ fontSize: 11 }}>
              Assistant LLM
            </label>

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
          </div>
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
    case 'get_session_list': return 'list sessions on the board'
    case 'get_session_info': return 'fetch a session’s state + transcript'
    case 'create_session': return 'spawn a new claude session'
  }
}

import { useEffect, useRef, useState } from 'react'
import {
  loadDefaultSpawnCommand,
  saveDefaultSpawnCommand,
  DEFAULT_SPAWN_COMMAND,
} from '../preferences'

interface Props {
  onClose: () => void
  onSaved?: (cmd: string) => void
}

/**
 * 最小偏好设置面板。当前只有一个条目：**新 session 的默认启动命令**。
 *
 * 为什么不做 profile 列表：大多数人就是想改一下默认 `--model` / 用 wrapper
 * 脚本，profile CRUD 过度设计；未来真需要多条再扩。
 */
export function PreferencesDialog({ onClose, onSaved }: Props) {
  const [command, setCommand] = useState<string>(loadDefaultSpawnCommand)
  const [busy, setBusy] = useState(false)
  const inputRef = useRef<HTMLInputElement | null>(null)

  useEffect(() => {
    inputRef.current?.focus()
    inputRef.current?.select()
  }, [])

  const save = () => {
    setBusy(true)
    saveDefaultSpawnCommand(command)
    onSaved?.(command.trim() || DEFAULT_SPAWN_COMMAND)
    onClose()
  }

  const reset = () => {
    setCommand(DEFAULT_SPAWN_COMMAND)
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
        style={{ width: 480, maxWidth: '90vw' }}
      >
        <div className="modal-header">Preferences</div>
        <div className="modal-body col" style={{ gap: 12 }}>
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
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !busy) {
                  e.preventDefault()
                  save()
                }
                if (e.key === 'Escape') {
                  e.preventDefault()
                  onClose()
                }
              }}
            />
            <div className="muted" style={{ fontSize: 11, lineHeight: 1.4 }}>
              runs in the new Ghostty tab after it opens in the chosen cwd.
              examples:
              <br />
              <code>claude</code> · <code>claude --model opus</code> · <code>aider --model gpt-4o</code> · <code>my-wrapper.sh</code> · <code>zsh</code>
              <br />
              applies to both "New Claude session…" and "Ask AI to spawn…".
            </div>
          </div>
        </div>
        <div className="modal-footer">
          <button className="ghost" onClick={reset}>Reset to default</button>
          <span style={{ flex: 1 }} />
          <button className="ghost" onClick={onClose} disabled={busy}>Cancel</button>
          <button className="primary" onClick={save} disabled={busy}>Save</button>
        </div>
      </div>
    </div>
  )
}

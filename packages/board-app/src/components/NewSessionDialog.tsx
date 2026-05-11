import { useEffect, useRef, useState } from 'react'
import { spawnSession } from '../api'
import {
  commandForSpawnProvider,
  loadSpawnProvider,
  saveSpawnProvider,
  spawnProviderLabel,
} from '../preferences'
import type { SpawnProvider } from '../types'

interface Props {
  onClose: () => void
  onSpawned: (cwd: string) => void
  onError: (msg: string) => void
  /** 预填的 cwd —— 从 sidebar 项目组的 + 按钮触发时传入项目目录 */
  defaultCwd?: string
}

/**
 * "New session" 对话框。
 *
 * 用户给出目录（支持 ~、相对路径会被 meee2 daemon 规范化），可选勾选"目录
 * 不存在就 mkdir"。点 Spawn 会让 daemon 启一个新 Ghostty 窗口、落在 cwd
 * 并自动跑用户选择的 provider CLI。
 */
export function NewSessionDialog({ onClose, onSpawned, onError, defaultCwd }: Props) {
  const [cwd, setCwd] = useState(defaultCwd || '~/')
  const [createIfMissing, setCreateIfMissing] = useState(false)
  const [provider, setProvider] = useState<SpawnProvider>(loadSpawnProvider)
  const [busy, setBusy] = useState(false)
  const [localErr, setLocalErr] = useState<string | null>(null)
  const inputRef = useRef<HTMLInputElement | null>(null)

  useEffect(() => {
    inputRef.current?.focus()
    inputRef.current?.select()
  }, [])

  const submit = async () => {
    const v = cwd.trim()
    if (!v) { setLocalErr('Folder path required'); return }
    setBusy(true)
    setLocalErr(null)
    try {
      const finalCmd = commandForSpawnProvider(provider)
      await spawnSession({
        cwd: v,
        command: finalCmd,
        createIfMissing,
      })
      saveSpawnProvider(provider)
      onSpawned(v)
    } catch (e) {
      const msg = (e as Error).message || 'Spawn failed'
      setLocalErr(msg)
      onError(msg)
      setBusy(false)
    }
  }

  return (
    <div
      className="modal-backdrop"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div className="modal" role="dialog" aria-modal="true" aria-label="New session">
        <div className="modal-header">New session</div>
        <div className="modal-body col" style={{ gap: 12 }}>
          <div className="col" style={{ gap: 4 }}>
            <label className="muted" style={{ fontSize: 11 }}>Folder</label>
            <input
              ref={inputRef}
              value={cwd}
              onChange={(e) => setCwd(e.target.value)}
              placeholder="~/projects/my-app  or  /abs/path"
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !busy) {
                  e.preventDefault()
                  submit()
                }
                if (e.key === 'Escape') {
                  e.preventDefault()
                  onClose()
                }
              }}
              spellCheck={false}
              autoCapitalize="off"
              autoCorrect="off"
            />
            <label className="row" style={{ gap: 6, fontSize: 12 }}>
              <input
                type="checkbox"
                checked={createIfMissing}
                onChange={(e) => setCreateIfMissing(e.target.checked)}
              />
              Create folder if missing (mkdir -p)
            </label>
          </div>
          <div className="col" style={{ gap: 4 }}>
            <label className="muted" style={{ fontSize: 11 }}>Provider</label>
            <div className="segment">
              {(['claude', 'codex'] as SpawnProvider[]).map((item) => (
                <button
                  key={item}
                  type="button"
                  className={provider === item ? 'active' : ''}
                  onClick={() => setProvider(item)}
                >
                  {spawnProviderLabel(item)}
                </button>
              ))}
            </div>
          </div>
          {localErr && <div className="inline-error">{localErr}</div>}
        </div>
        <div className="modal-footer">
          <button className="ghost" onClick={onClose} disabled={busy}>Cancel</button>
          <button
            className="primary"
            onClick={submit}
            disabled={busy || !cwd.trim()}
          >
            {busy ? 'Spawning…' : 'Spawn'}
          </button>
        </div>
      </div>
    </div>
  )
}

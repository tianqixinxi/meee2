import { useEffect, useMemo, useRef, useState } from 'react'
import type { BoardState, Selection, Session } from '../types'
import { injectToSession } from '../api'
import { loadSpawnProvider, spawnProviderLabel } from '../preferences'
import { useToast } from '../App'
import { Zap, Inbox, FolderOpen, Diamond } from 'lucide-react'

interface Props {
  state: BoardState | null
  selection: Selection
  connected: boolean
  unreadCount: number
  onNewSession: () => Promise<void> | void
  onAskAndSpawn: () => void
  onPreferences: () => void
  onNewChannel: () => void
}

/// 与 Sidebar 的 projectGroupKey 同一规则；保持单独副本避免相互 import。
function deriveProjectName(project: string | null | undefined): string {
  const raw = (project ?? '').replace(/\/+$/, '')
  if (!raw) return ''
  const wtIdx = raw.indexOf('/.claude/worktrees/')
  if (wtIdx > 0) {
    const before = raw.slice(0, wtIdx)
    const slash = before.lastIndexOf('/')
    const base = slash >= 0 ? before.slice(slash + 1) : before
    if (base) return base
  }
  const idx = raw.lastIndexOf('/')
  return idx >= 0 ? raw.slice(idx + 1) : raw
}

/// 借鉴 Claude Code app 底栏的"功能展示型"chatbox：
///   row 1 — meta chips（连接状态 / sessions 计数 / inbox / 当前 cwd / 模型）
///   row 2 — 输入区（选中 session 时直发；没选时按 Enter 走 quick-spawn）
///   row 3 — 操作按钮（new session / ask AI / new channel / preferences）
/// 始终可见，让用户一眼看清当前 board 状态 + 主要操作路径。
export function CommandBar({
  state,
  selection,
  connected,
  unreadCount,
  onNewSession,
  onAskAndSpawn,
  onPreferences,
  onNewChannel,
}: Props) {
  const toast = useToast()
  const [value, setValue] = useState('')
  const [sending, setSending] = useState(false)
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)

  const selectedSession: Session | null = useMemo(() => {
    if (!state || selection.kind !== 'session') return null
    return state.sessions.find((s) => s.id === selection.sessionId) ?? null
  }, [state, selection])

  const sessions = state?.sessions ?? []
  const sessionCount = sessions.length
  const totalInbox = sessions.reduce((acc, s) => acc + s.inboxPending, 0)
  const distinctProjects = useMemo(() => {
    const set = new Set<string>()
    for (const s of sessions) {
      const k = deriveProjectName(s.project)
      if (k) set.add(k)
    }
    return [...set]
  }, [sessions])

  // Status pill content - depends on whether a session is selected
  const cwdLabel = useMemo(() => {
    if (selectedSession) {
      return deriveProjectName(selectedSession.project) || 'unknown'
    }
    if (distinctProjects.length === 1) return distinctProjects[0]
    if (distinctProjects.length > 1) return `${distinctProjects.length} projects`
    return 'no project'
  }, [selectedSession, distinctProjects])

  const spawnProvider = loadSpawnProvider()

  const handleSubmit = async () => {
    const body = value.trim()
    if (!body) return
    setSending(true)
    try {
      if (selectedSession) {
        await injectToSession(selectedSession.id, body)
        toast.push('success', `Sent to ${selectedSession.title}`)
        setValue('')
      } else {
        await onNewSession()
        setValue('')
      }
    } catch (e) {
      toast.push('error', (e as Error).message || 'Failed to send')
    } finally {
      setSending(false)
    }
  }

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    const composing = (e.nativeEvent as KeyboardEvent).isComposing
    if (e.key === 'Enter' && !e.shiftKey && !composing) {
      e.preventDefault()
      void handleSubmit()
    }
  }

  // 选中 session 切换时把焦点挪走（避免误注入）
  useEffect(() => {
    setValue('')
  }, [selection])

  const placeholder = selectedSession
    ? `Send to ${selectedSession.title}…  (Enter to send, Shift+Enter newline)`
    : 'Spawn a new session here…  (Enter to spawn with default command)'

  return (
    <div className="command-bar" role="region" aria-label="Command bar">
      <div className="command-bar__chips">
        <span className={'cb-chip cb-chip--status' + (connected ? ' is-on' : ' is-off')}>
          <span className="cb-dot" />
          {connected ? 'live' : 'offline'}
        </span>
        <span className="cb-chip" title="Sessions on the board">
          <span className="cb-chip__glyph"><Zap size={11} aria-hidden /></span>
          {sessionCount} session{sessionCount === 1 ? '' : 's'}
        </span>
        {totalInbox > 0 && (
          <span className="cb-chip cb-chip--warn" title="Pending inbox messages">
            <span className="cb-chip__glyph"><Inbox size={11} aria-hidden /></span>
            {totalInbox} pending
          </span>
        )}
        {unreadCount > 0 && (
          <span className="cb-chip cb-chip--accent" title="Sessions with unread updates">
            <span className="cb-chip__glyph">●</span>
            {unreadCount} unread
          </span>
        )}
        <span className="cb-chip" title="Working directory context">
          <span className="cb-chip__glyph"><FolderOpen size={11} aria-hidden /></span>
          {cwdLabel}
        </span>
        {selectedSession && (
          <span className="cb-chip cb-chip--accent" title={selectedSession.id}>
            <span
              className="color-dot"
              style={{ background: selectedSession.pluginColor, width: 8, height: 8 }}
            />
            {selectedSession.title}
          </span>
        )}
        <span className="cb-spacer" />
        <span className="cb-chip cb-chip--ghost" title="Default spawn command">
          <span className="cb-chip__glyph"><Diamond size={11} aria-hidden /></span>
          {spawnProviderLabel(spawnProvider)}
        </span>
      </div>
      <div className="command-bar__input-row">
        <textarea
          ref={textareaRef}
          className="command-bar__textarea"
          value={value}
          placeholder={placeholder}
          disabled={sending}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={handleKeyDown}
          rows={1}
        />
        <button
          className="command-bar__send"
          onClick={() => void handleSubmit()}
          disabled={sending || !value.trim()}
          title={selectedSession ? 'Send to session' : 'Spawn new session'}
        >
          {sending ? '…' : selectedSession ? 'Send' : 'Spawn'}
        </button>
      </div>
      <div className="command-bar__actions">
        <button className="cb-action" onClick={onNewSession} title="New session">
          <span className="cb-action__glyph">+</span>
          New session
        </button>
        <button className="cb-action" onClick={onAskAndSpawn} title="Ask AI to suggest a session">
          <span className="cb-action__glyph">✦</span>
          Ask AI
        </button>
        <button className="cb-action" onClick={onNewChannel} title="Create a new channel">
          <span className="cb-action__glyph">#</span>
          New channel
        </button>
        <span className="cb-spacer" />
        <button
          className="cb-action cb-action--ghost"
          onClick={onPreferences}
          title="Preferences"
        >
          <span className="cb-action__glyph">⚙</span>
          Prefs
        </button>
      </div>
    </div>
  )
}

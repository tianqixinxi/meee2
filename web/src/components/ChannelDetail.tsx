import { useEffect, useMemo, useState } from 'react'
import type { BoardState, Channel, Message, Mode } from '../types'
import {
  addMember,
  deleteChannel,
  deliverMessage,
  dropMessage,
  listChannelMessages,
  removeMember,
  sendMessage,
  setChannelMode,
} from '../api'
import { useToast } from '../App'

interface Props {
  state: BoardState
  channelName: string
}

const MODES: Mode[] = ['auto', 'intercept', 'paused']

export default function ChannelDetail({ state, channelName }: Props) {
  const toast = useToast()
  const channel = state.channels.find((c) => c.name === channelName)
  const [messages, setMessages] = useState<Message[]>([])
  const [msgError, setMsgError] = useState<string | null>(null)
  const [opError, setOpError] = useState<string | null>(null)
  const [addingMember, setAddingMember] = useState(false)
  const [newAlias, setNewAlias] = useState('')
  const [newSessionId, setNewSessionId] = useState('')
  // 默认发送方 = operator（合成 alias，后端当 injectedByHuman 的人类发送方
  // 放行）。为什么不是 member 列表第一个：channel 里只有一个成员时，从那
  // 个成员发广播会把自己排除，结果 0 个接收方、消息被标成 "delivered=[]"
  // 的死状态——用户以为发出去了其实没人收到。
  const [sendFrom, setSendFrom] = useState<string>('operator')
  const [sendTo, setSendTo] = useState<string>('*')
  const [sendContent, setSendContent] = useState('')

  // Load recent messages on channel change / state version.
  useEffect(() => {
    let cancelled = false
    async function load() {
      try {
        const msgs = await listChannelMessages(channelName, { limit: 20 })
        if (!cancelled) setMessages(msgs)
        if (!cancelled) setMsgError(null)
      } catch (e) {
        if (!cancelled) setMsgError((e as Error).message)
      }
    }
    void load()
    return () => {
      cancelled = true
    }
    // rely on state as a trigger: when backend updates, state prop changes
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [channelName, state])

  // 默认把 sendTo 压到"第一个真正可达的 member"。当 from=operator 时
  // operator 不是 member，`*` 会广播给所有 member，单 member channel 也
  // 不会出现空接收方；当 from 被切成某 member 时，对方 member 才是正确默认。
  useEffect(() => {
    if (!channel) return
    if (sendTo === '*') {
      // 只在当前 from 选择导致 * 会变空时才自动换
      if (sendFrom !== 'operator') {
        const others = channel.members.filter((m) => m.alias !== sendFrom)
        if (others.length === 0 && channel.members.length > 0) {
          // 让用户 fallback 到唯一的那个 member
          setSendTo(channel.members[0].alias)
        }
      }
    }
    // 把无效的 sendFrom（channel 里找不到，且不是 operator）降到 operator
    if (
      sendFrom !== 'operator' &&
      !channel.members.some((m) => m.alias === sendFrom)
    ) {
      setSendFrom('operator')
    }
  }, [channel, sendFrom, sendTo])

  const availableSessions = useMemo(() => {
    if (!channel) return []
    const inChannel = new Set(channel.members.map((m) => m.sessionId))
    return state.sessions.filter((s) => !inChannel.has(s.id))
  }, [state, channel])

  if (!channel) {
    return <div className="muted">Channel not found.</div>
  }

  async function wrap<T>(fn: () => Promise<T>, errSink = setOpError) {
    errSink(null)
    try {
      return await fn()
    } catch (e) {
      const msg = (e as Error).message
      errSink(msg)
      toast.push('error', msg)
      return null
    }
  }

  const changeMode = async (mode: Mode) => {
    await wrap(() => setChannelMode(channel.name, mode))
  }

  const removeMemberClick = async (alias: string) => {
    await wrap(() => removeMember(channel.name, alias))
  }

  const addMemberClick = async () => {
    if (!newAlias.trim() || !newSessionId) return
    await wrap(() =>
      addMember(channel.name, newAlias.trim(), newSessionId),
    )
    setNewAlias('')
    setNewSessionId('')
    setAddingMember(false)
  }

  const handleSend = async () => {
    if (!sendFrom || !sendContent.trim()) return
    const r = await wrap(() =>
      sendMessage({
        channel: channel.name,
        fromAlias: sendFrom,
        toAlias: sendTo,
        content: sendContent,
        injectedByHuman: true,
      }),
    )
    if (r) {
      setSendContent('')
      toast.push('success', 'Message sent.')
    }
  }

  const handleDelete = async () => {
    if (!confirm(`Delete channel "${channel.name}"? This cannot be undone.`)) {
      return
    }
    await wrap(() => deleteChannel(channel.name))
    toast.push('info', `Channel "${channel.name}" deleted.`)
  }

  const handleMsgAction = async (
    msg: Message,
    action: 'deliver' | 'drop',
  ) => {
    await wrap(() =>
      action === 'deliver' ? deliverMessage(msg.id) : dropMessage(msg.id),
    )
  }

  const sessionTitleFor = (sid: string): string => {
    return state.sessions.find((s) => s.id === sid)?.title ?? sid.slice(0, 8)
  }

  return (
    <div className="col" style={{ gap: 12 }}>
      <div>
        <div style={{ fontSize: 15, fontWeight: 600 }}>#{channel.name}</div>
        {channel.description && (
          <div className="muted" style={{ marginTop: 4 }}>
            {channel.description}
          </div>
        )}
        <div className="muted mono" style={{ marginTop: 4 }}>
          {channel.members.length} member(s) · {channel.pendingCount} pending
        </div>
      </div>

      <div className="section">
        <h4>Mode</h4>
        <div className="segment">
          {MODES.map((m) => (
            <button
              key={m}
              className={m === channel.mode ? 'active' : ''}
              onClick={() => changeMode(m)}
            >
              {m}
            </button>
          ))}
        </div>
      </div>

      <div className="section">
        <h4>Members</h4>
        {channel.members.map((m) => (
          <div key={m.alias} className="row space" style={{ marginBottom: 4 }}>
            <div>
              <div>
                <span className="badge">{m.alias}</span>{' '}
                <span>{sessionTitleFor(m.sessionId)}</span>
              </div>
              <div className="mono muted">{m.sessionId.slice(0, 8)}</div>
            </div>
            <button
              className="ghost"
              onClick={() => removeMemberClick(m.alias)}
              title="Remove member"
            >
              ✕
            </button>
          </div>
        ))}
        {!addingMember && (
          <button onClick={() => setAddingMember(true)} style={{ marginTop: 4 }}>
            + Add member
          </button>
        )}
        {addingMember && (
          <div className="col" style={{ marginTop: 6 }}>
            <div className="field">
              <label>Session</label>
              <select
                value={newSessionId}
                onChange={(e) => setNewSessionId(e.target.value)}
              >
                <option value="">—</option>
                {availableSessions.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.title}
                  </option>
                ))}
              </select>
            </div>
            <div className="field">
              <label>Alias</label>
              <input
                value={newAlias}
                onChange={(e) => setNewAlias(e.target.value)}
                placeholder="e.g. agent-a"
              />
            </div>
            <div className="row">
              <button
                className="primary"
                onClick={addMemberClick}
                disabled={!newAlias.trim() || !newSessionId}
              >
                Add
              </button>
              <button onClick={() => setAddingMember(false)}>Cancel</button>
            </div>
          </div>
        )}
      </div>

      <div className="section">
        <h4>Recent messages</h4>
        {msgError && <div className="inline-error">{msgError}</div>}
        {messages.length === 0 && !msgError && (
          <div className="muted">No messages yet.</div>
        )}
        {messages.map((msg) => (
          <div key={msg.id} className="message-row">
            <div className="meta">
              <span>
                {msg.fromAlias} → {msg.toAlias}
              </span>
              <span>{new Date(msg.createdAt).toLocaleTimeString()}</span>
            </div>
            <div className="content">{msg.content}</div>
            <div className="row space actions">
              <span className={'badge ' + statusClass(msg.status)}>
                {msg.status}
                {msg.injectedByHuman ? ' · human' : ''}
              </span>
              <div className="row" style={{ gap: 4 }}>
                {(msg.status === 'pending' || msg.status === 'held') && (
                  <>
                    <button onClick={() => handleMsgAction(msg, 'deliver')}>
                      Deliver
                    </button>
                    <button onClick={() => handleMsgAction(msg, 'drop')}>
                      Drop
                    </button>
                  </>
                )}
              </div>
            </div>
          </div>
        ))}
      </div>

      <div className="section">
        <h4>Send message</h4>
        <div className="field">
          <label>From</label>
          <select
            value={sendFrom}
            onChange={(e) => setSendFrom(e.target.value)}
          >
            {/* operator 是合成发送方：以人的身份发消息，不必是 member */}
            <option value="operator">operator (you)</option>
            {channel.members.map((m) => (
              <option key={m.alias} value={m.alias}>
                {m.alias}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label>To</label>
          <select value={sendTo} onChange={(e) => setSendTo(e.target.value)}>
            <option value="*">* (broadcast)</option>
            {channel.members.map((m) => (
              <option key={m.alias} value={m.alias}>
                {m.alias}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label>Content</label>
          <textarea
            value={sendContent}
            onChange={(e) => setSendContent(e.target.value)}
            placeholder="Type a message…"
          />
        </div>
        {opError && <div className="inline-error">{opError}</div>}
        <button
          className="primary"
          onClick={handleSend}
          disabled={!sendFrom || !sendContent.trim()}
        >
          Send
        </button>
      </div>

      <div className="section">
        <button className="danger" onClick={handleDelete}>
          Delete channel
        </button>
      </div>
    </div>
  )
}

function statusClass(status: Message['status']): string {
  switch (status) {
    case 'delivered':
      return 'success'
    case 'pending':
      return 'warn'
    case 'held':
      return 'warn'
    case 'dropped':
      return 'danger'
  }
}

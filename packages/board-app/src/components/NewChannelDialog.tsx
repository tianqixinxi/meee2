import { useMemo, useState } from 'react'
import type { BoardState, Mode } from '../types'
import {
  addMember,
  createChannel,
  deleteChannel,
  sendMessage,
} from '../api'
import { useToast } from '../App'

interface Props {
  state: BoardState
  onClose: () => void
  onCreated: (channelName: string) => void
}

interface MemberDraft {
  sessionId: string
  alias: string
}

const MODES: Mode[] = ['auto', 'intercept', 'paused']

function randomName(): string {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789'
  let s = ''
  for (let i = 0; i < 4; i++) {
    s += alphabet[Math.floor(Math.random() * alphabet.length)]
  }
  return `channel-${s}`
}

export default function NewChannelDialog({ state, onClose, onCreated }: Props) {
  const toast = useToast()
  const [name, setName] = useState(randomName())
  const [mode, setMode] = useState<Mode>('auto')
  // 默认不预选任何成员 —— 用户建 channel 的典型流程现在是：先建好一个 hub，
  // 回到画布从 session card 拉一条 channel arrow 到 hub 就自动加成员。这里
  // 留空，上方仍允许"手填"作为老路径兜底（比如想一次建好 + 加两个成员）。
  const [members, setMembers] = useState<MemberDraft[]>([])
  const [seed, setSeed] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  const canSubmit = useMemo(() => {
    if (!name.trim()) return false
    // 成员可以为空（稍后画 channel arrow 加进来），但如果手填了就必须
    // 填全 + 别名不重复
    const valid = members.filter((m) => m.sessionId && m.alias.trim())
    const filled = members.filter((m) => m.sessionId || m.alias.trim())
    if (valid.length !== filled.length) return false  // 半填的行拒掉
    const aliases = new Set(valid.map((m) => m.alias.trim()))
    if (aliases.size !== valid.length) return false
    return true
  }, [name, members])

  const addRow = () =>
    setMembers((prev) => [...prev, { sessionId: '', alias: '' }])
  const removeRow = (idx: number) =>
    setMembers((prev) => prev.filter((_, i) => i !== idx))
  const updateRow = (idx: number, patch: Partial<MemberDraft>) =>
    setMembers((prev) =>
      prev.map((m, i) => (i === idx ? { ...m, ...patch } : m)),
    )

  const submit = async () => {
    if (!canSubmit) return
    setBusy(true)
    setErr(null)
    const cleanMembers = members
      .map((m) => ({ sessionId: m.sessionId, alias: m.alias.trim() }))
      .filter((m) => m.sessionId && m.alias)
    try {
      await createChannel({ name: name.trim(), mode })
      // Add members sequentially; rollback on failure.
      const added: string[] = []
      try {
        for (const m of cleanMembers) {
          await addMember(name.trim(), m.alias, m.sessionId)
          added.push(m.alias)
        }
      } catch (memberErr) {
        // Best-effort rollback: delete the channel we just made
        try {
          await deleteChannel(name.trim())
        } catch {
          /* ignore */
        }
        throw memberErr
      }

      // Seed 消息需要至少 2 个成员（1 个发送方 + ≥1 个接收方）；现在支持
      // "0 成员创建"后，没成员就别硬发了。用户后续通过画 channel arrow 加
      // 进来成员，再手动发 seed 即可。
      if (seed.trim() && cleanMembers.length >= 2) {
        try {
          await sendMessage({
            channel: name.trim(),
            fromAlias: cleanMembers[0].alias,
            toAlias: '*',
            content: seed.trim(),
            injectedByHuman: true,
          })
        } catch (e) {
          toast.push(
            'error',
            `Seed message failed: ${(e as Error).message}`,
          )
        }
      }

      onCreated(name.trim())
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div
      className="modal-backdrop"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div className="modal" role="dialog" aria-modal="true">
        <div className="modal-header">Create channel</div>
        <div className="modal-body">
          <div className="field">
            <label>Name</label>
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="channel-abcd"
            />
          </div>
          <div className="field">
            <label>Mode</label>
            <div className="segment">
              {MODES.map((m) => (
                <button
                  key={m}
                  className={m === mode ? 'active' : ''}
                  onClick={() => setMode(m)}
                >
                  {m}
                </button>
              ))}
            </div>
          </div>
          <div className="field">
            <label>Members (optional — add later by drawing a channel arrow)</label>
            {members.map((m, idx) => (
              <div key={idx} className="member-row">
                <select
                  value={m.sessionId}
                  onChange={(e) => updateRow(idx, { sessionId: e.target.value })}
                >
                  <option value="">— session —</option>
                  {state.sessions.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.title}
                    </option>
                  ))}
                </select>
                <input
                  value={m.alias}
                  onChange={(e) => updateRow(idx, { alias: e.target.value })}
                  placeholder="alias"
                />
                <button
                  className="ghost"
                  onClick={() => removeRow(idx)}
                  disabled={members.length <= 2}
                  title="Remove row"
                >
                  ✕
                </button>
              </div>
            ))}
            <button onClick={addRow} style={{ marginTop: 4 }}>
              + Add member
            </button>
          </div>
          <div className="field">
            <label>Seed message (optional)</label>
            <textarea
              value={seed}
              onChange={(e) => setSeed(e.target.value)}
              placeholder="Kick-off instructions for the agents…"
            />
            <span className="muted mono">
              Will be sent as broadcast from the first member (no operator
              pseudo-sender in MVP).
            </span>
          </div>
          {err && <div className="inline-error">{err}</div>}
        </div>
        <div className="modal-footer">
          <button onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button
            className="primary"
            onClick={submit}
            disabled={!canSubmit || busy}
          >
            {busy ? 'Creating…' : 'Create'}
          </button>
        </div>
      </div>
    </div>
  )
}

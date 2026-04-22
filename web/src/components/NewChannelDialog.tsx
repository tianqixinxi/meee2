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
  const [members, setMembers] = useState<MemberDraft[]>(() => {
    const first = state.sessions[0]
    const second = state.sessions[1]
    return [
      { sessionId: first?.id ?? '', alias: 'alpha' },
      { sessionId: second?.id ?? '', alias: 'beta' },
    ]
  })
  const [seed, setSeed] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  const canSubmit = useMemo(() => {
    if (!name.trim()) return false
    const valid = members.filter((m) => m.sessionId && m.alias.trim())
    if (valid.length < 2) return false
    // Unique aliases
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

      // Seed message workaround: the spec's ideal would be a pseudo-sender
      // "__operator__", but since __operator__ isn't a channel member, we
      // can't POST /messages/send as that alias. For MVP, we send the seed
      // using the first member as the sender, broadcast (toAlias="*") so
      // every other member receives it, flagged injectedByHuman:true.
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
            <label>Members (min 2)</label>
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

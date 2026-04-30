// Right-side detail panel — meee2-specific glue around board-ui's
// <SessionInspector>. Wires Open Terminal / Spawn Here / inbox load
// against the local Swift backend; passes meee2's TranscriptPanel as the
// transcript slot.

import { useEffect, useMemo, useState } from 'react'
import { SessionInspector } from '@tianqixinxi/board-ui'
import type {
  ChannelMembershipForInspector,
  InboxItemForInspector,
  SessionForInspector,
} from '@tianqixinxi/board-core'
import type { BoardState, Message } from '../types'
import { listChannelMessages, activateSession, spawnSession } from '../api'
import { loadDefaultSpawnCommand } from '../preferences'
import { useToast } from '../App'
import TranscriptPanel from './TranscriptPanel'

interface Props {
  state: BoardState
  sessionId: string
}

export default function SessionDetail({ state, sessionId }: Props) {
  const toast = useToast()
  const session = state.sessions.find((s) => s.id === sessionId)
  const [inboxItems, setInboxItems] = useState<InboxItemForInspector[]>([])

  const memberships = useMemo<ChannelMembershipForInspector[]>(
    () =>
      state.channels
        .map((ch) => ({
          channel: ch.name,
          aliases: ch.members.filter((m) => m.sessionId === sessionId).map((m) => m.alias),
        }))
        .filter((m) => m.aliases.length > 0),
    [state.channels, sessionId],
  )

  // Pull pending/held messages addressed to this session for the inbox
  // chip popover + bottom block. Same logic the previous SessionDetail had.
  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!session) return
      const out: InboxItemForInspector[] = []
      for (const m of memberships) {
        try {
          const msgs = await listChannelMessages(m.channel, {
            statuses: ['pending', 'held'],
            limit: 20,
          })
          for (const msg of msgs as Message[]) {
            if (msg.fromAlias && m.aliases.includes(msg.fromAlias)) continue
            if (msg.toAlias === '*' || m.aliases.includes(msg.toAlias)) {
              out.push({
                id: msg.id,
                channel: m.channel,
                fromAlias: msg.fromAlias,
                toAlias: msg.toAlias,
                content: msg.content,
                createdAt: msg.createdAt,
              })
            }
          }
        } catch (e) {
          toast.push('error', (e as Error).message)
        }
      }
      if (!cancelled) setInboxItems(out)
    }
    void load()
    return () => { cancelled = true }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, state])

  if (!session) {
    return <div className="muted">Session no longer exists.</div>
  }

  // meee2's Session structurally satisfies SessionForInspector — fields
  // line up. Cast keeps the call site clean without an intermediate map.
  const inspectorSession: SessionForInspector = session as unknown as SessionForInspector

  return (
    <SessionInspector
      session={inspectorSession}
      onOpenTerminal={async () => {
        const ok = await activateSession(session.id)
        if (!ok) toast.push('error', 'Failed to open terminal')
      }}
      onSpawnHere={async () => {
        try {
          const cmd = loadDefaultSpawnCommand() || 'claude'
          await spawnSession({ cwd: session.project, command: cmd, createIfMissing: false })
          toast.push('success', `Spawned new agent in ${session.project}`)
        } catch (e) {
          toast.push('error', `Spawn failed: ${(e as Error).message}`)
        }
      }}
      inboxItems={inboxItems}
      memberships={memberships}
      transcriptSlot={
        <TranscriptPanel
          key={session.id}
          sessionId={session.id}
          limit={200}
          refreshTrigger={state}
        />
      }
    />
  )
}

import { useEffect, useRef, useState } from 'react'

// Minimal conversation panel for the meee2-online TS planner runtime.
// Owns:
//   - "Start session" + seed message input
//   - SSE event log (textDelta / toolCall / toolResult / proposal / askUser / done / error)
//   - Reply input when an askUser event has fired
//   - Per-canvas audit log fetch (read-only)
//
// Mounting: parent passes runtimeBaseUrl + boardBaseUrl + canvasId; this
// component doesn't know about app routing.

interface Props {
  runtimeBaseUrl: string
  boardBaseUrl: string
  canvasId: string
  harness?: 'stub' | 'anthropic'
}

interface LogEntry {
  ts: number
  kind: string
  text: string
}

interface AuditEntry {
  id: string
  session_id: string
  canvas_id: string
  actor: string
  tool_name: string
  args: unknown
  result: unknown
  ok: boolean
  error: string | null
  ts: string
}

export function PlannerAgentChatPanel({
  runtimeBaseUrl,
  boardBaseUrl,
  canvasId,
  harness = 'stub',
}: Props) {
  const [seedMessage, setSeedMessage] = useState('')
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [log, setLog] = useState<LogEntry[]>([])
  const [pendingQuestion, setPendingQuestion] = useState<string | null>(null)
  const [pendingCallId, setPendingCallId] = useState<string | null>(null)
  const [replyText, setReplyText] = useState('')
  const [audit, setAudit] = useState<AuditEntry[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const sourceRef = useRef<EventSource | null>(null)

  useEffect(() => {
    return () => {
      sourceRef.current?.close()
    }
  }, [])

  function addLog(kind: string, text: string) {
    setLog((prev) => [...prev, { ts: Date.now(), kind, text }])
  }

  function openStream(sid: string) {
    sourceRef.current?.close()
    const src = new EventSource(`${runtimeBaseUrl}/api/planner/runtime/sessions/${sid}/stream`)
    sourceRef.current = src
    const handle = (kind: string) => (ev: MessageEvent) => {
      let payload: unknown = ev.data
      try {
        payload = JSON.parse(ev.data)
      } catch {
        // keep as raw string
      }
      if (
        kind === 'askUser' &&
        typeof payload === 'object' &&
        payload &&
        'question' in payload &&
        'callId' in payload
      ) {
        const ask = payload as unknown as { question: string; callId: string }
        setPendingQuestion(ask.question)
        setPendingCallId(ask.callId)
      }
      if (kind === 'done' || kind === 'error') {
        src.close()
        sourceRef.current = null
        void refreshAudit(sid)
      }
      addLog(kind, typeof payload === 'string' ? payload : JSON.stringify(payload))
    }
    for (const k of [
      'textDelta',
      'toolCall',
      'toolResult',
      'proposal',
      'askUser',
      'done',
      'error',
    ]) {
      src.addEventListener(k, handle(k))
    }
    src.onerror = () => {
      addLog('error', '(SSE connection error)')
      src.close()
      sourceRef.current = null
    }
  }

  async function refreshAudit(sid: string) {
    try {
      const r = await fetch(
        `${runtimeBaseUrl}/api/planner/runtime/sessions/${sid}/audit?limit=50`,
      )
      if (!r.ok) return
      const data = (await r.json()) as { entries: AuditEntry[] }
      setAudit(data.entries ?? [])
    } catch {
      // ignore
    }
  }

  async function startSession() {
    setBusy(true)
    setError(null)
    setLog([])
    setAudit([])
    setPendingQuestion(null)
    setPendingCallId(null)
    try {
      const r = await fetch(`${runtimeBaseUrl}/api/planner/runtime/sessions`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          canvasId,
          boardBaseUrl,
          harness,
          seedUserMessage: seedMessage.trim() || '(no seed)',
        }),
      })
      const json = (await r.json()) as { session?: { id: string }; error?: string }
      if (!r.ok || !json.session) {
        setError(json.error ?? `create session failed: ${r.status}`)
        return
      }
      setSessionId(json.session.id)
      addLog('session', `started ${json.session.id}`)
      openStream(json.session.id)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  async function sendReply() {
    if (!sessionId || !pendingCallId || !replyText.trim()) return
    setBusy(true)
    try {
      const r = await fetch(
        `${runtimeBaseUrl}/api/planner/runtime/sessions/${sessionId}/reply`,
        {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ answer: replyText.trim() }),
        },
      )
      if (!r.ok) {
        const json = (await r.json().catch(() => null)) as { error?: string } | null
        setError(json?.error ?? `reply failed: ${r.status}`)
        return
      }
      addLog('reply', replyText.trim())
      setReplyText('')
      setPendingQuestion(null)
      setPendingCallId(null)
      openStream(sessionId)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="planner-agent-chat">
      <header>
        <h3>Planner Agent</h3>
        <small>
          runtime <code>{runtimeBaseUrl}</code> · canvas <code>{canvasId}</code> · harness{' '}
          <code>{harness}</code>
        </small>
      </header>

      {!sessionId && (
        <section>
          <textarea
            value={seedMessage}
            onChange={(e) => setSeedMessage(e.target.value)}
            placeholder="describe what you want the planner to plan (e.g. 'add a code review step before deploy')"
            rows={3}
            disabled={busy}
          />
          <button type="button" onClick={startSession} disabled={busy}>
            {busy ? 'starting…' : 'start session'}
          </button>
        </section>
      )}

      <section className="planner-agent-log">
        {log.map((entry, i) => (
          <div key={i} className={`planner-agent-log-row planner-agent-log-${entry.kind}`}>
            <span className="planner-agent-log-kind">{entry.kind}</span>
            <span className="planner-agent-log-text">{entry.text}</span>
          </div>
        ))}
      </section>

      {pendingQuestion && (
        <section className="planner-agent-ask">
          <strong>Agent asks:</strong> {pendingQuestion}
          <textarea
            value={replyText}
            onChange={(e) => setReplyText(e.target.value)}
            placeholder="your answer"
            rows={2}
            disabled={busy}
          />
          <button type="button" onClick={sendReply} disabled={busy || !replyText.trim()}>
            send reply
          </button>
        </section>
      )}

      {error && <div className="planner-agent-error">{error}</div>}

      {audit.length > 0 && (
        <section className="planner-agent-audit">
          <h4>Audit log ({audit.length})</h4>
          <ol>
            {audit.map((a) => (
              <li key={a.id}>
                <code>{a.tool_name}</code>{' '}
                <span className={a.ok ? 'ok' : 'bad'}>{a.ok ? 'ok' : 'fail'}</span>{' '}
                {a.error && <em>{a.error}</em>}
              </li>
            ))}
          </ol>
        </section>
      )}
    </div>
  )
}

import { useEffect, useMemo, useState, type CSSProperties } from 'react'
import {
  AlertTriangle,
  CheckCircle2,
  ExternalLink,
  GitPullRequest,
  History,
  Map,
  MessageSquare,
  Search,
  Shield,
  Users,
} from 'lucide-react'
import type { BoardState } from '../types'
import {
  createFeishuDoc,
  fetchFeishuConfig,
  sendFeishuCard,
  type FeishuConfig,
} from '../api'
import {
  buildSessionGraph,
  matchesSessionNode,
  type SessionGraph,
  type SessionGraphNode,
} from '../sessionGraph'
import {
  buildSyncPayloadPreview,
  createWorkroom,
  effectiveSyncPolicy,
  generateHandoffSummary,
  inferArtifacts,
  loadWorkrooms,
  saveWorkrooms,
  type Workroom,
} from '../workLayer'
import { useI18n } from '../i18n'

export type WorkLayerView = 'team' | 'workrooms' | 'review' | 'memory'

interface WorkLayerViewsProps {
  view: WorkLayerView
  state: BoardState | null
  error: string | null
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
}

export function WorkLayerViews({
  view,
  state,
  error,
  onOpenSession,
  onShowInMap,
}: WorkLayerViewsProps) {
  const { t } = useI18n()
  const [query, setQuery] = useState('')
  const [workrooms, setWorkrooms] = useState(loadWorkrooms)
  const [feishu, setFeishu] = useState<FeishuConfig | null>(null)
  const [deliveryMessage, setDeliveryMessage] = useState<string | null>(null)
  const graph = useMemo(() => buildSessionGraph(state?.sessions ?? []), [state])
  const nodes = useMemo(
    () => graph.nodes.filter((node) => matchesSessionNode(node, query)),
    [graph.nodes, query],
  )
  const title = titleFor(view, t)
  useEffect(() => {
    fetchFeishuConfig()
      .then((result) => setFeishu(result.feishu))
      .catch(() => setFeishu(null))
  }, [])

  const persistWorkrooms = (next: Workroom[]) => {
    setWorkrooms(saveWorkrooms(next))
  }

  return (
    <main className="work-layer" aria-label="AI Work Layer">
      <header className="work-layer__header">
        <div>
          <p className="cockpit-kicker">{title.kicker}</p>
          <h1>{title.title}</h1>
          <p className="cockpit-subtitle">{title.subtitle}</p>
        </div>
      </header>

      <div className="cockpit-search work-layer__search">
        <Search size={16} aria-hidden />
        <input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t('work.search')}
          aria-label="Search work layer"
        />
      </div>

      {error && <div className="cockpit-inline-error">{error}</div>}

      {view === 'team' && (
        <TeamRadar
          graph={graph}
          nodes={nodes}
          feishu={feishu}
          deliveryMessage={deliveryMessage}
          onDeliveryMessage={setDeliveryMessage}
          onOpenSession={onOpenSession}
          onShowInMap={onShowInMap}
        />
      )}
      {view === 'workrooms' && (
        <WorkroomsView
          nodes={nodes}
          workrooms={workrooms}
          feishu={feishu}
          onDeliveryMessage={setDeliveryMessage}
          onSave={persistWorkrooms}
          onOpenSession={onOpenSession}
          onShowInMap={onShowInMap}
        />
      )}
      {view === 'review' && (
        <ReviewRoom
          nodes={nodes}
          onOpenSession={onOpenSession}
          onShowInMap={onShowInMap}
        />
      )}
      {view === 'memory' && (
        <MemoryAudit
          graph={graph}
          nodes={nodes}
          feishu={feishu}
          onDeliveryMessage={setDeliveryMessage}
        />
      )}
    </main>
  )
}

function TeamRadar({
  graph,
  nodes,
  feishu,
  deliveryMessage,
  onDeliveryMessage,
  onOpenSession,
  onShowInMap,
}: {
  graph: SessionGraph
  nodes: SessionGraphNode[]
  feishu: FeishuConfig | null
  deliveryMessage: string | null
  onDeliveryMessage: (message: string | null) => void
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
}) {
  const visible = nodes.filter((node) => effectiveSyncPolicy(node.session) !== 'private')
  const privateCount = nodes.length - visible.length
  const needsAttention = visible.filter((node) => node.bucketIds.includes('needsAttention'))
  const running = visible.filter((node) => node.bucketIds.includes('running'))
  const reviewReady = visible.filter((node) => inferArtifacts(node).some((artifact) => artifact.type === 'pr' || artifact.type === 'diff'))
  const done = visible.filter((node) => node.bucketIds.includes('recentlyCompleted'))
  const ownerRows = groupCounts(visible, (node) => node.session.syncTeamName || 'Local team')
  const repoRows = groupCounts(visible, (node) => node.repo)
  const providerRows = groupCounts(visible, (node) => node.provider)
  const hiddenAttention = graph.buckets.needsAttention.length - needsAttention.length
  const sendBlocked = async () => {
    const node = graph.buckets.needsAttention.find((candidate) => effectiveSyncPolicy(candidate.session) !== 'private')
    if (!node) return
    const policy = effectiveSyncPolicy(node.session)
    const preview = buildSyncPayloadPreview(node, policy)
    try {
      const result = await sendFeishuCard({
        kind: 'blocked',
        payload: {
          event: 'blocked',
          policy,
          card: preview.payload,
          sessionLink: `/sessions/${node.session.id}`,
        },
      })
      onDeliveryMessage(result.ok ? 'Feishu blocked alert sent.' : result.error ?? 'Feishu blocked alert failed.')
    } catch (err) {
      onDeliveryMessage((err as Error).message)
    }
  }
  return (
    <div className="work-layer__grid">
      <section className="work-layer__panel work-layer__wide">
        <div className="work-layer__panel-head">
          <div>
            <h2>Team AI Radar</h2>
            <p>For CEO / PM / CTO: what is moving, what is blocked, what is ready for review, and what shipped.</p>
          </div>
          <Users size={18} aria-hidden />
        </div>
        <div className="work-layer__radar-stats">
          <RadarStat label="Needs attention" value={needsAttention.length} tone="danger" />
          <RadarStat label="Running" value={running.length} tone="info" />
          <RadarStat label="Review-ready" value={reviewReady.length} tone="warning" />
          <RadarStat label="Recently done" value={done.length} tone="success" />
        </div>
      </section>
      <section className="work-layer__panel work-layer__wide">
        <div className="work-layer__panel-head">
          <div>
            <h2>Needs attention</h2>
            <p>Blocked, permission-required, stale, or failed work that needs a person.</p>
          </div>
          <AlertTriangle size={18} aria-hidden />
        </div>
        <RadarSessionList
          nodes={needsAttention.slice(0, 8)}
          onOpenSession={onOpenSession}
          onShowInMap={onShowInMap}
          empty={visible.length === 0 ? 'No team-visible sessions yet.' : 'No visible blockers right now.'}
        />
      </section>
      <section className="work-layer__panel">
        <h2>Active work</h2>
        <RadarSessionList
          nodes={running.slice(0, 5)}
          onOpenSession={onOpenSession}
          onShowInMap={onShowInMap}
          empty="No team-visible running sessions."
          compact
        />
      </section>
      <section className="work-layer__panel">
        <h2>Ready / done</h2>
        <MetricRows rows={[
          ['Review-ready', reviewReady.length],
          ['Completed', done.length],
          ['Visible sessions', visible.length],
          ['Private local', privateCount],
        ]} />
      </section>
      <section className="work-layer__panel">
        <h2>Feishu delivery</h2>
        <StatusRows rows={[
          ['Status', feishu?.deliveryStatus ?? 'not configured'],
          ['Default group', feishu?.defaultGroupName || feishu?.defaultGroupId || 'not set'],
          ['Last sent', feishu?.lastSentAt ? new Date(feishu.lastSentAt).toLocaleString() : 'never'],
          ['Last error', feishu?.lastError ?? 'none'],
        ]} />
        {deliveryMessage && <p className="work-layer__muted">{deliveryMessage}</p>}
        <button className="ghost" type="button" onClick={() => void sendBlocked()} disabled={needsAttention.length === 0}>
          Send blocked alert
        </button>
      </section>
      <section className="work-layer__panel">
        <div className="work-layer__panel-head">
          <div>
            <h2>Visibility boundary</h2>
            <p>Radar only uses sessions allowed by sync policy.</p>
          </div>
          <Shield size={18} aria-hidden />
        </div>
        <StatusRows rows={[
          ['Team-visible', `${visible.length}`],
          ['Private local', `${privateCount}`],
          ['Hidden blockers', `${Math.max(0, hiddenAttention)}`],
          ['Full transcript', `${visible.filter((node) => effectiveSyncPolicy(node.session) === 'fullTranscript').length}`],
        ]} />
      </section>
      <section className="work-layer__panel work-layer__wide">
        <div className="work-layer__panel-head">
          <div>
            <h2>Team slices</h2>
            <p>Scan by team scope, repo, and provider without leaving the radar.</p>
          </div>
        </div>
        <div className="work-layer__slice-grid">
          <MetricRows rows={ownerRows.length > 0 ? ownerRows : [['No team-visible sessions', 0]]} />
          <MetricRows rows={repoRows.length > 0 ? repoRows : [['No repos', 0]]} />
          <MetricRows rows={providerRows.length > 0 ? providerRows : [['No providers', 0]]} />
        </div>
      </section>
    </div>
  )
}

function WorkroomsView({
  nodes,
  workrooms,
  feishu,
  onDeliveryMessage,
  onSave,
  onOpenSession,
  onShowInMap,
}: {
  nodes: SessionGraphNode[]
  workrooms: Workroom[]
  feishu: FeishuConfig | null
  onDeliveryMessage: (message: string | null) => void
  onSave: (workrooms: Workroom[]) => void
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
}) {
  const [selectedIds, setSelectedIds] = useState<string[]>(() => nodes.slice(0, 2).map((node) => node.session.id))
  const [name, setName] = useState('Handoff room')
  const [purpose, setPurpose] = useState('Rescue or review selected AI sessions.')
  const [commentBody, setCommentBody] = useState('')
  const selectedNodes = nodes.filter((node) => selectedIds.includes(node.session.id))
  const activeWorkroom = workrooms[0] ?? null
  const handoff = activeWorkroom ? generateHandoffSummary(activeWorkroom, nodes) : ''
  const feishuHandoff = activeWorkroom ? buildFeishuWorkroomBrief(activeWorkroom, nodes) : ''

  const toggle = (sessionId: string) => {
    setSelectedIds((current) =>
      current.includes(sessionId)
        ? current.filter((id) => id !== sessionId)
        : [...current, sessionId],
    )
  }
  const create = () => {
    if (selectedIds.length === 0) return
    const room = createWorkroom({
      name,
      purpose,
      linkedRepo: selectedNodes[0]?.repo ?? '',
      linkedPr: '',
      selectedSessionIds: selectedIds,
    })
    onSave([room, ...workrooms])
  }
  const addComment = () => {
    if (!activeWorkroom || !commentBody.trim()) return
    const next = workrooms.map((room) =>
      room.id === activeWorkroom.id
        ? {
            ...room,
            comments: [
              ...room.comments,
              {
                id: `comment-${Date.now().toString(36)}`,
                author: 'local-user',
                body: commentBody.trim(),
                createdAt: new Date().toISOString(),
              },
            ],
            updatedAt: new Date().toISOString(),
          }
        : room,
    )
    setCommentBody('')
    onSave(next)
  }
  const sendHandoffCard = async () => {
    if (!activeWorkroom) return
    try {
      const result = await sendFeishuCard({
        kind: 'handoffCreated',
        payload: {
          event: 'handoffCreated',
          workroom: activeWorkroom,
          handoff: feishuHandoff,
        },
      })
      onDeliveryMessage(result.ok ? 'Feishu handoff card sent.' : result.error ?? 'Feishu handoff card failed.')
    } catch (err) {
      onDeliveryMessage((err as Error).message)
    }
  }
  const createHandoffDoc = async () => {
    if (!activeWorkroom) return
    try {
      const result = await createFeishuDoc({
        kind: 'handoffDoc',
        title: `meee2 handoff · ${activeWorkroom.name}`,
        content: feishuHandoff,
        workroomId: activeWorkroom.id,
      })
      onDeliveryMessage(result.ok ? `Feishu handoff doc created${result.url ? `: ${result.url}` : '.'}` : result.error ?? 'Feishu doc failed.')
    } catch (err) {
      onDeliveryMessage((err as Error).message)
    }
  }

  return (
    <div className="work-layer__grid">
      <section className="work-layer__panel">
        <h2>Create Workroom</h2>
        <label className="work-layer__field">
          <span>Name</span>
          <input value={name} onChange={(event) => setName(event.target.value)} />
        </label>
        <label className="work-layer__field">
          <span>Purpose</span>
          <textarea value={purpose} onChange={(event) => setPurpose(event.target.value)} />
        </label>
        <button className="primary" type="button" onClick={create} disabled={selectedIds.length === 0}>
          Create from {selectedIds.length} sessions
        </button>
      </section>
      <section className="work-layer__panel work-layer__wide">
        <h2>Select sessions</h2>
        <div className="work-layer__checklist">
          {nodes.map((node) => (
            <label key={node.session.id} className="work-layer__checkrow">
              <input
                type="checkbox"
                checked={selectedIds.includes(node.session.id)}
                onChange={() => toggle(node.session.id)}
              />
              <span>
                <strong>{node.session.title}</strong>
                <small>{node.provider} · {node.repo} · {node.currentStep}</small>
              </span>
            </label>
          ))}
        </div>
      </section>
      <section className="work-layer__panel">
        <h2>Workrooms</h2>
        {workrooms.length === 0 ? (
          <p className="work-layer__muted">No workrooms yet. Workroom replaces old global session/channel as the temporary handoff surface.</p>
        ) : (
          <div className="work-layer__room-list">
            {workrooms.map((room) => (
              <div key={room.id} className="work-layer__room">
                <strong>{room.name}</strong>
                <span>{room.selectedSessionIds.length} sessions · {room.linkedRepo || 'no repo'}</span>
              </div>
            ))}
          </div>
        )}
      </section>
      <section className="work-layer__panel work-layer__wide">
        <div className="work-layer__panel-head">
          <div>
            <h2>Combined handoff</h2>
            <p>Generated locally from selected session state, risks, and current steps.</p>
          </div>
          <MessageSquare size={18} aria-hidden />
        </div>
        {activeWorkroom ? (
          <>
            <pre className="work-layer__handoff">{handoff}</pre>
            <SessionPills nodes={nodes.filter((node) => activeWorkroom.selectedSessionIds.includes(node.session.id))} onOpenSession={onOpenSession} onShowInMap={onShowInMap} />
          </>
        ) : (
          <p className="work-layer__muted">Create a workroom to generate handoff context.</p>
        )}
      </section>
      <section className="work-layer__panel work-layer__wide">
        <div className="work-layer__panel-head">
          <div>
            <h2>Comments and actions</h2>
            <p>Local collaboration notes for this workroom. Sending context to sessions still requires explicit action.</p>
          </div>
        </div>
        {activeWorkroom ? (
          <>
            <div className="work-layer__comments">
              {activeWorkroom.comments.length === 0 ? (
                <p className="work-layer__muted">No comments yet.</p>
              ) : activeWorkroom.comments.map((comment) => (
                <div key={comment.id} className="work-layer__comment">
                  <strong>{comment.author}</strong>
                  <span>{new Date(comment.createdAt).toLocaleString()}</span>
                  <p>{comment.body}</p>
                </div>
              ))}
            </div>
            <div className="work-layer__comment-box">
              <input
                value={commentBody}
                onChange={(event) => setCommentBody(event.target.value)}
                placeholder="Add handoff note, reviewer context, or rescue action"
              />
              <button type="button" className="primary" onClick={addComment} disabled={!commentBody.trim()}>
                Add comment
              </button>
              <button
                type="button"
                className="ghost"
                onClick={() => {
                  if (window.confirm('Prepare this handoff context for selected sessions? Nothing is sent automatically.')) {
                    setCommentBody('Prepared combined handoff context. Use Jump back to paste or continue in the real terminal/editor.')
                  }
                }}
              >
                Prepare send context
              </button>
              <button type="button" className="ghost" onClick={() => void sendHandoffCard()} disabled={!feishu?.configured}>
                Send to Feishu group
              </button>
              <button type="button" className="ghost" onClick={() => void createHandoffDoc()} disabled={!feishu?.configured}>
                Create Feishu handoff doc
              </button>
              <button
                type="button"
                className="ghost"
                onClick={() => void navigator.clipboard?.writeText(feishuHandoff)}
              >
                Copy Feishu-ready brief
              </button>
            </div>
          </>
        ) : (
          <p className="work-layer__muted">Create a workroom to add comments.</p>
        )}
      </section>
    </div>
  )
}

function ReviewRoom({
  nodes,
  onOpenSession,
  onShowInMap,
}: {
  nodes: SessionGraphNode[]
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
}) {
  const repos = [...new Set(nodes.map((node) => node.repo))]
  const [repo, setRepo] = useState(repos[0] ?? '')
  const scoped = nodes.filter((node) => !repo || node.repo === repo)
  const artifacts = scoped.flatMap((node) => inferArtifacts(node).map((artifact) => ({ ...artifact, session: node.session.title })))
  return (
    <div className="work-layer__grid">
      <section className="work-layer__panel">
        <h2>Review scope</h2>
        <label className="work-layer__field">
          <span>Repo / project</span>
          <select value={repo} onChange={(event) => setRepo(event.target.value)}>
            {repos.map((r) => <option key={r} value={r}>{r}</option>)}
          </select>
        </label>
        <MetricRows rows={[
          ['Related sessions', scoped.length],
          ['Risks', scoped.reduce((sum, node) => sum + node.risks.length, 0)],
          ['Artifacts', artifacts.length],
        ]} />
      </section>
      <section className="work-layer__panel work-layer__wide">
        <div className="work-layer__panel-head">
          <div>
            <h2>Related sessions</h2>
            <p>PR review context comes from session status, recent decisions, failed attempts, and local evidence.</p>
          </div>
          <GitPullRequest size={18} aria-hidden />
        </div>
        <SessionPills nodes={scoped} onOpenSession={onOpenSession} onShowInMap={onShowInMap} />
      </section>
      <section className="work-layer__panel">
        <h2>Evidence</h2>
        {artifacts.length === 0 ? (
          <p className="work-layer__muted">No PR/test/deploy evidence inferred yet. GitHub and CI integrations will write here in Phase 4.</p>
        ) : (
          <div className="work-layer__artifact-list">
            {artifacts.map((artifact, index) => (
              <div key={`${artifact.session}-${artifact.type}-${index}`} className="work-layer__artifact">
                <strong>{artifact.type}</strong>
                <span>{artifact.title} · {artifact.status}</span>
                <small>{artifact.session}</small>
              </div>
            ))}
          </div>
        )}
      </section>
      <section className="work-layer__panel">
        <h2>Integration slots</h2>
        <StatusRows rows={[
          ['GitHub PR / checks', 'not connected'],
          ['Linear / Jira issue', 'light link only'],
          ['CI / Vercel deploy', 'pending integration'],
          ['Reviewer brief', scoped.length > 0 ? 'ready from local sessions' : 'no sessions'],
        ]} />
      </section>
    </div>
  )
}

function MemoryAudit({
  graph,
  nodes,
  feishu,
  onDeliveryMessage,
}: {
  graph: SessionGraph
  nodes: SessionGraphNode[]
  feishu: FeishuConfig | null
  onDeliveryMessage: (message: string | null) => void
}) {
  const visible = nodes.filter((node) => effectiveSyncPolicy(node.session) !== 'private')
  const fullTranscript = nodes.filter((node) => effectiveSyncPolicy(node.session) === 'fullTranscript').length
  const privateCount = nodes.length - visible.length
  const standup = [
    ...graph.buckets.needsAttention.slice(0, 4).map((node) => `Blocked: ${node.session.title} — ${node.risks[0]?.label ?? node.currentStep}`),
    ...graph.buckets.running.slice(0, 4).map((node) => `Running: ${node.session.title} — ${node.currentStep}`),
    ...graph.buckets.recentlyCompleted.slice(0, 4).map((node) => `Done: ${node.session.title}`),
  ]
  const standupText = standup.join('\n') || 'No local session activity yet.'
  const feishuStandupText = visible
    .slice(0, 12)
    .map((node) => {
      const preview = buildSyncPayloadPreview(node, effectiveSyncPolicy(node.session))
      return `- ${node.session.status}: ${JSON.stringify(preview.payload)}`
    })
    .join('\n') || 'No team-visible session activity.'
  const sendStandup = async () => {
    try {
      const result = await sendFeishuCard({
        kind: 'dailyStandup',
        payload: {
          event: 'dailyStandup',
          policy: 'selective',
          standup: feishuStandupText,
        },
      })
      onDeliveryMessage(result.ok ? 'Feishu standup sent.' : result.error ?? 'Feishu standup failed.')
    } catch (err) {
      onDeliveryMessage((err as Error).message)
    }
  }
  const createStandupDoc = async () => {
    try {
      const result = await createFeishuDoc({
        kind: 'dailyStandupDoc',
        title: `meee2 AI standup · ${new Date().toLocaleDateString()}`,
        content: feishuStandupText,
      })
      onDeliveryMessage(result.ok ? `Feishu standup doc created${result.url ? `: ${result.url}` : '.'}` : result.error ?? 'Feishu standup doc failed.')
    } catch (err) {
      onDeliveryMessage((err as Error).message)
    }
  }
  return (
    <div className="work-layer__grid">
      <section className="work-layer__panel">
        <div className="work-layer__panel-head">
          <div>
            <h2>AI standup</h2>
            <p>Local draft for daily team update.</p>
          </div>
          <History size={18} aria-hidden />
        </div>
        <pre className="work-layer__handoff">{standupText}</pre>
        <div className="work-layer__comment-box">
          <button className="ghost" type="button" onClick={() => void createStandupDoc()} disabled={!feishu?.configured || visible.length === 0}>
            Generate daily Feishu standup
          </button>
          <button className="ghost" type="button" onClick={() => void sendStandup()} disabled={!feishu?.configured || visible.length === 0}>
            Send standup to Feishu group
          </button>
        </div>
      </section>
      <section className="work-layer__panel">
        <h2>Throughput</h2>
        <MetricRows rows={[
          ['Total sessions', nodes.length],
          ['Running', graph.buckets.running.length],
          ['Blocked / attention', graph.buckets.needsAttention.length],
          ['Completed', graph.buckets.recentlyCompleted.length],
        ]} />
      </section>
      <section className="work-layer__panel">
        <h2>Privacy audit</h2>
        <MetricRows rows={[
          ['Private', privateCount],
          ['Team visible', visible.length],
          ['Full transcript', fullTranscript],
          ['Metadata or safer', nodes.length - fullTranscript],
        ]} />
      </section>
      <section className="work-layer__panel work-layer__wide">
        <h2>Retention and governance</h2>
        <StatusRows rows={[
          ['Default sync', 'private locally; metadata only after explicit team policy'],
          ['Transcript', 'collapsed and excluded unless policy is Full transcript'],
          ['Enterprise audit', 'planned integration surface'],
          ['Self-host', 'planned deployment mode'],
        ]} />
      </section>
    </div>
  )
}

function RadarStat({ label, value, tone }: { label: string; value: number; tone: 'danger' | 'info' | 'warning' | 'success' }) {
  return (
    <div className={`work-layer__radar-stat is-${tone}`}>
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  )
}

function RadarSessionList({
  nodes,
  onOpenSession,
  onShowInMap,
  empty,
  compact = false,
}: {
  nodes: SessionGraphNode[]
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
  empty: string
  compact?: boolean
}) {
  if (nodes.length === 0) return <p className="work-layer__muted">{empty}</p>
  return (
    <div className={`work-layer__radar-list${compact ? ' is-compact' : ''}`}>
      {nodes.map((node) => {
        const policy = effectiveSyncPolicy(node.session)
        const risk = node.risks[0]
        return (
          <div key={node.session.id} className="work-layer__radar-row">
            <span className="work-layer__provider" style={{ '--provider-color': node.session.pluginColor } as CSSProperties}>
              {node.provider}
            </span>
            <div className="work-layer__radar-main">
              <strong>{node.session.title}</strong>
              <span>{node.currentStep}</span>
            </div>
            <span>{node.repo}</span>
            <span className={`work-layer__risk-chip ${risk ? `is-${risk.severity}` : ''}`}>
              {risk?.label ?? node.session.status}
            </span>
            <span className="work-layer__policy-chip">{policy}</span>
            <button className="ghost icon-only" type="button" onClick={() => onShowInMap(node.session.id)} aria-label="Show in Session Map">
              <Map size={15} aria-hidden />
            </button>
            <button className="ghost icon-only" type="button" onClick={() => onOpenSession(node.session.id)} aria-label="Open session detail">
              <ExternalLink size={15} aria-hidden />
            </button>
          </div>
        )
      })}
    </div>
  )
}

function groupCounts(nodes: SessionGraphNode[], labelFor: (node: SessionGraphNode) => string): Array<[string, number]> {
  const counts = new globalThis.Map<string, number>()
  for (const node of nodes) {
    const label = labelFor(node).trim() || 'Unknown'
    counts.set(label, (counts.get(label) ?? 0) + 1)
  }
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, 5)
}

function SessionPills({
  nodes,
  onOpenSession,
  onShowInMap,
}: {
  nodes: SessionGraphNode[]
  onOpenSession: (sessionId: string) => void
  onShowInMap: (sessionId: string) => void
}) {
  if (nodes.length === 0) return <p className="work-layer__muted">No related sessions.</p>
  return (
    <div className="work-layer__pills">
      {nodes.map((node) => (
        <article key={node.session.id} className="work-layer__session-pill">
          <div>
            <strong>{node.session.title}</strong>
            <span>{node.provider} · {node.repo} · {node.session.status}</span>
            <p>{node.currentStep}</p>
          </div>
          <div className="work-layer__pill-actions">
            {node.risks.length > 0 && <AlertTriangle size={15} aria-label="Has risk" />}
            {node.session.status === 'completed' && <CheckCircle2 size={15} aria-label="Completed" />}
            <button className="ghost icon-only" type="button" onClick={() => onShowInMap(node.session.id)} aria-label="Show in Session Map">
              <Map size={15} aria-hidden />
            </button>
            <button className="ghost icon-only" type="button" onClick={() => onOpenSession(node.session.id)} aria-label="Open session detail">
              <ExternalLink size={15} aria-hidden />
            </button>
          </div>
        </article>
      ))}
    </div>
  )
}

function MetricRows({ rows }: { rows: Array<[string, number]> }) {
  return (
    <div className="work-layer__metrics">
      {rows.map(([label, value]) => (
        <div key={label}>
          <span>{label}</span>
          <strong>{value}</strong>
        </div>
      ))}
    </div>
  )
}

function StatusRows({ rows }: { rows: Array<[string, string]> }) {
  return (
    <div className="work-layer__status-rows">
      {rows.map(([label, value]) => (
        <div key={label}>
          <span>{label}</span>
          <strong>{value}</strong>
        </div>
      ))}
    </div>
  )
}

function buildFeishuWorkroomBrief(workroom: Workroom, nodes: SessionGraphNode[]): string {
  const selected = nodes.filter((node) => workroom.selectedSessionIds.includes(node.session.id))
  const visible = selected.filter((node) => effectiveSyncPolicy(node.session) !== 'private')
  const omitted = selected.length - visible.length
  const payloads = visible.map((node) => {
    const policy = effectiveSyncPolicy(node.session)
    const preview = buildSyncPayloadPreview(node, policy)
    return [
      `Session: ${node.session.id}`,
      `Policy: ${policy}`,
      JSON.stringify(preview.payload, null, 2),
    ].join('\n')
  })

  return [
    `Workroom: ${workroom.name}`,
    `Purpose: ${workroom.purpose}`,
    omitted > 0 ? `Private sessions omitted: ${omitted}` : 'Private sessions omitted: 0',
    '',
    payloads.join('\n\n') || 'No team-visible sessions in this workroom.',
  ].join('\n')
}

function titleFor(
  view: WorkLayerView,
  t: (key: string, params?: Record<string, string | number>) => string,
): { kicker: string; title: string; subtitle: string } {
  switch (view) {
    case 'team':
      return {
        kicker: t('work.team.kicker'),
        title: t('work.team.title'),
        subtitle: t('work.team.subtitle'),
      }
    case 'workrooms':
      return {
        kicker: t('work.workrooms.kicker'),
        title: t('work.workrooms.title'),
        subtitle: t('work.workrooms.subtitle'),
      }
    case 'review':
      return {
        kicker: t('work.review.kicker'),
        title: t('work.review.title'),
        subtitle: t('work.review.subtitle'),
      }
    case 'memory':
      return {
        kicker: t('work.memory.kicker'),
        title: t('work.memory.title'),
        subtitle: t('work.memory.subtitle'),
      }
  }
}

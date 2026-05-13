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
    <main className="work-layer" aria-label={t('work.aria')}>
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
          aria-label={t('work.searchAria')}
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
  const { t } = useI18n()
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
      onDeliveryMessage(result.ok ? t('feishu.blockedSent') : result.error ?? t('feishu.blockedFailed'))
    } catch (err) {
      onDeliveryMessage((err as Error).message)
    }
  }
  return (
    <div className="work-layer__grid">
      <section className="work-layer__panel work-layer__wide">
        <div className="work-layer__panel-head">
          <div>
            <h2>{t('team.radarTitle')}</h2>
            <p>{t('team.radarSubtitle')}</p>
          </div>
          <Users size={18} aria-hidden />
        </div>
        <div className="work-layer__radar-stats">
          <RadarStat label={t('team.needsAttention')} value={needsAttention.length} tone="danger" />
          <RadarStat label={t('team.running')} value={running.length} tone="info" />
          <RadarStat label={t('team.reviewReady')} value={reviewReady.length} tone="warning" />
          <RadarStat label={t('team.recentlyDone')} value={done.length} tone="success" />
        </div>
      </section>
      <section className="work-layer__panel work-layer__wide">
        <div className="work-layer__panel-head">
          <div>
            <h2>{t('team.needsAttention')}</h2>
            <p>{t('team.needsAttentionSubtitle')}</p>
          </div>
          <AlertTriangle size={18} aria-hidden />
        </div>
        <RadarSessionList
          nodes={needsAttention.slice(0, 8)}
          onOpenSession={onOpenSession}
          onShowInMap={onShowInMap}
          empty={visible.length === 0 ? t('team.noVisibleSessions') : t('team.noVisibleBlockers')}
        />
      </section>
      <section className="work-layer__panel">
        <h2>{t('team.activeWork')}</h2>
        <RadarSessionList
          nodes={running.slice(0, 5)}
          onOpenSession={onOpenSession}
          onShowInMap={onShowInMap}
          empty={t('team.noRunning')}
          compact
        />
      </section>
      <section className="work-layer__panel">
        <h2>{t('team.readyDone')}</h2>
        <MetricRows rows={[
          [t('team.reviewReady'), reviewReady.length],
          [t('team.completed'), done.length],
          [t('team.visibleSessions'), visible.length],
          [t('team.privateLocal'), privateCount],
        ]} />
      </section>
      <section className="work-layer__panel">
        <h2>{t('feishu.delivery')}</h2>
        <StatusRows rows={[
          [t('feishu.status'), feishu?.deliveryStatus ?? t('feishu.notConfigured')],
          [t('feishu.defaultGroup'), feishu?.defaultGroupName || feishu?.defaultGroupId || t('feishu.notSet')],
          [t('feishu.lastSent'), feishu?.lastSentAt ? new Date(feishu.lastSentAt).toLocaleString() : t('feishu.never')],
          [t('feishu.lastError'), feishu?.lastError ?? t('feishu.none')],
        ]} />
        {deliveryMessage && <p className="work-layer__muted">{deliveryMessage}</p>}
        <button className="ghost" type="button" onClick={() => void sendBlocked()} disabled={needsAttention.length === 0}>
          {t('feishu.sendBlocked')}
        </button>
      </section>
      <section className="work-layer__panel">
        <div className="work-layer__panel-head">
          <div>
            <h2>{t('team.visibilityBoundary')}</h2>
            <p>{t('team.visibilitySubtitle')}</p>
          </div>
          <Shield size={18} aria-hidden />
        </div>
        <StatusRows rows={[
          [t('team.visibleSessions'), `${visible.length}`],
          [t('team.privateLocal'), `${privateCount}`],
          [t('team.hiddenBlockers'), `${Math.max(0, hiddenAttention)}`],
          [t('team.fullTranscript'), `${visible.filter((node) => effectiveSyncPolicy(node.session) === 'fullTranscript').length}`],
        ]} />
      </section>
      <section className="work-layer__panel work-layer__wide">
        <div className="work-layer__panel-head">
          <div>
            <h2>{t('team.slices')}</h2>
            <p>{t('team.slicesSubtitle')}</p>
          </div>
        </div>
        <div className="work-layer__slice-grid">
          <MetricRows rows={ownerRows.length > 0 ? ownerRows : [[t('team.noVisibleSessions'), 0]]} />
          <MetricRows rows={repoRows.length > 0 ? repoRows : [[t('team.noRepos'), 0]]} />
          <MetricRows rows={providerRows.length > 0 ? providerRows : [[t('team.noProviders'), 0]]} />
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
  const { t } = useI18n()
  const [selectedIds, setSelectedIds] = useState<string[]>(() => nodes.slice(0, 2).map((node) => node.session.id))
  const [name, setName] = useState('Handoff room')
  const [purpose, setPurpose] = useState('Rescue or review selected AI sessions.')
  const [commentBody, setCommentBody] = useState('')
  const [selectModalOpen, setSelectModalOpen] = useState(false)
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
      onDeliveryMessage(result.ok ? t('feishu.handoffSent') : result.error ?? t('feishu.handoffFailed'))
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
      onDeliveryMessage(result.ok ? `${t('feishu.handoffDocCreated')}${result.url ? `: ${result.url}` : '.'}` : result.error ?? t('feishu.docFailed'))
    } catch (err) {
      onDeliveryMessage((err as Error).message)
    }
  }

  return (
    <>
    <div className="work-layer__grid">
      <section className="work-layer__panel">
        <h2>{t('workroom.createTitle')}</h2>
        <label className="work-layer__field">
          <span>{t('workroom.name')}</span>
          <input value={name} onChange={(event) => setName(event.target.value)} />
        </label>
        <label className="work-layer__field">
          <span>{t('workroom.purpose')}</span>
          <textarea value={purpose} onChange={(event) => setPurpose(event.target.value)} />
        </label>
        <div className="work-layer__selected-summary">
          <div>
            <strong>{t('workroom.selectedSessions')}</strong>
            <span>{t('workroom.selectedCount', { count: selectedIds.length })}</span>
          </div>
          <button className="ghost" type="button" onClick={() => setSelectModalOpen(true)}>
            {t('workroom.selectSessions')}
          </button>
        </div>
        <SessionPills nodes={selectedNodes.slice(0, 3)} onOpenSession={onOpenSession} onShowInMap={onShowInMap} />
        <button className="primary" type="button" onClick={create} disabled={selectedIds.length === 0}>
          {t('workroom.createFrom', { count: selectedIds.length })}
        </button>
      </section>
      <section className="work-layer__panel">
        <h2>{t('workroom.listTitle')}</h2>
        {workrooms.length === 0 ? (
          <p className="work-layer__muted">{t('workroom.empty')}</p>
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
            <h2>{t('workroom.combinedHandoff')}</h2>
            <p>{t('workroom.handoffSubtitle')}</p>
          </div>
          <MessageSquare size={18} aria-hidden />
        </div>
        {activeWorkroom ? (
          <>
            <pre className="work-layer__handoff">{handoff}</pre>
            <SessionPills nodes={nodes.filter((node) => activeWorkroom.selectedSessionIds.includes(node.session.id))} onOpenSession={onOpenSession} onShowInMap={onShowInMap} />
          </>
        ) : (
          <p className="work-layer__muted">{t('workroom.createForHandoff')}</p>
        )}
      </section>
      <section className="work-layer__panel work-layer__wide">
        <div className="work-layer__panel-head">
          <div>
            <h2>{t('workroom.commentsActions')}</h2>
            <p>{t('workroom.commentsSubtitle')}</p>
          </div>
        </div>
        {activeWorkroom ? (
          <>
            <div className="work-layer__comments">
              {activeWorkroom.comments.length === 0 ? (
                <p className="work-layer__muted">{t('workroom.noComments')}</p>
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
                placeholder={t('workroom.commentPlaceholder')}
              />
              <button type="button" className="primary" onClick={addComment} disabled={!commentBody.trim()}>
                {t('workroom.addComment')}
              </button>
              <button
                type="button"
                className="ghost"
                onClick={() => {
                  if (window.confirm(t('workroom.prepareConfirm'))) {
                    setCommentBody(t('workroom.preparedContext'))
                  }
                }}
              >
                {t('workroom.prepareSendContext')}
              </button>
              <button type="button" className="ghost" onClick={() => void sendHandoffCard()} disabled={!feishu?.configured}>
                {t('feishu.sendToGroup')}
              </button>
              <button type="button" className="ghost" onClick={() => void createHandoffDoc()} disabled={!feishu?.configured}>
                {t('feishu.createHandoffDoc')}
              </button>
              <button
                type="button"
                className="ghost"
                onClick={() => void navigator.clipboard?.writeText(feishuHandoff)}
              >
                {t('feishu.copyBrief')}
              </button>
            </div>
          </>
        ) : (
          <p className="work-layer__muted">{t('workroom.createForComments')}</p>
        )}
      </section>
    </div>
    {selectModalOpen && (
      <div className="work-layer__modal-backdrop" role="presentation">
        <div className="work-layer__modal" role="dialog" aria-modal="true" aria-label={t('workroom.selectSessions')}>
          <div className="work-layer__modal-head">
            <div>
              <h2>{t('workroom.selectSessions')}</h2>
              <p>{t('workroom.selectSubtitle')}</p>
            </div>
            <button className="ghost" type="button" onClick={() => setSelectModalOpen(false)}>
              {t('action.done')}
            </button>
          </div>
          <div className="work-layer__checklist work-layer__checklist--modal">
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
        </div>
      </div>
    )}
    </>
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
  const { t } = useI18n()
  const repos = [...new Set(nodes.map((node) => node.repo))]
  const [repo, setRepo] = useState(repos[0] ?? '')
  const scoped = nodes.filter((node) => !repo || node.repo === repo)
  const artifacts = scoped.flatMap((node) => inferArtifacts(node).map((artifact) => ({ ...artifact, session: node.session.title })))
  return (
    <div className="work-layer__grid">
      <section className="work-layer__panel">
        <h2>{t('review.scope')}</h2>
        <label className="work-layer__field">
          <span>{t('review.repoProject')}</span>
          <select value={repo} onChange={(event) => setRepo(event.target.value)}>
            {repos.map((r) => <option key={r} value={r}>{r}</option>)}
          </select>
        </label>
        <MetricRows rows={[
          [t('review.relatedSessions'), scoped.length],
          [t('review.risks'), scoped.reduce((sum, node) => sum + node.risks.length, 0)],
          [t('review.artifacts'), artifacts.length],
        ]} />
      </section>
      <section className="work-layer__panel work-layer__wide">
        <div className="work-layer__panel-head">
          <div>
            <h2>{t('review.relatedSessions')}</h2>
            <p>{t('review.relatedSubtitle')}</p>
          </div>
          <GitPullRequest size={18} aria-hidden />
        </div>
        <SessionPills nodes={scoped} onOpenSession={onOpenSession} onShowInMap={onShowInMap} />
      </section>
      <section className="work-layer__panel">
        <h2>{t('review.evidence')}</h2>
        {artifacts.length === 0 ? (
          <p className="work-layer__muted">{t('review.noEvidence')}</p>
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
        <h2>{t('review.integrationSlots')}</h2>
        <StatusRows rows={[
          [t('review.githubChecks'), t('review.notConnected')],
          [t('review.issueLink'), t('review.lightLinkOnly')],
          [t('review.ciDeploy'), t('review.pendingIntegration')],
          [t('review.reviewerBrief'), scoped.length > 0 ? t('review.readyFromLocal') : t('review.noSessions')],
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
  const { t } = useI18n()
  const visible = nodes.filter((node) => effectiveSyncPolicy(node.session) !== 'private')
  const fullTranscript = nodes.filter((node) => effectiveSyncPolicy(node.session) === 'fullTranscript').length
  const privateCount = nodes.length - visible.length
  const standup = [
    ...graph.buckets.needsAttention.slice(0, 4).map((node) => `${t('memory.blocked')}: ${node.session.title} - ${node.risks[0]?.label ?? node.currentStep}`),
    ...graph.buckets.running.slice(0, 4).map((node) => `${t('memory.running')}: ${node.session.title} - ${node.currentStep}`),
    ...graph.buckets.recentlyCompleted.slice(0, 4).map((node) => `${t('memory.done')}: ${node.session.title}`),
  ]
  const standupText = standup.join('\n') || t('memory.noLocalActivity')
  const feishuStandupText = visible
    .slice(0, 12)
    .map((node) => {
      const preview = buildSyncPayloadPreview(node, effectiveSyncPolicy(node.session))
      return `- ${node.session.status}: ${JSON.stringify(preview.payload)}`
    })
    .join('\n') || t('memory.noVisibleActivity')
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
      onDeliveryMessage(result.ok ? t('feishu.standupSent') : result.error ?? t('feishu.standupFailed'))
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
      onDeliveryMessage(result.ok ? `${t('feishu.standupDocCreated')}${result.url ? `: ${result.url}` : '.'}` : result.error ?? t('feishu.standupDocFailed'))
    } catch (err) {
      onDeliveryMessage((err as Error).message)
    }
  }
  return (
    <div className="work-layer__grid">
      <section className="work-layer__panel">
        <div className="work-layer__panel-head">
          <div>
            <h2>{t('memory.standup')}</h2>
            <p>{t('memory.standupSubtitle')}</p>
          </div>
          <History size={18} aria-hidden />
        </div>
        <pre className="work-layer__handoff">{standupText}</pre>
        <div className="work-layer__comment-box">
          <button className="ghost" type="button" onClick={() => void createStandupDoc()} disabled={!feishu?.configured || visible.length === 0}>
            {t('memory.generateStandup')}
          </button>
          <button className="ghost" type="button" onClick={() => void sendStandup()} disabled={!feishu?.configured || visible.length === 0}>
            {t('memory.sendStandup')}
          </button>
        </div>
      </section>
      <section className="work-layer__panel">
        <h2>{t('memory.throughput')}</h2>
        <MetricRows rows={[
          [t('memory.totalSessions'), nodes.length],
          [t('memory.running'), graph.buckets.running.length],
          [t('memory.blockedAttention'), graph.buckets.needsAttention.length],
          [t('memory.completed'), graph.buckets.recentlyCompleted.length],
        ]} />
      </section>
      <section className="work-layer__panel">
        <h2>{t('memory.privacyAudit')}</h2>
        <MetricRows rows={[
          [t('memory.private'), privateCount],
          [t('memory.teamVisible'), visible.length],
          [t('memory.fullTranscript'), fullTranscript],
          [t('memory.metadataOrSafer'), nodes.length - fullTranscript],
        ]} />
      </section>
      <section className="work-layer__panel work-layer__wide">
        <h2>{t('memory.retentionGovernance')}</h2>
        <StatusRows rows={[
          [t('memory.defaultSync'), t('memory.defaultSyncValue')],
          [t('memory.transcript'), t('memory.transcriptValue')],
          [t('memory.enterpriseAudit'), t('memory.plannedIntegration')],
          [t('memory.selfHost'), t('memory.plannedDeployment')],
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
  const { t } = useI18n()
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
            <button className="ghost icon-only" type="button" onClick={() => onShowInMap(node.session.id)} aria-label={t('action.showInMap')}>
              <Map size={15} aria-hidden />
            </button>
            <button className="ghost icon-only" type="button" onClick={() => onOpenSession(node.session.id)} aria-label={t('action.openDetail')}>
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
  const { t } = useI18n()
  if (nodes.length === 0) return <p className="work-layer__muted">{t('session.noRelated')}</p>
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
            <button className="ghost icon-only" type="button" onClick={() => onShowInMap(node.session.id)} aria-label={t('action.showInMap')}>
              <Map size={15} aria-hidden />
            </button>
            <button className="ghost icon-only" type="button" onClick={() => onOpenSession(node.session.id)} aria-label={t('action.openDetail')}>
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

import { useState } from 'react'
import type {
  CanvasSceneAction,
  CanvasSceneNodeAnchor,
  CanvasSceneSpec,
  PlannerArtifact,
  PlanningNode,
} from '../../types'

interface CanvasSceneLayerProps {
  sceneSpec: CanvasSceneSpec | null | undefined
  nodes: PlanningNode[]
  artifacts: PlannerArtifact[]
  onOpenNode: (nodeId: string) => void
  onSceneAction: (nodeId: string, actionId: string, payload?: CanvasSceneActionPayload) => void
}

type SceneRecord = Record<string, unknown>
export type PokerUserRole = 'observer' | 'gm' | 'player' | 'all-ai'
export interface CanvasSceneActionPayload {
  userRole?: PokerUserRole | string
  controlledPlayerId?: string | null
  autoRun?: boolean
}

export function CanvasSceneLayer({
  sceneSpec,
  nodes,
  artifacts,
  onOpenNode,
  onSceneAction,
}: CanvasSceneLayerProps) {
  if (!sceneSpec) return null

  const state = resolveCanvasSceneState(sceneSpec, artifacts)
  const nodesById = new Map(nodes.map((node) => [node.id, node]))
  const anchors = sceneSpec.nodeAnchors ?? []
  const actions = sceneSpec.actions ?? []

  return (
    <section className={`canvas-scene canvas-scene--${cssToken(sceneSpec.kind)}`} aria-label="Canvas scene">
      <div className="canvas-scene__stage">
        {sceneSpec.kind === 'poker-table'
          ? (
              <PokerScene
                state={state}
                anchors={anchors}
                actions={actions}
                nodesById={nodesById}
                onOpenNode={onOpenNode}
                onSceneAction={onSceneAction}
              />
            )
          : (
              <TravelScene
                state={state}
                anchors={anchors}
                actions={actions}
                nodesById={nodesById}
                onOpenNode={onOpenNode}
                onSceneAction={onSceneAction}
              />
            )}
      </div>
    </section>
  )
}

export function resolveCanvasSceneState(
  sceneSpec: CanvasSceneSpec,
  artifacts: PlannerArtifact[],
): SceneRecord {
  let state = cloneRecord(asRecord(sceneSpec.initialState))
  for (const binding of sceneSpec.artifactBindings ?? []) {
    const artifact = latestArtifactForBinding(artifacts, binding.nodeId, binding.reference)
    if (!artifact) continue
    const patch = extractScenePayload(artifact.payload ?? artifact.typedPayload)
    if (binding.mode === 'replace') {
      state = asRecord(patch) ? cloneRecord(asRecord(patch)) : state
      continue
    }
    const patchRecord = asRecord(patch)
    if (patchRecord) {
      state = mergeSceneRecord(state, patchRecord)
    } else if (patch !== undefined && patch !== null) {
      state = { ...state, [binding.id]: patch }
    }
  }
  return state
}

function TravelScene({
  state,
  anchors,
  actions,
  nodesById,
  onOpenNode,
  onSceneAction,
}: {
  state: SceneRecord
  anchors: CanvasSceneNodeAnchor[]
  actions: CanvasSceneAction[]
  nodesById: Map<string, PlanningNode>
  onOpenNode: (nodeId: string) => void
  onSceneAction: (nodeId: string, actionId: string, payload?: CanvasSceneActionPayload) => void
}) {
  const route = readArray(state.route)
  const timeline = readArray(state.timeline)
  const hotels = readArray(state.hotels)
  const budget = asRecord(state.budget)

  return (
    <div className="canvas-scene-travel">
      <div className="canvas-scene__copy">
        <strong>{readString(state.title, 'Travel Squad')}</strong>
        <span>{readString(state.summary, '路线、酒店、美食和预算由节点产出的 artifacts 推进。')}</span>
      </div>
      <div className="canvas-scene-travel__map">
        <svg viewBox="0 0 100 100" role="img" aria-label="Travel route">
          <polyline
            points={route.map((stop) => `${readNumber(asRecord(stop)?.x, 0)},${readNumber(asRecord(stop)?.y, 0)}`).join(' ')}
            fill="none"
            stroke="currentColor"
            strokeWidth="1.8"
            strokeDasharray="4 3"
          />
          {route.map((stop, index) => {
            const item = asRecord(stop) ?? {}
            const x = readNumber(item.x, 12 + index * 28)
            const y = readNumber(item.y, 50)
            return (
              <g key={readString(item.id, String(index))} transform={`translate(${x} ${y})`}>
                <circle r="4.5" />
                <text y="-7">{readString(item.label, `Stop ${index + 1}`)}</text>
                <text y="10">{readString(item.days, '')}</text>
              </g>
            )
          })}
        </svg>
        <div className="canvas-scene-travel__nodes" aria-label="Travel scene nodes">
          {anchors.map((anchor) => (
            <SceneNodeButton
              key={anchor.id}
              anchor={anchor}
              node={nodesById.get(anchor.nodeId)}
              className="canvas-scene-travel__node"
              onOpenNode={onOpenNode}
            />
          ))}
        </div>
      </div>
      <div className="canvas-scene-travel__panels">
        <SceneList title="行程" items={timeline} primaryKey="day" secondaryKey="title" />
        <SceneList title="住宿" items={hotels} primaryKey="city" secondaryKey="title" />
        <div className="canvas-scene-card">
          <span>预算</span>
          <strong>{readString(budget?.label, '等待预算输入')}</strong>
        </div>
        <SceneActions
          actions={actions}
          nodesById={nodesById}
          onSceneAction={onSceneAction}
        />
      </div>
    </div>
  )
}

function PokerScene({
  state,
  anchors,
  actions,
  nodesById,
  onOpenNode,
  onSceneAction,
}: {
  state: SceneRecord
  anchors: CanvasSceneNodeAnchor[]
  actions: CanvasSceneAction[]
  nodesById: Map<string, PlanningNode>
  onOpenNode: (nodeId: string) => void
  onSceneAction: (nodeId: string, actionId: string, payload?: CanvasSceneActionPayload) => void
}) {
  const players = readArray(state.players)
  const actionLog = readArray(state.actionLog)
  const communityCards = normalizePokerCards(readArray(state.communityCards), 5)
  const anchorsById = new Map(anchors.map((anchor) => [anchor.id, anchor]))
  const gmAnchor = anchorsById.get('gm')
  const phase = readString(state.phase, 'Pre-flop')
  const pot = readString(state.pot, '0')
  const setup = asRecord(state.setup) ?? {}
  const started = readBoolean(setup.started, false)
  const activeRole = readString(setup.userRole, 'observer') as PokerUserRole
  const controlledPlayerId = readString(setup.controlledPlayerId, '')
  const autoRun = readBoolean(setup.autoRun, true)
  const nextActor = readString(state.nextActor, readString(state.nextAction, 'TBD')).toLowerCase()
  const nextAction = readString(state.nextAction, nextActor || 'TBD')
  const [selectedRole, setSelectedRole] = useState<PokerUserRole>(activeRole || 'observer')
  const [selectedPlayer, setSelectedPlayer] = useState(controlledPlayerId || 'ada')
  const startAction = actions.find((action) => action.id === 'start-game') ?? actions.find((action) => action.nodeId === gmAnchor?.nodeId)
  const rolePlayerId = selectedRole === 'player' ? selectedPlayer : null

  return (
    <div className="canvas-scene-poker">
      <div className="canvas-scene-poker__table-zone">
        <div className="canvas-scene__copy canvas-scene-poker__header">
          <strong>{readString(state.title, 'Poker Table')}</strong>
          <span>{started ? `${phase} · Pot ${pot} · Next ${nextAction}` : 'Role setup · Rules Orchestrator not started'}</span>
        </div>
        <div className="canvas-scene-poker__felt">
          <div className="canvas-scene-poker__community">
            {communityCards.map((card, index) => (
              <span key={`${String(card)}-${index}`} className="canvas-scene-poker__card">{String(card)}</span>
            ))}
          </div>
          {players.map((player, index) => {
            const item = asRecord(player) ?? {}
            const playerId = readString(item.id, String(index))
            const anchor = anchorsById.get(playerId)
            const node = anchor ? nodesById.get(anchor.nodeId) : undefined
            const seat = cssToken(readString(item.seat, `seat-${index}`))
            const stack = readString(item.stack, '0')
            const playerStatus = readString(item.status, 'waiting')
            const canSeeHand = canSeePokerHand(activeRole, controlledPlayerId, playerId)
            const cards = normalizePokerCards(readArray(item.holeCards), playerId === 'dealer' ? 0 : 2)
            const contents = (
              <>
                <strong>{node?.title ?? readString(item.name, `Player ${index + 1}`)}</strong>
                <span>{playerId === 'dealer' ? playerStatus : `${readString(item.style, playerStatus)} · ${stack}`}</span>
                {cards.length > 0 && (
                  <span className="canvas-scene-poker__hole-cards">
                    {cards.map((card, cardIndex) => (
                      <b key={`${playerId}-${cardIndex}`}>{canSeeHand ? String(card) : '??'}</b>
                    ))}
                  </span>
                )}
                <em>{playerId === nextActor ? '轮到行动' : `${node?.status ?? playerStatus}`}</em>
              </>
            )
            if (anchor) {
              return (
                <button
                  key={playerId}
                  type="button"
                  className={`canvas-scene-poker__seat canvas-scene-poker__seat--${seat} ${node ? `is-${node.status}` : 'is-missing'} ${playerId === nextActor ? 'is-next' : ''} ${node?.executionMode === 'human' ? 'is-human' : ''}`}
                  onClick={() => onOpenNode(anchor.nodeId)}
                  title={node ? `${anchor.label}: ${node.title}` : anchor.label}
                >
                  {contents}
                </button>
              )
            }
            return (
              <div key={playerId} className={`canvas-scene-poker__seat canvas-scene-poker__seat--${seat}`}>
                {contents}
              </div>
            )
          })}
          {gmAnchor && (
            <SceneNodeButton
              anchor={gmAnchor}
              node={nodesById.get(gmAnchor.nodeId)}
              className="canvas-scene-poker__gm"
              onOpenNode={onOpenNode}
            />
          )}
        </div>
      </div>
      <div className="canvas-scene-poker__rail">
        {!started ? (
          <PokerRoleSetup
            actions={actions}
            selectedRole={selectedRole}
            selectedPlayer={selectedPlayer}
            onRoleChange={setSelectedRole}
            onPlayerChange={setSelectedPlayer}
            onStart={() => {
              if (!startAction) return
              onSceneAction(startAction.nodeId, 'start-game', {
                userRole: selectedRole,
                controlledPlayerId: rolePlayerId,
                autoRun: true,
              })
            }}
          />
        ) : (
          <>
            <div className="canvas-scene-poker__stats">
              <span>PHASE <strong>{phase}</strong></span>
              <span>POT <strong>{pot}</strong></span>
              <span>NEXT <strong>{nextAction}</strong></span>
            </div>
            <PokerAutomationPanel
              actions={actions}
              nextAction={nextActor}
              anchors={anchors}
              nodesById={nodesById}
              autoRun={autoRun}
              onSceneAction={onSceneAction}
            />
          </>
        )}
        <div className="canvas-scene-poker__log">
          <strong>Action log</strong>
          {actionLog.slice(-5).map((entry, index) => (
            <span key={`${String(entry)}-${index}`}>{String(entry)}</span>
          ))}
        </div>
      </div>
    </div>
  )
}

function PokerRoleSetup({
  actions,
  selectedRole,
  selectedPlayer,
  onRoleChange,
  onPlayerChange,
  onStart,
}: {
  actions: CanvasSceneAction[]
  selectedRole: PokerUserRole
  selectedPlayer: string
  onRoleChange: (role: PokerUserRole) => void
  onPlayerChange: (playerId: string) => void
  onStart: () => void
}) {
  const canStart = actions.some((action) => action.id === 'start-game')
  const roles: Array<{ id: PokerUserRole; label: string; detail: string }> = [
    { id: 'observer', label: 'Observer', detail: '观察牌局，AI 玩家自动行动' },
    { id: 'gm', label: 'GM', detail: '你负责裁判审批，玩家由 AI 执行' },
    { id: 'player', label: 'Player', detail: '你控制一个玩家，轮到你时暂停' },
    { id: 'all-ai', label: 'All AI', detail: '玩家全部由 AI 执行，GM 仍可审批异常' },
  ]

  return (
    <div className="canvas-scene-poker__setup" aria-label="Poker role setup">
      <div className="canvas-scene-poker__automation-head">
        <span>ROLE SETUP</span>
        <strong>选择你在牌桌里的角色</strong>
      </div>
      <div className="canvas-scene-poker__role-grid">
        {roles.map((role) => (
          <button
            key={role.id}
            type="button"
            className={selectedRole === role.id ? 'is-selected' : ''}
            onClick={() => onRoleChange(role.id)}
          >
            <span>{role.label}</span>
            <small>{role.detail}</small>
          </button>
        ))}
      </div>
      {selectedRole === 'player' && (
        <div className="canvas-scene-poker__player-select" aria-label="Choose player">
          {['ada', 'bruno', 'mina'].map((playerId) => (
            <button
              key={playerId}
              type="button"
              className={selectedPlayer === playerId ? 'is-selected' : ''}
              onClick={() => onPlayerChange(playerId)}
            >
              {playerId[0].toUpperCase() + playerId.slice(1)}
            </button>
          ))}
        </div>
      )}
      <button
        type="button"
        className="canvas-scene-poker__start"
        onClick={onStart}
        disabled={!canStart}
      >
        Start Game
      </button>
    </div>
  )
}

function PokerAutomationPanel({
  actions,
  nextAction,
  anchors,
  nodesById,
  autoRun,
  onSceneAction,
}: {
  actions: CanvasSceneAction[]
  nextAction: string
  anchors: CanvasSceneNodeAnchor[]
  nodesById: Map<string, PlanningNode>
  autoRun: boolean
  onSceneAction: (nodeId: string, actionId: string, payload?: CanvasSceneActionPayload) => void
}) {
  const current = pokerActionForNext(actions, nextAction, anchors, nodesById)
  const humanActions = actions.filter((action) => {
    if (current?.action.id === action.id) return false
    if (['start-game', 'step', 'resume-auto', 'pause-auto', 'next-street'].includes(action.id)) return false
    const node = nodesById.get(action.nodeId)
    return node?.executorType === 'human' || node?.executionMode === 'human'
  })
  const dealerAction = actions.find((action) => action.id === (autoRun ? 'pause-auto' : 'resume-auto'))
  const stepAction = actions.find((action) => action.id === 'step')

  return (
    <div className="canvas-scene-poker__automation" aria-label="Poker automation">
      <div className="canvas-scene-poker__automation-head">
        <span>下一步</span>
        <strong>{current?.node?.executionMode === 'human' ? '等待人工行动' : (current?.node?.title ?? '等待牌局状态')}</strong>
      </div>
      {current ? (
        <button
          type="button"
          className="canvas-scene-poker__auto-button"
          onClick={() => onSceneAction(current.action.nodeId, current.action.id)}
          disabled={!current.node || current.node.executorType === 'human' || current.node.executionMode === 'human'}
          aria-label={`执行：${current.action.label}`}
          title={`${current.action.label}: ${current.node?.title ?? 'Missing node'}`}
        >
          <span>执行：{current.action.label}</span>
          <small>{current.node?.title ?? current.action.label}</small>
        </button>
      ) : (
        <div className="canvas-scene-poker__auto-empty">等待 game-state.json</div>
      )}
      <div className="canvas-scene-poker__orchestrator-actions">
        {stepAction && (
          <button type="button" onClick={() => onSceneAction(stepAction.nodeId, stepAction.id)}>
            Step
          </button>
        )}
        {dealerAction && (
          <button type="button" onClick={() => onSceneAction(dealerAction.nodeId, dealerAction.id)}>
            {autoRun ? 'Pause' : 'Resume Auto'}
          </button>
        )}
      </div>
      {humanActions.length > 0 && (
        <div className="canvas-scene-poker__human-actions" aria-label="Human approvals">
          <strong>需要确认</strong>
          {humanActions.map((action) => {
            const node = nodesById.get(action.nodeId)
            return (
              <button
                key={action.id}
                type="button"
                onClick={() => onSceneAction(action.nodeId, action.id)}
                disabled={!node}
                aria-label={action.label}
                title={node ? `${action.label}: ${node.title}` : action.label}
              >
                <span>需要确认：{action.label}</span>
                <small>{node?.title ?? 'Missing node'}</small>
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

function pokerActionForNext(
  actions: CanvasSceneAction[],
  nextAction: string,
  anchors: CanvasSceneNodeAnchor[],
  nodesById: Map<string, PlanningNode>,
): { action: CanvasSceneAction; node: PlanningNode | undefined } | null {
  const normalized = cssToken(nextAction || '').replace(/^-+|-+$/g, '')
  const anchor = anchors.find((item) => cssToken(item.id) === normalized || cssToken(item.label) === normalized)
  const candidates = [
    `ask-${normalized}`,
    normalized === 'dealer' ? 'next-street' : '',
  ].filter(Boolean)
  const action = actions.find((item) => candidates.includes(item.id))
    ?? (anchor ? actions.find((item) => item.nodeId === anchor.nodeId && item.id !== 'gm-review') : undefined)
    ?? actions.find((item) => item.id === 'next-street')
  return action ? { action, node: nodesById.get(action.nodeId) } : null
}

function SceneNodeButton({
  anchor,
  node,
  className,
  onOpenNode,
}: {
  anchor: CanvasSceneNodeAnchor
  node: PlanningNode | undefined
  className: string
  onOpenNode: (nodeId: string) => void
}) {
  return (
    <button
      type="button"
      className={`canvas-scene-node ${className} canvas-scene-node--${cssToken(anchor.role ?? 'node')} ${node ? `is-${node.status}` : 'is-missing'}`}
      style={{ left: `${anchor.x}%`, top: `${anchor.y}%` }}
      onClick={() => onOpenNode(anchor.nodeId)}
      disabled={!node}
      title={node ? `${anchor.label}: ${node.title}` : anchor.label}
    >
      <span>{anchor.label}</span>
      {node && <em>{node.status}</em>}
    </button>
  )
}

function SceneActions({
  actions,
  nodesById,
  onSceneAction,
}: {
  actions: CanvasSceneAction[]
  nodesById: Map<string, PlanningNode>
  onSceneAction: (nodeId: string, actionId: string, payload?: CanvasSceneActionPayload) => void
}) {
  if (actions.length === 0) return null
  return (
    <div className="canvas-scene__actions" aria-label="Scene actions">
      {actions.map((action) => {
        const node = nodesById.get(action.nodeId)
        return (
          <button
            key={action.id}
            type="button"
            onClick={() => onSceneAction(action.nodeId, action.id)}
            disabled={!node}
            aria-label={action.label}
            title={node ? `${action.label}: ${node.title}` : action.label}
          >
            <span>{action.label}</span>
            <small>{node?.title ?? 'Missing node'}</small>
          </button>
        )
      })}
    </div>
  )
}

function SceneList({
  title,
  items,
  primaryKey,
  secondaryKey,
}: {
  title: string
  items: unknown[]
  primaryKey: string
  secondaryKey: string
}) {
  return (
    <div className="canvas-scene-card">
      <span>{title}</span>
      {items.slice(0, 4).map((item, index) => {
        const record = asRecord(item) ?? {}
        return (
          <p key={`${title}-${index}`}>
            <strong>{readString(record[primaryKey], `#${index + 1}`)}</strong>
            <em>{readString(record[secondaryKey], '')}</em>
          </p>
        )
      })}
    </div>
  )
}

function latestArtifactForBinding(
  artifacts: PlannerArtifact[],
  nodeId: string,
  reference: string,
): PlannerArtifact | null {
  const normalized = normalizeRef(reference)
  let latest: PlannerArtifact | null = null
  for (const artifact of artifacts) {
    if (artifact.nodeId !== nodeId) continue
    if (normalizeRef(artifact.reference) !== normalized) continue
    if (!latest || Date.parse(artifact.createdAt) > Date.parse(latest.createdAt)) {
      latest = artifact
    }
  }
  return latest
}

function extractScenePayload(payload: unknown): unknown {
  const record = asRecord(payload)
  if (!record) return payload
  if (asRecord(record.sceneState)) return record.sceneState
  if (asRecord(record.json)) return record.json
  if (asRecord(record.data)) return record.data
  if (typeof record.text === 'string') {
    try {
      return JSON.parse(record.text)
    } catch {
      return record.text
    }
  }
  return payload
}

function mergeSceneRecord(base: SceneRecord, patch: SceneRecord): SceneRecord {
  const next: SceneRecord = { ...base }
  for (const [key, value] of Object.entries(patch)) {
    const current = asRecord(next[key])
    const incoming = asRecord(value)
    next[key] = current && incoming ? mergeSceneRecord(current, incoming) : value
  }
  return next
}

function cloneRecord(record: SceneRecord | null): SceneRecord {
  if (!record) return {}
  return JSON.parse(JSON.stringify(record)) as SceneRecord
}

function asRecord(value: unknown): SceneRecord | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as SceneRecord
    : null
}

function readArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function readString(value: unknown, fallback: string): string {
  if (typeof value === 'string' && value.trim()) return value
  if (typeof value === 'number') return String(value)
  return fallback
}

function readBoolean(value: unknown, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value : fallback
}

function readNumber(value: unknown, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

function normalizePokerCards(cards: unknown[], count: number): unknown[] {
  if (count <= 0) return []
  const next = cards.length > 0 ? cards.slice(0, count) : []
  while (next.length < count) next.push('??')
  return next
}

function canSeePokerHand(role: string, controlledPlayerId: string, playerId: string): boolean {
  if (playerId === 'dealer') return true
  if (role === 'gm') return true
  if (role === 'player') return controlledPlayerId.toLowerCase() === playerId.toLowerCase()
  return false
}

function normalizeRef(value: string): string {
  return value.trim().toLowerCase()
}

function cssToken(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9_-]+/g, '-')
}

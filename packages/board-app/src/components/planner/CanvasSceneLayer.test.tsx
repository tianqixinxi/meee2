import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { CanvasSceneSpec, PlannerArtifact, PlanningNode } from '../../types'
import { CanvasSceneLayer, resolveCanvasSceneState } from './CanvasSceneLayer'

function artifact(overrides: Partial<PlannerArtifact> = {}): PlannerArtifact {
  return {
    id: 'artifact-1',
    canvasId: 'canvas-1',
    nodeId: 'node-1',
    kind: 'generic',
    title: 'Scene artifact',
    reference: 'itinerary.json',
    status: 'attached',
    createdAt: '2026-06-01T00:00:00Z',
    ...overrides,
  }
}

function node(overrides: Partial<PlanningNode> = {}): PlanningNode {
  return {
    id: 'node-1',
    canvasId: 'canvas-1',
    title: '路线规划 Agent',
    schema: {
      inputs: [],
      outputs: ['itinerary.json'],
      goal: 'Update the scene state.',
    },
    contextSources: [],
    executionMode: 'auto',
    executorType: 'claude',
    doerId: 'agent',
    reviewerIds: [],
    approverIds: [],
    handoffPolicy: 'none',
    status: 'ready',
    ...overrides,
  }
}

describe('CanvasSceneLayer', () => {
  it('uses the latest matching artifact to advance scene state', () => {
    const sceneSpec: CanvasSceneSpec = {
      kind: 'travel-squad',
      initialState: {
        title: 'Original Trip',
        route: [{ id: 'tokyo', label: 'Tokyo' }],
        budget: { label: '$2,400' },
      },
      artifactBindings: [
        { id: 'itinerary', nodeId: 'node-1', reference: 'itinerary.json' },
      ],
    }

    const state = resolveCanvasSceneState(sceneSpec, [
      artifact({
        id: 'old',
        payload: { type: 'json', json: { title: 'Old Trip', budget: { label: '$2,700' } } },
        createdAt: '2026-06-01T00:00:00Z',
      }),
      artifact({
        id: 'new',
        payload: {
          type: 'json',
          json: {
            title: 'Updated Trip',
            route: [{ id: 'kyoto', label: 'Kyoto' }],
          },
        },
        createdAt: '2026-06-02T00:00:00Z',
      }),
    ])

    expect(state.title).toBe('Updated Trip')
    expect(state.route).toEqual([{ id: 'kyoto', label: 'Kyoto' }])
    expect(state.budget).toEqual({ label: '$2,400' })
  })

  it('opens node inspector from travel scene nodes and dispatches scene actions', () => {
    const openNode = vi.fn()
    const sceneAction = vi.fn()
    const sceneSpec: CanvasSceneSpec = {
      kind: 'travel-squad',
      initialState: {
        title: 'Travel Squad',
        summary: 'Scene state only.',
        route: [{ id: 'tokyo', label: 'Tokyo', x: 20, y: 60 }],
      },
      nodeAnchors: [
        { id: 'route-anchor', label: '路线', nodeId: 'node-1', x: 25, y: 35, role: 'agent' },
      ],
      actions: [
        { id: 'replan-route', label: '重算路线', nodeId: 'node-1' },
      ],
    }

    render(
      <CanvasSceneLayer
        sceneSpec={sceneSpec}
        nodes={[node()]}
        artifacts={[]}
        onOpenNode={openNode}
        onSceneAction={sceneAction}
      />,
    )

    fireEvent.click(screen.getByTitle('路线: 路线规划 Agent'))
    expect(openNode).toHaveBeenCalledWith('node-1')

    fireEvent.click(screen.getByRole('button', { name: '重算路线' }))
    expect(sceneAction).toHaveBeenCalledWith('node-1', 'replan-route')
  })

  it('renders poker seats as scene-native node entry points', () => {
    const openNode = vi.fn()
    const sceneSpec: CanvasSceneSpec = {
      kind: 'poker-table',
      initialState: {
        title: 'AI Poker Table',
        setup: { started: true, userRole: 'observer', controlledPlayerId: null, autoRun: true },
        phase: 'Pre-flop',
        pot: 150,
        nextActor: 'ada',
        nextAction: 'Ada',
        communityCards: ['??', '??', '??', '??', '??'],
        players: [
          { id: 'dealer', name: 'Dealer', stack: 0, status: 'active', seat: 'top', holeCards: [] },
          { id: 'ada', name: 'Ada', style: '紧凶型', stack: 950, status: 'to-act', seat: 'left', holeCards: ['As', 'Ks'] },
          { id: 'bruno', name: 'Bruno', style: '诈唬型', stack: 870, status: 'waiting', seat: 'right', holeCards: ['Qh', 'Js'] },
        ],
      },
      nodeAnchors: [
        { id: 'dealer', label: 'Dealer', nodeId: 'dealer-node', x: 50, y: 16, role: 'dealer' },
        { id: 'ada', label: 'Ada', nodeId: 'ada-node', x: 16, y: 52, role: 'player' },
        { id: 'bruno', label: 'Bruno', nodeId: 'bruno-node', x: 84, y: 52, role: 'player' },
        { id: 'gm', label: 'GM', nodeId: 'gm-node', x: 78, y: 18, role: 'approval' },
      ],
    }

    render(
      <CanvasSceneLayer
        sceneSpec={sceneSpec}
        nodes={[
          node({ id: 'dealer-node', title: 'Dealer / Table State', executorType: 'mock', executionMode: 'human' }),
          node({ id: 'ada-node', title: 'Ada 玩家 Agent' }),
          node({ id: 'bruno-node', title: 'Bruno 玩家 Agent' }),
          node({ id: 'gm-node', title: 'GM / 规则裁判', executorType: 'human', executionMode: 'human' }),
        ]}
        artifacts={[]}
        onOpenNode={openNode}
        onSceneAction={vi.fn()}
      />,
    )

    fireEvent.click(screen.getByTitle('Ada: Ada 玩家 Agent'))
    expect(openNode).toHaveBeenCalledWith('ada-node')
    expect(screen.getByText('Observer')).toBeInTheDocument()
    expect(screen.getByText('全桌手牌可见')).toBeInTheDocument()
    expect(screen.getByText('Rules Orchestrator')).toBeInTheDocument()
    expect(screen.getByText('game-state.json · action-log.json')).toBeInTheDocument()
    expect(screen.getByText(/no AI session/)).toBeInTheDocument()
    expect(screen.getByText('As')).toBeInTheDocument()
    expect(screen.getByText('Qh')).toBeInTheDocument()
    expect(screen.getByText('GM / 异常审批')).toBeInTheDocument()
    expect(screen.queryByLabelText('Scene node anchors')).not.toBeInTheDocument()
  })

  it('only reveals the controlled player hand when the user plays a seat', () => {
    const sceneSpec: CanvasSceneSpec = {
      kind: 'poker-table',
      initialState: {
        title: 'AI Poker Table',
        setup: { started: true, userRole: 'player', controlledPlayerId: 'ada', autoRun: true },
        phase: 'Pre-flop',
        pot: 150,
        nextActor: 'bruno',
        nextAction: 'Bruno',
        communityCards: ['??', '??', '??', '??', '??'],
        players: [
          { id: 'ada', name: 'Ada', style: '紧凶型', stack: 950, status: 'waiting', seat: 'left', holeCards: ['As', 'Ks'] },
          { id: 'bruno', name: 'Bruno', style: '诈唬型', stack: 870, status: 'to-act', seat: 'right', holeCards: ['Qh', 'Js'] },
        ],
      },
      nodeAnchors: [
        { id: 'ada', label: 'Ada', nodeId: 'ada-node', x: 16, y: 52, role: 'player' },
        { id: 'bruno', label: 'Bruno', nodeId: 'bruno-node', x: 84, y: 52, role: 'player' },
      ],
    }

    render(
      <CanvasSceneLayer
        sceneSpec={sceneSpec}
        nodes={[
          node({ id: 'ada-node', title: 'Ada 玩家 Agent' }),
          node({ id: 'bruno-node', title: 'Bruno 玩家 Agent' }),
        ]}
        artifacts={[]}
        onOpenNode={vi.fn()}
        onSceneAction={vi.fn()}
      />,
    )

    expect(screen.getByText('Play as Ada')).toBeInTheDocument()
    expect(screen.getByText('只看 Ada 手牌')).toBeInTheDocument()
    expect(screen.getByText('As')).toBeInTheDocument()
    expect(screen.queryByText('Qh')).not.toBeInTheDocument()
  })

  it('shows poker role setup before the rules orchestrator starts', () => {
    const sceneAction = vi.fn()
    const sceneSpec: CanvasSceneSpec = {
      kind: 'poker-table',
      initialState: {
        title: 'AI Poker Table',
        setup: { started: false, userRole: 'observer', controlledPlayerId: null, autoRun: true },
        communityCards: ['??', '??', '??', '??', '??'],
        players: [],
        actionLog: ['请选择你在牌桌里的角色，然后开始游戏。'],
      },
      actions: [
        { id: 'start-game', label: '开始游戏', nodeId: 'dealer-node' },
      ],
    }

    render(
      <CanvasSceneLayer
        sceneSpec={sceneSpec}
        nodes={[node({ id: 'dealer-node', title: 'Dealer / Table State', executorType: 'mock', executionMode: 'human' })]}
        artifacts={[]}
        onOpenNode={vi.fn()}
        onSceneAction={sceneAction}
      />,
    )

    expect(screen.getByText('ROLE SETUP')).toBeInTheDocument()
    fireEvent.click(screen.getByText('Player'))
    fireEvent.click(screen.getByText('Bruno'))
    fireEvent.click(screen.getByRole('button', { name: 'Start Game' }))
    expect(sceneAction).toHaveBeenCalledWith('dealer-node', 'start-game', {
      userRole: 'player',
      controlledPlayerId: 'bruno',
      autoRun: true,
    })
  })

  it('allows legacy poker scenes to start from the dealer anchor without a start-game action', () => {
    const sceneAction = vi.fn()
    const sceneSpec: CanvasSceneSpec = {
      kind: 'poker-table',
      initialState: {
        title: 'Legacy Poker Table',
        communityCards: ['??', '??', '??'],
        players: [],
      },
      nodeAnchors: [
        { id: 'dealer', label: 'Dealer', nodeId: 'dealer-node', x: 50, y: 16, role: 'dealer' },
      ],
      actions: [
        { id: 'next-street', label: '发下一轮牌', nodeId: 'dealer-node' },
      ],
    }

    render(
      <CanvasSceneLayer
        sceneSpec={sceneSpec}
        nodes={[node({ id: 'dealer-node', title: 'Dealer / Table State', executorType: 'mock', executionMode: 'human' })]}
        artifacts={[]}
        onOpenNode={vi.fn()}
        onSceneAction={sceneAction}
      />,
    )

    const start = screen.getByRole('button', { name: 'Start Game' })
    expect(start).not.toBeDisabled()
    fireEvent.click(start)
    expect(sceneAction).toHaveBeenCalledWith('dealer-node', 'start-game', {
      userRole: 'observer',
      controlledPlayerId: null,
      autoRun: true,
    })
  })

  it('uses a single poker next-step target and keeps GM in human confirmation', () => {
    const sceneAction = vi.fn()
    const sceneSpec: CanvasSceneSpec = {
      kind: 'poker-table',
      initialState: {
        title: 'AI Poker Table',
        setup: { started: true, userRole: 'observer', controlledPlayerId: null, autoRun: true },
        phase: 'Pre-flop',
        pot: 150,
        nextActor: 'ada',
        nextAction: 'Ada',
        communityCards: ['??', '??', '??', '??', '??'],
        players: [
          { id: 'ada', name: 'Ada', style: '紧凶型', stack: 950, status: 'to-act', seat: 'left', holeCards: ['As', 'Ks'] },
          { id: 'bruno', name: 'Bruno', style: '诈唬型', stack: 870, status: 'waiting', seat: 'right', holeCards: ['Qh', 'Js'] },
        ],
      },
      nodeAnchors: [
        { id: 'ada', label: 'Ada', nodeId: 'ada-node', x: 16, y: 52, role: 'player' },
        { id: 'bruno', label: 'Bruno', nodeId: 'bruno-node', x: 84, y: 52, role: 'player' },
        { id: 'gm', label: 'GM', nodeId: 'gm-node', x: 78, y: 18, role: 'approval' },
      ],
      actions: [
        { id: 'ask-ada', label: '要求 Ada 行动', nodeId: 'ada-node' },
        { id: 'ask-bruno', label: '要求 Bruno 行动', nodeId: 'bruno-node' },
        { id: 'gm-review', label: 'GM 审批', nodeId: 'gm-node' },
        { id: 'pause-auto', label: '暂停', nodeId: 'dealer-node' },
      ],
    }

    render(
      <CanvasSceneLayer
        sceneSpec={sceneSpec}
        nodes={[
          node({ id: 'ada-node', title: 'Ada 玩家 Agent' }),
          node({ id: 'bruno-node', title: 'Bruno 玩家 Agent' }),
          node({ id: 'gm-node', title: 'GM / 规则裁判', executionMode: 'human', executorType: 'human' }),
          node({ id: 'dealer-node', title: 'Dealer / Table State', executorType: 'mock', executionMode: 'human' }),
        ]}
        artifacts={[]}
        onOpenNode={vi.fn()}
        onSceneAction={sceneAction}
      />,
    )

    expect(screen.getByText('下一步')).toBeInTheDocument()
    expect(screen.getAllByText('Ada 玩家 Agent').length).toBeGreaterThan(0)
    expect(screen.queryByRole('button', { name: '要求 Ada 行动' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '要求 Bruno 行动' })).not.toBeInTheDocument()
    expect(screen.getAllByText('??').length).toBeGreaterThanOrEqual(5)

    fireEvent.click(screen.getByRole('button', { name: '执行：要求 Ada 行动' }))
    expect(sceneAction).toHaveBeenCalledWith('ada-node', 'ask-ada')
    expect(screen.getByRole('button', { name: 'GM 审批' })).toBeInTheDocument()
    expect(screen.getByText('需要确认')).toBeInTheDocument()
  })
})

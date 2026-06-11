import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { NodeContributionsSection } from './NodeContributionsSection'
import type { PlanningNode } from '../../types'

const apiMocks = vi.hoisted(() => ({
  fetchPlannerNodeContributions: vi.fn(),
  submitPlannerNodeContribution: vi.fn(),
  updatePlannerNodeContribution: vi.fn(),
}))

vi.mock('../../api', async () => {
  const actual = await vi.importActual<typeof import('../../api')>('../../api')
  return {
    ...actual,
    fetchPlannerNodeContributions: apiMocks.fetchPlannerNodeContributions,
    submitPlannerNodeContribution: apiMocks.submitPlannerNodeContribution,
    updatePlannerNodeContribution: apiMocks.updatePlannerNodeContribution,
  }
})

function makeNode(contribution: PlanningNode['contribution']): PlanningNode {
  return {
    id: 'node-1',
    canvasId: 'canvas-1',
    title: 'Collect startup list',
    schema: { inputs: [], outputs: [] },
    contextSources: [],
    executionMode: 'human',
    executorType: 'human',
    doerId: 'owner-1',
    reviewerIds: [],
    approverIds: [],
    handoffPolicy: 'none',
    status: 'ready',
    nodeKind: 'step',
    contribution,
  } as unknown as PlanningNode
}

const TEAM = [
  { userId: 'u-alice', displayName: 'Alice', avatarUrl: null },
  { userId: 'u-bob', displayName: 'Bob', avatarUrl: null },
] as never[]

describe('NodeContributionsSection', () => {
  beforeEach(() => {
    apiMocks.fetchPlannerNodeContributions.mockReset()
    apiMocks.submitPlannerNodeContribution.mockReset()
    apiMocks.updatePlannerNodeContribution.mockReset()
  })

  it('renders the attributed ledger when the node is open for team contributions', async () => {
    apiMocks.fetchPlannerNodeContributions.mockResolvedValue({
      contributions: [
        { id: 'c1', title: 'Stripe', note: '支付', submittedBy: 'u-alice', createdAt: new Date().toISOString() },
        { id: 'c2', title: 'Anthropic', submittedBy: 'u-bob', createdAt: new Date().toISOString() },
      ],
    })
    render(
      <NodeContributionsSection
        canvasId="canvas-1"
        node={makeNode({ policy: 'team', itemLabel: 'startup' })}
        isOwner={false}
        teamMembers={TEAM}
      />,
    )
    await waitFor(() => {
      expect(screen.getByText('Stripe')).toBeTruthy()
    })
    expect(screen.getByText('Anthropic')).toBeTruthy()
    // 归属:贡献人名字来自团队目录。
    expect(screen.getByText(/Alice/)).toBeTruthy()
    expect(screen.getByText(/Bob/)).toBeTruthy()
    // 成员(非 owner)看不到 policy 开关。
    expect(screen.queryByText('关闭共建')).toBeNull()
  })

  it('submits a contribution and refreshes the list', async () => {
    apiMocks.fetchPlannerNodeContributions.mockResolvedValue({ contributions: [] })
    apiMocks.submitPlannerNodeContribution.mockResolvedValue({
      ok: true,
      contribution: { id: 'c9', title: 'Vercel', submittedBy: 'u-bob', createdAt: new Date().toISOString() },
    })
    render(
      <NodeContributionsSection
        canvasId="canvas-1"
        node={makeNode({ policy: 'team', itemLabel: 'startup' })}
        isOwner={false}
        teamMembers={TEAM}
      />,
    )
    const input = await screen.findByPlaceholderText('添加一条startup…')
    fireEvent.change(input, { target: { value: 'Vercel' } })
    fireEvent.click(screen.getByText('添加'))
    await waitFor(() => {
      expect(apiMocks.submitPlannerNodeContribution).toHaveBeenCalledWith(
        'canvas-1',
        'node-1',
        { title: 'Vercel', note: undefined },
      )
    })
    // 提交后刷新账本(初始 1 次 + 提交后 1 次)。
    await waitFor(() => {
      expect(apiMocks.fetchPlannerNodeContributions.mock.calls.length).toBeGreaterThanOrEqual(2)
    })
  })

  it('lets the owner open a closed node to the team', async () => {
    apiMocks.updatePlannerNodeContribution.mockResolvedValue({ nodes: [] })
    render(
      <NodeContributionsSection
        canvasId="canvas-1"
        node={makeNode(null)}
        isOwner
        teamMembers={TEAM}
      />,
    )
    fireEvent.click(screen.getByText('开放给团队'))
    await waitFor(() => {
      expect(apiMocks.updatePlannerNodeContribution).toHaveBeenCalledWith(
        'canvas-1',
        'node-1',
        { policy: 'team', itemLabel: null },
      )
    })
    // 关闭态不拉账本。
    expect(apiMocks.fetchPlannerNodeContributions).not.toHaveBeenCalled()
  })

  it('shows members a hint when the owner has not opened contributions', () => {
    render(
      <NodeContributionsSection
        canvasId="canvas-1"
        node={makeNode(null)}
        isOwner={false}
        teamMembers={TEAM}
      />,
    )
    expect(screen.getByText('负责人还没开放这个节点的团队共建')).toBeTruthy()
    expect(apiMocks.fetchPlannerNodeContributions).not.toHaveBeenCalled()
  })
})

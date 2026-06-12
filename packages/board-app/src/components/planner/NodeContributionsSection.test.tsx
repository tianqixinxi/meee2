import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { NodeContributionsSection } from './NodeContributionsSection'
import type { PlanningNode } from '../../types'

const apiMocks = vi.hoisted(() => ({
  fetchPlannerNodeContributions: vi.fn(),
  submitPlannerNodeContribution: vi.fn(),
  updatePlannerNodeContribution: vi.fn(),
  startPlannerContributionSession: vi.fn(),
}))

vi.mock('../../api', async () => {
  const actual = await vi.importActual<typeof import('../../api')>('../../api')
  return {
    ...actual,
    fetchPlannerNodeContributions: apiMocks.fetchPlannerNodeContributions,
    submitPlannerNodeContribution: apiMocks.submitPlannerNodeContribution,
    updatePlannerNodeContribution: apiMocks.updatePlannerNodeContribution,
    startPlannerContributionSession: apiMocks.startPlannerContributionSession,
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
    apiMocks.startPlannerContributionSession.mockReset()
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

  it('renders http(s) urls as links but never unsafe schemes (stored XSS guard)', async () => {
    apiMocks.fetchPlannerNodeContributions.mockResolvedValue({
      contributions: [
        { id: 'c1', title: 'SafeCo', url: 'https://safe.example.com', submittedBy: 'u-alice', createdAt: new Date().toISOString() },
        { id: 'c2', title: 'EvilCo', url: 'javascript:alert(1)', submittedBy: 'u-bob', createdAt: new Date().toISOString() },
      ],
    })
    const { container } = render(
      <NodeContributionsSection
        canvasId="canvas-1"
        node={makeNode({ policy: 'team' })}
        isOwner={false}
        teamMembers={TEAM}
      />,
    )
    await waitFor(() => {
      expect(screen.getByText('SafeCo')).toBeTruthy()
    })
    const links = Array.from(container.querySelectorAll('a'))
    expect(links.map((a) => a.getAttribute('href'))).toEqual(['https://safe.example.com'])
    // EvilCo 仍渲染标题,但绝不渲染成 javascript: 链接。
    expect(screen.getByText('EvilCo').closest('a')).toBeNull()
  })

  it('starts an AI collection session as the primary path', async () => {
    apiMocks.fetchPlannerNodeContributions.mockResolvedValue({ contributions: [] })
    apiMocks.startPlannerContributionSession.mockResolvedValue({
      ok: true,
      sessionId: 'sess-1',
      nodeId: 'node-1',
      action: 'created',
      detail: '已派发专属收集会话,产出会陆续进入账本。',
    })
    render(
      <NodeContributionsSection
        canvasId="canvas-1"
        node={makeNode({ policy: 'team', itemLabel: 'startup' })}
        isOwner={false}
        teamMembers={TEAM}
      />,
    )
    fireEvent.click(await screen.findByText('开始 AI 收集startup'))
    await waitFor(() => {
      expect(apiMocks.startPlannerContributionSession).toHaveBeenCalledWith('canvas-1', 'node-1')
    })
    // 派发结果反馈到面板。
    expect(await screen.findByText('已派发专属收集会话,产出会陆续进入账本。')).toBeTruthy()
  })

  it('marks agent-produced items with attribution to the member', async () => {
    apiMocks.fetchPlannerNodeContributions.mockResolvedValue({
      contributions: [
        { id: 'c1', title: 'Modal', kind: 'agent', submittedBy: 'u-alice', createdAt: new Date().toISOString() },
      ],
    })
    const { container } = render(
      <NodeContributionsSection
        canvasId="canvas-1"
        node={makeNode({ policy: 'team' })}
        isOwner={false}
        teamMembers={TEAM}
      />,
    )
    await waitFor(() => {
      expect(screen.getByText('Modal')).toBeTruthy()
    })
    // agent 产出带机器人标记,归属仍是成员。
    expect(container.querySelector('.planner-contrib__via-agent')).toBeTruthy()
    expect(screen.getByText(/Alice/)).toBeTruthy()
  })

  it('submits a manual contribution behind the secondary toggle and refreshes', async () => {
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
    // 手动表单默认收起,点「手动添加一条」展开。
    expect(screen.queryByPlaceholderText('手动添加一条startup…')).toBeNull()
    fireEvent.click(await screen.findByText('手动添加一条'))
    const input = await screen.findByPlaceholderText('手动添加一条startup…')
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

  it('renders the per-member collector list; own session opens locally, others open the dashboard', async () => {
    apiMocks.fetchPlannerNodeContributions.mockResolvedValue({
      contributions: [],
      dashboardBaseUrl: 'https://www.meee2.com',
      collectors: [
        { userId: 'u-alice', sessionId: 'sess-alice', startedAt: new Date().toISOString(), mine: true, alive: true },
        { userId: 'u-bob', sessionId: 'sess-bob', startedAt: new Date().toISOString() },
      ],
    })
    const onOpenSession = vi.fn()
    const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null)
    render(
      <NodeContributionsSection
        canvasId="canvas-1"
        node={makeNode({ policy: 'team' })}
        isOwner={false}
        teamMembers={TEAM}
        currentUserId="u-alice"
        onOpenSession={onOpenSession}
      />,
    )
    // 成员维度列表:我的 + Bob 的。
    expect(await screen.findByText('Alice (我)')).toBeTruthy()
    expect(screen.getByText('收集中')).toBeTruthy()
    fireEvent.click(screen.getByText('Alice (我)'))
    expect(onOpenSession).toHaveBeenCalledWith('sess-alice', 'node-1')
    // 别人的 → dashboard 网页。
    fireEvent.click(screen.getByText('Bob'))
    expect(openSpy).toHaveBeenCalledWith(
      'https://www.meee2.com/dashboard/sessions/sess-bob',
      '_blank',
      'noreferrer',
    )
    openSpy.mockRestore()
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

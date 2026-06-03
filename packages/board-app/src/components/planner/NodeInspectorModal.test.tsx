import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { NodeInspectorModal } from './NodeInspectorModal'
import type { PlannerWorkflowRunState, PlanningNode, Session } from '../../types'

// The inspector imports ./InspectorArtifactBody (only used on the `artifact`
// branch, which these step/session tests never hit) — stub it so the module
// graph stays cheap and isolated. InputCardSections is left real; it renders
// fine in jsdom.
vi.mock('./InspectorArtifactBody', () => ({
  InspectorArtifactBody: () => null,
}))

const NOW = new Date('2026-05-30T12:00:00Z').getTime()

function node(overrides: Partial<PlanningNode> = {}): PlanningNode {
  return {
    id: 'node-1',
    canvasId: 'c1',
    title: 'My Step',
    schema: { inputs: [], outputs: [], goal: '' },
    contextSources: [],
    executionMode: 'auto',
    executorType: 'claude',
    doerId: '',
    reviewerIds: [],
    approverIds: [],
    handoffPolicy: 'none',
    status: 'ready',
    nodeKind: 'step',
    ...overrides,
  } as PlanningNode
}

function session(overrides: Partial<Session> = {}): Session {
  return {
    id: 'sess-abcdef1234',
    title: 'Session',
    project: 'p',
    pluginId: 'claude',
    pluginDisplayName: 'Claude',
    pluginColor: '#FF9500',
    status: 'thinking',
    inboxPending: 0,
    recentMessages: [],
    currentTool: null,
    currentTask: null,
    usageStats: null,
    backgroundAgents: [],
    latestRecap: null,
    lastActivity: null,
    syncEnabled: false,
    syncTeamId: null,
    syncTeamName: null,
    ...overrides,
  }
}

function renderModal(props: {
  node: PlanningNode
  boundSession?: Session | null
}) {
  return render(
    <NodeInspectorModal
      node={props.node}
      canvasId="c1"
      state={null}
      onClose={() => {}}
      onOpenSession={() => {}}
      boundSession={props.boundSession ?? null}
    />,
  )
}

describe('NodeInspectorModal 进展 live-block gating', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(NOW)
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('(a) running node with a bound session shows currentTask/currentTool + relative time', () => {
    const sess = session({
      currentTask: 'Drafting the PRD',
      currentTool: 'Edit',
      lastActivity: new Date(NOW - 5 * 60_000).toISOString(),
      recentMessages: [{ role: 'assistant', text: 'working on it' }],
    })
    renderModal({
      node: node({
        sessionId: 'sess-abcdef1234',
        workflowRunState: 'running' as PlannerWorkflowRunState,
      }),
      boundSession: sess,
    })
    // 运行中 appears twice: header status badge + progress runtime label.
    expect(screen.getAllByText('运行中').length).toBeGreaterThanOrEqual(1)
    expect(screen.getByText('Drafting the PRD')).toBeInTheDocument()
    expect(screen.getByText('Edit')).toBeInTheDocument()
    // relative time rendered without the "最后活动" prefix (that's done-only)
    expect(screen.getByText('5 分钟前')).toBeInTheDocument()
    expect(screen.queryByText(/最后活动/)).not.toBeInTheDocument()
    // bound-session line + open-session button present
    expect(screen.getByText(/已绑定会话/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /打开会话查看进展/ })).toBeInTheDocument()
  })

  it('puts terminal ids at the drawer bottom even without live details', () => {
    const surfaceId = 'ghostty-surface-node-abcdef1234567890'
    const providerResumeSessionId = '8db44e39-685d-47ab-bd0e-5e97386ded80'
    const { container } = renderModal({
      node: node({
        sessionId: 'sess-abcdef1234',
        workflowRunState: 'ready_to_start' as PlannerWorkflowRunState,
      }),
      boundSession: session({
        currentTask: 'runtime task hidden outside live states',
        surfaceId,
        providerResumeSessionId,
      }),
    })

    expect(screen.getByLabelText('运行时标识')).toBeInTheDocument()
    expect(screen.getByText('Surface')).toBeInTheDocument()
    expect(screen.getByText('Provider')).toBeInTheDocument()
    expect(screen.getByText(surfaceId)).toBeInTheDocument()
    expect(screen.getByText(providerResumeSessionId)).toBeInTheDocument()
    expect(container.querySelector(`[title="${surfaceId}"]`)).not.toBeNull()
    expect(container.querySelector(`[title="${providerResumeSessionId}"]`)).not.toBeNull()
    expect(screen.queryByText('runtime task hidden outside live states')).not.toBeInTheDocument()
    const modalChildren = Array.from(container.querySelector('.planner-node-modal')?.children ?? [])
    const moreIndex = modalChildren.findIndex((child) => child.classList.contains('planner-node-modal__more'))
    const debugIndex = modalChildren.findIndex((child) => child.classList.contains('planner-node-modal__runtime-debug-footer'))
    expect(debugIndex).toBeGreaterThan(moreIndex)
  })

  it('keeps terminal ids outside the progress block when live details are shown', () => {
    const surfaceId = 'ghostty-surface-node-abcdef1234567890'
    const providerResumeSessionId = '8db44e39-685d-47ab-bd0e-5e97386ded80'
    const { container } = renderModal({
      node: node({
        sessionId: 'sess-abcdef1234',
        workflowRunState: 'running' as PlannerWorkflowRunState,
      }),
      boundSession: session({
        currentTask: 'Working on the node',
        lastActivity: new Date(NOW - 60_000).toISOString(),
        surfaceId,
        providerResumeSessionId,
      }),
    })

    expect(screen.getByText('Working on the node')).toBeInTheDocument()
    expect(screen.getByLabelText('运行时标识')).toBeInTheDocument()
    expect(screen.getByText('Surface')).toBeInTheDocument()
    expect(screen.getByText('Provider')).toBeInTheDocument()
    expect(screen.getByText(surfaceId)).toBeInTheDocument()
    expect(screen.getByText(providerResumeSessionId)).toBeInTheDocument()
    expect(container.querySelector(`[title="${surfaceId}"]`)).not.toBeNull()
    expect(container.querySelector(`[title="${providerResumeSessionId}"]`)).not.toBeNull()
    expect(container.querySelector('.planner-node-modal__progress-runtime-live .planner-node-modal__runtime-debug-footer')).toBeNull()
  })

  it('(b) done node with a bound session shows recent message + 最后活动 but NOT currentTask/currentTool', () => {
    const sess = session({
      status: 'idle',
      currentTask: 'Stale task that should be hidden',
      currentTool: 'StaleTool',
      lastActivity: new Date(NOW - 2 * 3_600_000).toISOString(),
      recentMessages: [{ role: 'assistant', text: 'all done here' }],
    })
    renderModal({
      node: node({
        sessionId: 'sess-abcdef1234',
        status: 'done',
        workflowRunState: 'done' as PlannerWorkflowRunState,
      }),
      boundSession: sess,
    })
    // done state: live currentTask/currentTool are suppressed (stale for a finished node)
    expect(screen.queryByText('Stale task that should be hidden')).not.toBeInTheDocument()
    expect(screen.queryByText('StaleTool')).not.toBeInTheDocument()
    // recent message still shown
    expect(screen.getByText('all done here')).toBeInTheDocument()
    // "最后活动 …" prefix present for done
    expect(screen.getByText(/最后活动/)).toBeInTheDocument()
    expect(screen.getByText(/2 小时前/)).toBeInTheDocument()
  })

  it('(c) node with NO sessionId shows neither 已绑定会话 nor the open-session button', () => {
    renderModal({
      node: node({
        sessionId: null,
        workflowRunState: 'running' as PlannerWorkflowRunState,
      }),
      boundSession: session({ currentTask: 'should not appear' }),
    })
    expect(screen.queryByText(/已绑定会话/)).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /打开会话查看进展/ })).not.toBeInTheDocument()
    // no bound-session live row content either (gated on hasSession)
    expect(screen.queryByText('should not appear')).not.toBeInTheDocument()
  })
})

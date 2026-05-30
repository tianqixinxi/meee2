import { describe, expect, it } from 'vitest'
import { deriveDisplayStatus } from './labels'
import type { PlannerWorkflowRunState, PlanningNode, PlanningNodeStatus } from '../../types'

function node(
  overrides: Partial<Pick<PlanningNode, 'workflowRunState' | 'status'>> = {},
): PlanningNode {
  return {
    id: 'n1',
    canvasId: 'c1',
    title: 'Node',
    schema: { inputs: [], outputs: [], goal: '' },
    contextSources: [],
    executionMode: 'auto',
    executorType: 'claude',
    doerId: '',
    reviewerIds: [],
    approverIds: [],
    handoffPolicy: 'none',
    status: 'ready',
    ...overrides,
  } as PlanningNode
}

describe('deriveDisplayStatus', () => {
  it('maps workflowRunState running/dispatched to 运行中 (running tone)', () => {
    for (const wfs of ['running', 'dispatched'] as PlannerWorkflowRunState[]) {
      expect(deriveDisplayStatus(node({ workflowRunState: wfs }))).toEqual({
        label: '运行中',
        tone: 'running',
      })
    }
  })

  it('maps awaiting-input to 等反馈 (awaiting tone)', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: 'awaiting-input' }))).toEqual({
      label: '等反馈',
      tone: 'awaiting',
    })
  })

  it('maps gate-wait to 等审核 (awaiting tone)', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: 'gate-wait' }))).toEqual({
      label: '等审核',
      tone: 'awaiting',
    })
  })

  it('maps failed to 失败 (failed tone)', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: 'failed' }))).toEqual({
      label: '失败',
      tone: 'failed',
    })
  })

  it('maps done workflowRunState to 完成 (done tone)', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: 'done' }))).toEqual({
      label: '完成',
      tone: 'done',
    })
  })

  it('maps done node.status (no workflowRunState) to 完成', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: null, status: 'done' }))).toEqual({
      label: '完成',
      tone: 'done',
    })
  })

  it('maps blocked node.status to 卡住 when run state is not terminal', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: null, status: 'blocked' }))).toEqual({
      label: '卡住',
      tone: 'blocked',
    })
  })

  it('falls back to the plan-status label with ready tone for ready nodes', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: 'ready_to_start', status: 'ready' }))).toEqual({
      label: '就绪',
      tone: 'ready',
    })
  })

  it('falls back to 就绪 for pending workflow state with a ready node', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: 'pending', status: 'ready' }))).toEqual({
      label: '就绪',
      tone: 'ready',
    })
  })

  it('treats an unknown legacy status as 就绪 (ready tone)', () => {
    expect(
      deriveDisplayStatus(node({ workflowRunState: null, status: 'draft' as PlanningNodeStatus })),
    ).toEqual({ label: '就绪', tone: 'ready' })
  })
})

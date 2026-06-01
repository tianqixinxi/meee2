import { describe, expect, it } from 'vitest'
import { deriveDisplayStatus } from './labels'
import type { PlannerWorkflowRunState, PlanningNode, PlanningNodeStatus } from '../../types'

function node(
  overrides: Partial<Pick<PlanningNode, 'workflowRunState' | 'status' | 'nodeKind'>> = {},
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

  // 3-态会话模型(2026-06-01): awaiting-input / gate-wait / failed 统一并入「需要人回应」。
  it('maps awaiting-input / gate-wait / failed to 需要人回应 (awaiting tone)', () => {
    for (const wfs of ['awaiting-input', 'gate-wait', 'failed'] as PlannerWorkflowRunState[]) {
      expect(deriveDisplayStatus(node({ workflowRunState: wfs }))).toEqual({
        label: '需要人回应',
        tone: 'awaiting',
      })
    }
  })

  // canvas-is-ledger-not-pm: step / session 工作节点没有「完成」态 → 回到「未启动」。
  it('maps a done step/session work node to 未启动 (no 完成 state)', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: 'done', nodeKind: 'step' }))).toEqual({
      label: '未启动',
      tone: 'ready',
    })
    expect(deriveDisplayStatus(node({ workflowRunState: null, status: 'done', nodeKind: 'session' }))).toEqual({
      label: '未启动',
      tone: 'ready',
    })
  })

  it('keeps 完成 for non-work nodes (subCanvas / artifact / external)', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: 'done', nodeKind: 'subCanvas' }))).toEqual({
      label: '完成',
      tone: 'done',
    })
    expect(deriveDisplayStatus(node({ workflowRunState: null, status: 'done', nodeKind: 'artifact' }))).toEqual({
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

  it('maps ready_to_start / pending to 未启动 (ready tone)', () => {
    for (const wfs of ['ready_to_start', 'pending'] as PlannerWorkflowRunState[]) {
      expect(deriveDisplayStatus(node({ workflowRunState: wfs, status: 'ready' }))).toEqual({
        label: '未启动',
        tone: 'ready',
      })
    }
  })

  it('treats an unknown legacy status as 未启动 (ready tone)', () => {
    expect(
      deriveDisplayStatus(node({ workflowRunState: null, status: 'draft' as PlanningNodeStatus })),
    ).toEqual({ label: '未启动', tone: 'ready' })
  })
})

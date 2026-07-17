import { describe, expect, it } from 'vitest'
import { deriveDisplayStatus, isSessionEnded, primaryActionLabel, requiredInputActionLabel } from './labels'
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

  // 节点结果与会话存活状态分离: done 永远保留「已完成」结果真相。
  it('maps a done step/session work node to 已完成', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: 'done', nodeKind: 'step' }))).toEqual({
      label: '已完成',
      tone: 'done',
    })
    expect(deriveDisplayStatus(node({ workflowRunState: null, status: 'done', nodeKind: 'session' }))).toEqual({
      label: '已完成',
      tone: 'done',
    })
  })

  // workflow-bridge 镜像节点(external 非工作节点): done → 「完成」(不是「未启动」),
  // running → 「运行中」—— 外部 workflow 的 agent 节点没有可重开的会话语义。
  it('maps external mirror nodes by workflowRunState', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: 'done', nodeKind: 'external' }))).toEqual({
      label: '已完成',
      tone: 'done',
    })
    expect(deriveDisplayStatus(node({ workflowRunState: 'running', nodeKind: 'external' }))).toEqual({
      label: '运行中',
      tone: 'running',
    })
    expect(deriveDisplayStatus(node({ workflowRunState: null, status: 'done', nodeKind: 'external' }))).toEqual({
      label: '已完成',
      tone: 'done',
    })
  })

  // done 结果优先；尚未执行但绑定了活会话时，显示会话在线待命。
  it('keeps done result separate from a live bound session', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: 'done', nodeKind: 'step' }), true)).toEqual({
      label: '已完成',
      tone: 'done',
    })
    expect(deriveDisplayStatus(node({ workflowRunState: 'pending', nodeKind: 'step' }), true)).toEqual({
      label: '在线待命',
      tone: 'running',
    })
  })

  // 优先级: 活跃 node 态(running / awaiting)仍优先于「在线待命」—— 会话活且节点
  // 在跑 / 待回复时显示其真实态,不被在线待命盖掉。
  it('keeps running / awaiting over 在线待命 even with a live session', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: 'running', nodeKind: 'step' }), true)).toEqual({
      label: '运行中',
      tone: 'running',
    })
    expect(deriveDisplayStatus(node({ workflowRunState: 'awaiting-input', nodeKind: 'step' }), true)).toEqual({
      label: '需要人回应',
      tone: 'awaiting',
    })
  })

  it('keeps 已完成 for non-work nodes (subCanvas / artifact / external)', () => {
    expect(deriveDisplayStatus(node({ workflowRunState: 'done', nodeKind: 'subCanvas' }))).toEqual({
      label: '已完成',
      tone: 'done',
    })
    expect(deriveDisplayStatus(node({ workflowRunState: null, status: 'done', nodeKind: 'artifact' }))).toEqual({
      label: '已完成',
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

describe('required input primary action', () => {
  it('takes precedence over spawning AI or submitting human work', () => {
    for (const executorType of ['claude', 'human']) {
      expect(primaryActionLabel({
        mode: 'design',
        hasSelectedDelivery: true,
        runStatus: 'ready_to_start',
        workflowRunState: 'ready_to_start',
        sessionId: null,
        nodeKind: 'step',
        status: 'ready',
        blockers: [],
        canChangeStatus: true,
        canCreateSession: true,
        creatingSession: false,
        executorType,
        missingRequiredInput: 'PDF brief',
      })).toBe('add-input')
    }
    expect(requiredInputActionLabel('PDF brief')).toBe('添加 PDF')
    expect(requiredInputActionLabel('海报模板')).toBe('选择模板')
  })
})

// 一致性守卫回归:node 回到「未启动」(pending/ready_to_start/null)时,卡片应丢弃
// active-run mirror 滞后残留的 sessionId/runState —— isSessionEnded 是这条守卫的判定。
describe('isSessionEnded — 未启动语义(丢弃 runNodeState 滞后残留)', () => {
  it('returns true for not-started states (pending / ready_to_start / null / undefined)', () => {
    expect(isSessionEnded('pending')).toBe(true)
    expect(isSessionEnded('ready_to_start')).toBe(true)
    expect(isSessionEnded(null)).toBe(true)
    expect(isSessionEnded(undefined)).toBe(true)
  })

  it('returns false for live / terminal states (must keep their bound session)', () => {
    for (const wfs of [
      'dispatched',
      'running',
      'awaiting-input',
      'gate-wait',
      'failed',
      'done',
    ] as PlannerWorkflowRunState[]) {
      expect(isSessionEnded(wfs)).toBe(false)
    }
  })
})

import { describe, expect, it } from 'vitest'
import {
  CONFIRMED_PLAN_DRAFT_PREFIX,
  buildConfirmedPlanGraphChanges,
  parseConfirmedPlanDraft,
  serializeConfirmedPlanDraft,
} from './plannerPlanDraft'

describe('planner confirmed plan drafts', () => {
  it('serializes and parses a confirmed plan card payload', () => {
    const payload = serializeConfirmedPlanDraft({
      title: '舆情分析与飞书输出计划',
      intro: '请确认。',
      steps: [
        { title: '收集公开舆情来源', body: '收集公开网页讨论和引用链接。' },
        { title: '生成飞书文档草稿', body: '整理结论并保留引用来源。' },
      ],
      prompt: 'legacy model prompt',
      canvasPresentation: 'workflow',
    })

    expect(payload.startsWith(`${CONFIRMED_PLAN_DRAFT_PREFIX}\n`)).toBe(true)
    expect(parseConfirmedPlanDraft(payload)).toEqual({
      title: '舆情分析与飞书输出计划',
      intro: '请确认。',
      steps: [
        { title: '收集公开舆情来源', body: '收集公开网页讨论和引用链接。' },
        { title: '生成飞书文档草稿', body: '整理结论并保留引用来源。' },
      ],
      prompt: 'legacy model prompt',
      canvasPresentation: 'workflow',
    })
  })

  it('turns a confirmed plan into addNode graph changes', () => {
    const draft = parseConfirmedPlanDraft(serializeConfirmedPlanDraft({
      title: 'Canvas 执行计划',
      intro: '请确认。',
      steps: [
        { title: 'Collect sources', body: 'Gather public sources.' },
        { title: 'Analyze themes', body: 'Classify and summarize themes.' },
      ],
    }))

    const changes = buildConfirmedPlanGraphChanges({
      canvasId: 'canvas-1',
      actorId: 'owner-1',
      idSeed: 'test-seed',
      draft: draft!,
    })

    expect(changes).toHaveLength(2)
    expect(changes[0].kind).toBe('addNode')
    expect(changes[0].node).toMatchObject({
      id: 'node-test-seed-1-collect-sources',
      canvasId: 'canvas-1',
      title: 'Collect sources',
      status: 'ready',
      nodeKind: 'step',
      executorType: 'claude',
      doerId: 'owner-1',
      dependsOnNodeIds: [],
    })
    expect(changes[1].node?.dependsOnNodeIds).toEqual(['node-test-seed-1-collect-sources'])
  })

  it('rejects legacy scene payloads without executable nodes', () => {
    const draft = parseConfirmedPlanDraft(`${CONFIRMED_PLAN_DRAFT_PREFIX}\n${JSON.stringify({
      title: 'AI Poker Table',
      intro: 'Legacy scene payload.',
      steps: [],
      canvasPresentation: 'scene',
      templateId: 'poker-table',
    })}`)

    expect(draft).toBeNull()
  })
})

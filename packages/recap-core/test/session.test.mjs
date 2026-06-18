import assert from 'node:assert/strict'
import { buildSessionRecap, deriveDisplaySessionTitle } from '../dist/session.js'

const now = '2026-06-19T12:00:00.000Z'

{
  const recap = buildSessionRecap({
    now,
    sessionId: 'session-1',
    provider: 'codex',
    title: 'Codex - meee2',
    status: 'running',
    currentTask: '优化 Artifact tab',
    signals: [{
      id: 'compact-1',
      provider: 'codex',
      sessionId: 'session-1',
      intent: 'context_compaction',
      content: 'Summary: 已修改多个文件，下一步继续跑测试。',
      timestamp: now,
      confidence: 'medium',
    }],
  })
  assert.equal(recap?.intent, 'context_compaction')
  assert.equal(recap?.displayTitle, undefined)

  const title = deriveDisplaySessionTitle({
    sessionRecap: recap,
    currentTask: '优化 Artifact tab',
    initialUserMessage: '不好看，而且 promote 为什么不能点击',
    providerTitle: 'Codex - meee2',
  })
  assert.equal(title.text, '优化 Artifact tab')
  assert.equal(title.source, 'current_task')
}

{
  const recap = buildSessionRecap({
    now,
    sessionId: 'session-2',
    provider: 'claude',
    title: 'Claude - meee2',
    status: 'idle',
    signals: [{
      id: 'away-1',
      provider: 'claude',
      sessionId: 'session-2',
      intent: 'human_recap',
      content: '已经完成 Session 标题与终端显示修复。',
      timestamp: now,
      confidence: 'high',
    }],
  })
  const title = deriveDisplaySessionTitle({
    sessionRecap: recap,
    currentTask: '旧任务',
    providerTitle: 'Claude - meee2',
  })
  assert.equal(title.text, 'Session 标题与终端显示修复')
  assert.equal(title.source, 'session_recap')
}

console.log('session recap tests passed')

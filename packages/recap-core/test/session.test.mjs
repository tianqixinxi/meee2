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

{
  const title = deriveDisplaySessionTitle({
    providerTitle: '梳理对话标题来源',
    currentTask: '仔细读下代码，研究下 multica 对话列表中每个对话的标题是怎么来的',
    initialUserMessage: '仔细读下代码，研究下 multica 对话列表中每个对话的标题是怎么来的',
  })
  assert.equal(title.text, '梳理对话标题来源')
  assert.equal(title.source, 'provider_title')
  assert.equal(title.confidence, 'high')
}

{
  const title = deriveDisplaySessionTitle({
    providerTitle: 'Codex',
    initialUserMessage: '继续 Terminal tab 中的 Session',
  })
  assert.equal(title.text, '继续 Terminal tab 中的 Session')
  assert.equal(title.source, 'initial_prompt')
}

console.log('session recap tests passed')

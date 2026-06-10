import assert from 'node:assert/strict'
import { buildCanvasMonitor } from '../dist/monitor.js'

const now = '2026-05-28T12:00:00.000Z'

function monitor(overrides = {}) {
  return buildCanvasMonitor({
    now,
    canvas: { id: 'canvas-1', title: 'Canvas' },
    nodeStates: [],
    sessions: [],
    ...overrides,
  })
}

{
  const result = monitor({
    nodes: [{ id: 'node-1', title: 'Needs chmod', sessionId: 's1' }],
    sessions: [{
      id: 's1',
      status: 'permissionRequired',
      pendingPermissionTool: 'Shell',
      pendingPermissionMessage: 'Allow chmod +x scripts/validate.sh?',
      inboxPending: 0,
      recentMessages: [],
    }],
  })
  assert.equal(result.counts.needsHumanReply, 1)
  assert.equal(result.items[0].reasonKind, 'permission_required')
  assert.equal(result.items[0].replyPrompt, 'Allow chmod +x scripts/validate.sh?')
  assert.equal(result.items[0].severity, 'critical')
}

{
  const result = monitor({
    nodes: [{ id: 'node-2', title: 'Answer product question', sessionId: 's2' }],
    sessions: [{
      id: 's2',
      status: 'waitingForUser',
      inboxPending: 0,
      recentMessages: [
        { role: 'user', text: 'Build it.' },
        { role: 'assistant', text: 'Which launch date should I target?' },
      ],
    }],
  })
  assert.equal(result.items[0].reasonKind, 'waiting_for_user')
  assert.equal(result.items[0].replyPrompt, 'Which launch date should I target?')
}

{
  const result = monitor({
    nodes: [{ id: 'node-3', title: 'Unread ops note', sessionId: 'prefix-s3' }],
    sessions: [{ id: 's3', status: 'idle', inboxPending: 2, recentMessages: [] }],
  })
  assert.equal(result.items[0].reasonKind, 'inbox_pending')
  assert.equal(result.items[0].needsHumanReply, true)
}

{
  const result = monitor({
    nodes: [
      { id: 'gate', title: 'Review output', workflowRunState: 'gate-wait', nextAction: 'Review the output.' },
      { id: 'awaiting', title: 'Needs context', workflowRunState: 'awaiting-input', nextAction: 'Open the session and reply.' },
      { id: 'blocked', title: 'Blocked node', status: 'blocked', blockedReason: 'Missing PR link' },
      { id: 'failed', title: 'Failed node', workflowRunState: 'failed' },
    ],
  })
  assert.deepEqual(result.items.map((item) => item.reasonKind), [
    'gate_wait',
    'awaiting_input',
    'blocked',
    'failed',
  ])
  assert.equal(result.items[0].needsHumanReply, true)
  assert.equal(result.items[1].needsHumanReply, true)
  assert.equal(result.items[2].needsHumanReply, false)
  assert.equal(result.items[3].needsHumanReply, false)
}

{
  const result = monitor({
    nodes: [
      { id: 'running', title: 'Running', status: 'working', workflowRunState: 'running' },
      { id: 'done', title: 'Done', status: 'done', workflowRunState: 'done' },
    ],
  })
  assert.equal(result.counts.needsHumanReply, 0)
  assert.equal(result.items[0].reasonKind, 'normal')
  assert.equal(result.items[1].reasonKind, 'normal')
}

{
  const result = monitor({
    nodes: [{ id: 'done-stale', title: 'Done with stale session', status: 'done', workflowRunState: 'done', sessionId: 's-done' }],
    sessions: [{
      id: 's-done',
      status: 'waitingForUser',
      inboxPending: 3,
      pendingPermissionTool: 'Shell',
      pendingPermissionMessage: 'Allow one more command?',
      recentMessages: [{ role: 'assistant', text: 'Should I keep going?' }],
    }],
  })
  assert.equal(result.counts.needsHumanReply, 0)
  assert.equal(result.items[0].reasonKind, 'normal')
  assert.equal(result.items[0].needsHumanReply, false)
  assert.equal(result.items[0].replyPrompt, null)
}

console.log('monitor tests passed')

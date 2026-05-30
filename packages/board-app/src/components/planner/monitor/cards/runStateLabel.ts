/**
 * Canonical labels for the per-node ledger surfaces used by monitor cards.
 *
 * `NodeStateSnapshot.runState` is the derived `NodeRunState`
 * (`draft|ready|working|blocked|done`). We map it to the same 5-bucket
 * vocabulary the widgets use (待办 / 运行中 / 卡住 / 完成) so the monitor reads
 * consistently with node cards. `working` → 运行中; `draft|ready` → 待办.
 */

import type { NodeRunState } from '../../../../types'

export const RUN_STATE_LABEL: Record<NodeRunState, string> = {
  draft: '待办',
  ready: '待办',
  working: '运行中',
  blocked: '卡住',
  done: '完成',
}

export const RUN_STATE_TONE: Record<NodeRunState, string> = {
  draft: 'todo',
  ready: 'todo',
  working: 'running',
  blocked: 'blocked',
  done: 'done',
}

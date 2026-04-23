// Per-session "未读通知" 标记。
//
// 触发：session.status 从工作态 (active/tooling/thinking/compacting)
//       转到休息态 (idle/completed/waitingForUser) —— 代表 "Claude 刚
//       完成一轮回复"。
// 清除：用户点击对应的 session card（selection 切换到该 sid）。
//
// 只记 sid 集合，不绑时间戳：lastActivity 会被 SessionMonitor 2s poll 不断
// bump，不适合做"有没有新东西"的指纹。所以用"转换事件"本身当信号。
//
// 持久化到 localStorage，浏览器关掉重开后红点还在，直到用户点击确认。

const STORAGE_KEY = 'meee2.board.unreadSids.v1'

export function loadUnreadSids(): Set<string> {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return new Set()
    const arr = JSON.parse(raw)
    if (Array.isArray(arr)) return new Set(arr.filter((x) => typeof x === 'string'))
  } catch { /* ignore */ }
  return new Set()
}

export function saveUnreadSids(s: Set<string>): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify([...s]))
  } catch { /* quota / private mode */ }
}

export const WORKING_STATUSES = new Set([
  'active', 'tooling', 'thinking', 'compacting',
])
export const RESTING_STATUSES = new Set([
  'idle', 'completed', 'waitingForUser',
])

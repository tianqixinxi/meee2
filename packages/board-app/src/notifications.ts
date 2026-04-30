// Per-session "未读通知" 状态机使用的状态分类。
//
// 触发：session.status 从工作态 (active/tooling/thinking/compacting)
//       转到休息态 (idle/completed/waitingForUser) —— 代表 "Claude 刚
//       完成一轮回复" → 加红点
// 清除：用户点击对应的 session card（selection 切换到该 sid），或者
//       状态从休息态再变回工作态（用户已通过 terminal 直接回复）。
//
// 持久化通过 CanvasPersistence.{load,save}UnreadSids；这里只剩集合常量。

export const WORKING_STATUSES = new Set([
  'active', 'tooling', 'thinking', 'compacting',
])
export const RESTING_STATUSES = new Set([
  'idle', 'completed', 'waitingForUser',
])

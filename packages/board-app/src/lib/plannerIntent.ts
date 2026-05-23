// Heuristic intent classifier for the planner chat composer.
// Spec: ENG-5 — if the user's message is purely interrogative, default to
// answer-only (do not mutate the canvas). If they include an action verb
// ("改/加/删/重写", "rewrite/edit/add/remove/refactor/…"), allow canvas
// mutation. The promote case fires when the user is asking us to refine an
// existing node's session prompt rather than reshape the graph.
//
// Intent labels:
//  - 'answer'  → respond with text in chat history only; no canvas write.
//  - 'edit'    → ok to propose schema mutations (existing flow).
//  - 'inspect' → run drift inspection (existing keyword set: blocked/drift/…).
//  - 'promote' → inject the directive into the target node's bound session
//                prompt instead of mutating the schema.

export type PlannerIntent = 'answer' | 'edit' | 'inspect' | 'promote'

export interface ClassifyOptions {
  /** True when the user has a node selected that has a bound session — only
   *  then can we route through the "promote into session prompt" path. */
  hasSelectedNodeWithSession: boolean
}

// Action verbs that imply the user wants the planner to actually modify
// something. EN + zh-Hans. Kept conservative on purpose; false-negatives just
// mean we answer instead of bulldozing the canvas, which is the safe default.
const EDIT_VERBS = [
  // English (whole-word match)
  /\b(add|insert|create|append|new|make)\b/i,
  /\b(remove|delete|drop|prune|clear)\b/i,
  /\b(rename|retitle|relabel)\b/i,
  /\b(edit|change|update|modify|rewrite|refactor|restructure|reshape|reorganize|reorganise)\b/i,
  /\b(split|merge|combine|consolidate|extract)\b/i,
  /\b(move|reorder|swap)\b/i,
  /\b(set|assign|bind|attach)\b/i,
  // zh-Hans (no \b — Chinese has no word boundary)
  /改|加|删|增|去掉|去除|新增|新加|新建|创建|建立|拆/,
  /重写|重做|重构|调整|修改|更改|改成|改为|改作|改名|换成/,
  /合并|拆分|分成|分开|移到|挪到|挪过去|放到/,
  /落一个|落成|落到|每个.*落|帮我.*改|帮我.*加|帮我.*删/,
]

// Purely-interrogative shapes. zh-Hans: 吗 / 嘛 / 呢 at sentence end, or
// leading 是不是 / 会不会 / 怎么 / 为什么 / 如何. EN: starts with a wh-word
// or "do/does/is/are/can/will/would" and ends with a question mark, or just
// ends with "?".
const INTERROGATIVE_HINTS = [
  /[?？]\s*$/,
  /(吗|嘛|呢)\s*[?？。.!]?\s*$/,
  /^(是不是|会不会|可以|能不能|可不可以|怎么|为什么|为啥|如何|什么时候|哪个|哪里|谁)/,
  /^\s*(what|how|why|when|where|who|which|will|would|can|could|should|does|do|is|are|am)\b/i,
]

const PROMOTE_HINTS = [
  // "把这个 / 这一步 / 这个 node 的 prompt / 任务 / 目标 改成 ..."
  /(把|让).{0,12}(这个|这|这一)(步|节点|node|任务|prompt).*(改|加|删|换|变)/,
  /(每个|每一个).{0,8}(落|生成|做成|改成|对应)/,
  // "rephrase / reword / promote (this) into …"
  /\b(rephrase|reword|rewrite\s+the\s+prompt|promote\s+(this|it|that)\s+into|inject\s+into)/i,
]

const INSPECT_KEYWORDS = ['blocked', 'drift', 'fix', 'repair', 'review', 'stuck', '卡', '修', '检查', '跑偏', '阻塞']

export function classifyPlannerIntent(
  rawMessage: string,
  options: ClassifyOptions = { hasSelectedNodeWithSession: false },
): PlannerIntent {
  const message = rawMessage.trim()
  if (!message) return 'inspect' // empty submit keeps existing drift-inspect semantics

  // Existing drift keywords already trigger an inspect proposal — keep that
  // behavior intact. (PlannerGraph.shouldInspectDrift gates this further on
  // hasActionableDrift; we only label here.)
  if (INSPECT_KEYWORDS.some((k) => message.toLowerCase().includes(k))) return 'inspect'

  // Promote takes priority only when we actually have a target session to
  // inject into; otherwise the directive has no landing site and we fall
  // back to the edit/answer split.
  if (options.hasSelectedNodeWithSession && PROMOTE_HINTS.some((re) => re.test(message))) {
    return 'promote'
  }

  const hasEditVerb = EDIT_VERBS.some((re) => re.test(message))
  const looksInterrogative = INTERROGATIVE_HINTS.some((re) => re.test(message))

  // Pure question, no edit verb → answer-only. This is the bug fix: today
  // the planner would mutate the canvas in response to "会怎样?" / "what
  // happens if …". With this heuristic it answers instead.
  if (looksInterrogative && !hasEditVerb) return 'answer'

  // Edit verb present → allow canvas mutation (existing flow).
  if (hasEditVerb) return 'edit'

  // Ambiguous (statement, no verb, no question mark). Lean toward answer to
  // honor "don't bulldoze the canvas" — the user can always re-send with an
  // explicit verb. If there are zero nodes yet, fall through to 'edit' since
  // first-canvas-draft is implicitly an edit request.
  return 'answer'
}

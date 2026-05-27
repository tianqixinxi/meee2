export interface AIRecapPromptState {
  canvas: {
    title: string
    plannerContext?: string | null
  }
  nodes: Array<{
    title: string
    status: string
    workflowRunState?: string | null
    blockedReason?: string | null
    nextAction?: string | null
    schema: {
      inputs: string[]
      outputs: string[]
    }
    dependsOnNodeIds?: string[] | null
    sessionId?: string | null
    schedule?: { enabled?: boolean | null } | null
  }>
  artifacts: Array<{
    title: string
    kind: string
    status: string
    nodeId: string
    createdAt: string
  }>
  proposals: Array<{
    status: string
    summary: string
    changes: unknown[]
  }>
  events?: Array<{
    type: string
    summary: string
    createdAt: string
  }> | null
}

export function buildAIRecapPrompt(state: AIRecapPromptState): string {
  const payload = {
    canvas: {
      title: state.canvas.title,
      context: state.canvas.plannerContext,
    },
    nodes: state.nodes.slice(0, 24).map((node) => ({
      title: node.title,
      status: node.status,
      workflowRunState: node.workflowRunState ?? null,
      blockedReason: node.blockedReason ?? null,
      nextAction: node.nextAction ?? null,
      inputs: node.schema.inputs,
      outputs: node.schema.outputs,
      dependsOnNodeIds: node.dependsOnNodeIds ?? [],
      hasSession: Boolean(node.sessionId),
      scheduled: Boolean(node.schedule?.enabled),
    })),
    artifacts: state.artifacts.slice(-12).map((artifact) => ({
      title: artifact.title,
      kind: artifact.kind,
      status: artifact.status,
      nodeId: artifact.nodeId,
      createdAt: artifact.createdAt,
    })),
    pendingProposals: state.proposals
      .filter((proposal) => proposal.status === 'pending')
      .slice(0, 5)
      .map((proposal) => ({ summary: proposal.summary, changeCount: proposal.changes.length })),
    latestEvents: [...(state.events ?? [])]
      .sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt))
      .slice(0, 8)
      .map((event) => ({
        type: event.type,
        summary: event.summary,
        createdAt: event.createdAt,
      })),
  }
  return [
    '你是 meee2 的画板 recap writer。只根据下面 JSON 生成用户能快速理解画板的摘要。',
    '不要复述状态计数，不要写 ready/running/done/artifacts 的数字串；那些会由 UI 单独显示。',
    'headline 必须是最重要的业务判断、风险、瓶颈或下一步，不是状态标题。',
    '用中文。返回严格 JSON，不要 markdown，不要代码块。',
    '格式: {"headline":"不超过32个中文字符","details":["2-4条，每条不超过48个中文字符"]}',
    '',
    JSON.stringify(payload),
  ].join('\n')
}

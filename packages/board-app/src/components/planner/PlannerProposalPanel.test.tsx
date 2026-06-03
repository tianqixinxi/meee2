import { fireEvent, render, screen } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../../lib/i18n'
import { parseConfirmedPlanDraft } from '../../lib/plannerPlanDraft'
import { PlannerProposalPanel } from './PlannerProposalPanel'

const apiMocks = vi.hoisted(() => ({
  fetchLocalAssistantSessionMessages: vi.fn(),
  streamAssistantChat: vi.fn(),
}))

vi.mock('../../api', async () => {
  const actual = await vi.importActual<typeof import('../../api')>('../../api')
  return {
    ...actual,
    fetchLocalAssistantSessionMessages: apiMocks.fetchLocalAssistantSessionMessages,
    streamAssistantChat: apiMocks.streamAssistantChat,
  }
})

function streamText(text: string) {
  return (async function* () {
    yield { type: 'delta' as const, text }
  })()
}

describe('PlannerProposalPanel empty canvas intake', () => {
  beforeEach(() => {
    window.localStorage.clear()
    apiMocks.fetchLocalAssistantSessionMessages.mockResolvedValue({ sessionId: null, messages: [] })
    apiMocks.streamAssistantChat.mockReset()
  })

  it('renders a plan card when the model returns an ask action with a concrete plan object', async () => {
    apiMocks.streamAssistantChat.mockImplementation(() => streamText(JSON.stringify({
      action: 'ask',
      message: '我来帮你规划节点流程。以下是执行计划：',
      question: 'What should I optimize for?',
      plan: {
        title: '舆情洞察执行计划',
        intro: '下面是可执行节点草案，请确认是否继续。',
        steps: [
          {
            title: '收集公开舆情',
            body: '**Input:** 产品关键词 **Actor/Tool:** Web 检索工具 **Output/Artifact:** 原始来源列表。',
          },
          {
            title: '生成飞书文档',
            body: '输入分析结论和引用来源，输出结构化飞书文档草稿。',
          },
        ],
        prompt: 'Draft a concrete meee2 canvas for public sentiment collection and Feishu document output.',
      },
    })))

    render(
      <I18nProvider>
        <PlannerProposalPanel
          canvasId="empty-canvas-plan-test"
          canvasName="Meee2舆情洞察"
          proposal={null}
          previewGraph={{ nodes: [], edges: [] }}
          busy={false}
          error={null}
          access={{
            actorId: 'local-user',
            role: 'owner',
            canCreateProposal: true,
            canApproveProposal: true,
            canApplyProposal: true,
            canRejectProposal: true,
            canUpdateAssignedNode: true,
          }}
          nodeCount={0}
          hasActionableDrift={false}
          onSubmit={vi.fn()}
          onApproveAndApply={vi.fn()}
          onReject={vi.fn()}
          initialIntakeMessage={{ id: 1, text: '收集互联网关于Meee2产品的舆情，并总结分析，输出飞书文档' }}
          emptyMode
          layout="omni"
        />
      </I18nProvider>,
    )

    expect(await screen.findByRole('heading', { name: '舆情洞察执行计划' })).toBeInTheDocument()
    expect(screen.getByText('收集公开舆情')).toBeInTheDocument()
    expect(screen.getByText('Input')).toBeInTheDocument()
    expect(screen.getByText('Actor / Tool')).toBeInTheDocument()
    expect(screen.getByText('Output')).toBeInTheDocument()
    expect(screen.queryByText(/\*\*Input:/)).not.toBeInTheDocument()
    expect(screen.queryByText('What should I optimize for?')).not.toBeInTheDocument()
    const prompt = JSON.stringify(apiMocks.streamAssistantChat.mock.calls[0]?.[0]?.messages ?? [])
    expect(prompt).toContain('A meee2 canvas can be a workflow, monitor, or scene')
    expect(prompt).toContain('Scene canvas rule')
    expect(prompt).not.toContain('A meee2 canvas is a graph of executable node cards connected by dependencies')
  })

  it('submits a confirmed scene template payload when the model returns a poker scene plan', async () => {
    const onSubmit = vi.fn()
    apiMocks.streamAssistantChat.mockImplementation(() => streamText(JSON.stringify({
      action: 'plan',
      message: '这是一个牌桌 scene canvas。',
      plan: {
        title: '德州扑克 Scene Canvas',
        intro: '确认后用官方 Poker Table 模板创建新画布。',
        canvasPresentation: 'scene',
        templateId: 'poker-table',
        adaptationPrompt: '4 人德州扑克，有 Dealer、3 个玩家和 GM 审批。',
        steps: [
          { title: 'Dealer Agent', body: '维护 game-state.json 和 action-log.json。' },
          { title: '玩家 Agent', body: '每个玩家根据当前牌局行动。' },
          { title: 'GM / 规则裁判', body: '审批揭示和规则争议。' },
        ],
      },
    })))

    render(
      <I18nProvider>
        <PlannerProposalPanel
          canvasId="empty-canvas-scene-plan-test"
          canvasName="德州扑克"
          proposal={null}
          previewGraph={{ nodes: [], edges: [] }}
          busy={false}
          error={null}
          access={{
            actorId: 'local-user',
            role: 'owner',
            canCreateProposal: true,
            canApproveProposal: true,
            canApplyProposal: true,
            canRejectProposal: true,
            canUpdateAssignedNode: true,
          }}
          nodeCount={0}
          hasActionableDrift={false}
          onSubmit={onSubmit}
          onApproveAndApply={vi.fn()}
          onReject={vi.fn()}
          initialIntakeMessage={{ id: 20, text: '我想开一个 4 人德州扑克 AI 牌局，有 Dealer、3 个玩家、GM 审批' }}
          emptyMode
          layout="omni"
        />
      </I18nProvider>,
    )

    expect(await screen.findByRole('heading', { name: '德州扑克 Scene Canvas' })).toBeInTheDocument()
    expect(screen.getByText('Official scene template · Poker Table')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Use scene template' }))

    expect(onSubmit).toHaveBeenCalledTimes(1)
    const draft = parseConfirmedPlanDraft(String(onSubmit.mock.calls[0][0]))
    expect(draft).toMatchObject({
      canvasPresentation: 'scene',
      templateId: 'poker-table',
      adaptationPrompt: '4 人德州扑克，有 Dealer、3 个玩家和 GM 审批。',
    })
  })

  it('turns a generic optimization question into a plan for a concrete request', async () => {
    apiMocks.streamAssistantChat.mockImplementation(() => streamText(JSON.stringify({
      action: 'ask',
      message: '我来帮你规划舆情收集和飞书文档输出的节点流程。以下是执行计划：',
      question: 'What should I optimize for?',
      choices: [],
    })))

    render(
      <I18nProvider>
        <PlannerProposalPanel
          canvasId="empty-canvas-generic-ask-test"
          canvasName="Meee2舆情洞察"
          proposal={null}
          previewGraph={{ nodes: [], edges: [] }}
          busy={false}
          error={null}
          access={{
            actorId: 'local-user',
            role: 'owner',
            canCreateProposal: true,
            canApproveProposal: true,
            canApplyProposal: true,
            canRejectProposal: true,
            canUpdateAssignedNode: true,
          }}
          nodeCount={0}
          hasActionableDrift={false}
          onSubmit={vi.fn()}
          onApproveAndApply={vi.fn()}
          onReject={vi.fn()}
          initialIntakeMessage={{ id: 2, text: '收集互联网关于Meee2产品的舆情，并总结分析，输出飞书文档' }}
          emptyMode
          layout="omni"
        />
      </I18nProvider>,
    )

    expect(await screen.findByRole('heading', { name: '舆情分析与飞书输出计划' })).toBeInTheDocument()
    expect(screen.getByText('收集公开舆情来源')).toBeInTheDocument()
    expect(screen.getByText('生成飞书文档草稿')).toBeInTheDocument()
    expect(screen.queryByText('What should I optimize for?')).not.toBeInTheDocument()
  })

  it('submits a confirmed plan payload when drafting from a plan card', async () => {
    const onSubmit = vi.fn()
    apiMocks.streamAssistantChat.mockImplementation(() => streamText(JSON.stringify({
      action: 'ask',
      message: '我来帮你规划舆情收集和飞书文档输出的节点流程。以下是执行计划：',
      question: 'What should I optimize for?',
      choices: [],
    })))

    render(
      <I18nProvider>
        <PlannerProposalPanel
          canvasId="empty-canvas-build-plan-test"
          canvasName="Meee2舆情洞察"
          proposal={null}
          previewGraph={{ nodes: [], edges: [] }}
          busy={false}
          error={null}
          access={{
            actorId: 'local-user',
            role: 'owner',
            canCreateProposal: true,
            canApproveProposal: true,
            canApplyProposal: true,
            canRejectProposal: true,
            canUpdateAssignedNode: true,
          }}
          nodeCount={0}
          hasActionableDrift={false}
          onSubmit={onSubmit}
          onApproveAndApply={vi.fn()}
          onReject={vi.fn()}
          initialIntakeMessage={{ id: 3, text: '收集互联网关于Meee2产品的舆情，并总结分析，输出飞书文档' }}
          emptyMode
          layout="omni"
        />
      </I18nProvider>,
    )

    expect(await screen.findByRole('heading', { name: '舆情分析与飞书输出计划' })).toBeInTheDocument()
    const draftButton = screen.getAllByRole('button', { name: 'Draft canvas' })
      .find((button) => !(button as HTMLButtonElement).disabled)
    expect(draftButton).toBeTruthy()
    fireEvent.click(draftButton!)

    expect(onSubmit).toHaveBeenCalledTimes(1)
    const draft = parseConfirmedPlanDraft(String(onSubmit.mock.calls[0][0]))
    expect(draft?.title).toBe('舆情分析与飞书输出计划')
    expect(draft?.steps.map((step) => step.title)).toEqual([
      '确认目标与输入',
      '收集公开舆情来源',
      '分析舆情主题与倾向',
      '生成飞书文档草稿',
    ])
  })

  it('repairs persisted generic optimization questions into the latest plan card', async () => {
    const canvasId = 'empty-canvas-persisted-generic-ask-test'
    window.localStorage.setItem(`meee2.planner.chatHistory.${canvasId}.v1`, JSON.stringify([
      {
        id: 'user:1',
        role: 'user',
        markdown: '收集互联网关于Meee2产品的舆情，并总结分析，输出飞书文档',
      },
      {
        id: 'planner:bad-1',
        role: 'planner',
        markdown: '我来帮你规划舆情收集和飞书文档输出的节点流程。以下是执行计划：\n\nWhat should I optimize for?',
        meta: ['question'],
      },
      {
        id: 'user:2',
        role: 'user',
        markdown: '重新输出下计划',
      },
      {
        id: 'planner:bad-2',
        role: 'planner',
        markdown: '收到，以下是重新整理的执行计划：\n\nWhat should I optimize for?',
        meta: ['question'],
      },
    ]))
    apiMocks.streamAssistantChat.mockImplementation(() => streamText(''))

    render(
      <I18nProvider>
        <PlannerProposalPanel
          canvasId={canvasId}
          canvasName="Meee2舆情洞察"
          proposal={null}
          previewGraph={{ nodes: [], edges: [] }}
          busy={false}
          error={null}
          access={{
            actorId: 'local-user',
            role: 'owner',
            canCreateProposal: true,
            canApproveProposal: true,
            canApplyProposal: true,
            canRejectProposal: true,
            canUpdateAssignedNode: true,
          }}
          nodeCount={0}
          hasActionableDrift={false}
          onSubmit={vi.fn()}
          onApproveAndApply={vi.fn()}
          onReject={vi.fn()}
          emptyMode
          layout="omni"
        />
      </I18nProvider>,
    )

    expect(await screen.findByRole('heading', { name: '舆情分析与飞书输出计划' })).toBeInTheDocument()
    expect(screen.getByText('重新输出下计划')).toBeInTheDocument()
    expect(screen.queryByText('What should I optimize for?')).not.toBeInTheDocument()
  })
})

import type { PlanChange, PlanningNode } from '../types'

export type PlannerCanvasPresentation = 'workflow' | 'scene'
export type OfficialSceneTemplateId = 'travel-squad' | 'poker-table'

export interface PlannerConfirmedPlanStep {
  title: string
  body: string
}

export interface PlannerConfirmedPlanDraft {
  title: string
  intro: string
  steps: PlannerConfirmedPlanStep[]
  prompt?: string
  canvasPresentation?: PlannerCanvasPresentation
  templateId?: OfficialSceneTemplateId
  adaptationPrompt?: string
}

export const CONFIRMED_PLAN_DRAFT_PREFIX = 'meee2:confirmed-plan:v1'

export function serializeConfirmedPlanDraft(draft: PlannerConfirmedPlanDraft): string {
  return [
    CONFIRMED_PLAN_DRAFT_PREFIX,
    JSON.stringify({
      title: draft.title,
      intro: draft.intro,
      steps: draft.steps,
      prompt: draft.prompt,
      canvasPresentation: draft.canvasPresentation,
      templateId: draft.templateId,
      adaptationPrompt: draft.adaptationPrompt,
    }, null, 2),
  ].join('\n')
}

export function parseConfirmedPlanDraft(value: string): PlannerConfirmedPlanDraft | null {
  const trimmed = value.trim()
  if (!trimmed.startsWith(CONFIRMED_PLAN_DRAFT_PREFIX)) return null
  const body = trimmed.slice(CONFIRMED_PLAN_DRAFT_PREFIX.length).trim()
  if (!body) return null
  try {
    const parsed = JSON.parse(body) as unknown
    if (!parsed || typeof parsed !== 'object') return null
    const item = parsed as Record<string, unknown>
    const title = cleanText(item.title)
    const intro = cleanText(item.intro)
    const steps = Array.isArray(item.steps)
      ? item.steps
        .map((step): PlannerConfirmedPlanStep | null => {
          if (!step || typeof step !== 'object') return null
          const next = step as Record<string, unknown>
          const stepTitle = cleanText(next.title)
          const bodyText = cleanText(next.body)
          if (!stepTitle || !bodyText) return null
          return { title: stepTitle, body: bodyText }
        })
        .filter((step): step is PlannerConfirmedPlanStep => Boolean(step))
      : []
    const canvasPresentation = normalizeCanvasPresentation(item.canvasPresentation)
    const templateId = normalizeOfficialSceneTemplateId(item.templateId)
    const sceneDraft = canvasPresentation === 'scene'
    if (!title || (!sceneDraft && steps.length === 0)) return null
    if (sceneDraft && !templateId) return null
    return {
      title,
      intro: intro || 'Confirmed plan',
      steps: sceneDraft && steps.length === 0 ? sceneTemplateSteps(templateId) : steps,
      prompt: cleanText(item.prompt) || undefined,
      canvasPresentation,
      templateId,
      adaptationPrompt: cleanText(item.adaptationPrompt) || undefined,
    }
  } catch {
    return null
  }
}

export function isScenePlanDraft(draft: PlannerConfirmedPlanDraft): draft is PlannerConfirmedPlanDraft & {
  canvasPresentation: 'scene'
  templateId: OfficialSceneTemplateId
} {
  return draft.canvasPresentation === 'scene' && Boolean(normalizeOfficialSceneTemplateId(draft.templateId))
}

export function buildConfirmedPlanGraphChanges(input: {
  canvasId: string
  actorId: string
  draft: PlannerConfirmedPlanDraft
  idSeed?: string
  existingNodeIds?: string[]
}): PlanChange[] {
  const seed = slugify(input.idSeed || Date.now().toString(36)) || 'plan'
  const usedIds = new Set(input.existingNodeIds ?? [])
  let previousNodeId: string | null = null
  return input.draft.steps.slice(0, 8).map((step, index) => {
    const id = uniqueNodeId(`node-${seed}-${index + 1}-${slugify(step.title) || 'step'}`, usedIds)
    const node: PlanningNode = {
      id,
      canvasId: input.canvasId,
      title: step.title,
      desc: compactDescription(step.body),
      schema: {
        inputs: index === 0
          ? ['confirmed owner goal', 'canvas context']
          : [`output from ${input.draft.steps[index - 1]?.title ?? 'previous step'}`],
        outputs: [`${step.title} output`],
        goal: step.body,
      },
      contextSources: [],
      executionMode: 'auto',
      executorType: 'claude',
      doerId: input.actorId,
      reviewerIds: [],
      approverIds: [],
      handoffPolicy: 'none',
      status: 'ready',
      source: 'planner',
      dependsOnNodeIds: previousNodeId ? [previousNodeId] : [],
      nodeKind: 'step',
    }
    previousNodeId = id
    return { kind: 'addNode', node }
  })
}

function cleanText(value: unknown): string {
  return typeof value === 'string' ? value.replace(/\s+/g, ' ').trim() : ''
}

function normalizeCanvasPresentation(value: unknown): PlannerCanvasPresentation | undefined {
  return value === 'scene' || value === 'workflow' ? value : undefined
}

function normalizeOfficialSceneTemplateId(value: unknown): OfficialSceneTemplateId | undefined {
  return value === 'travel-squad' || value === 'poker-table' ? value : undefined
}

function sceneTemplateSteps(templateId: OfficialSceneTemplateId | undefined): PlannerConfirmedPlanStep[] {
  if (templateId === 'poker-table') {
    return [
      { title: 'Dealer Agent', body: 'Maintains game-state.json and action-log.json for the table.' },
      { title: 'Player Agents', body: 'Each player node decides legal actions from the current game state.' },
      { title: 'GM / 规则裁判', body: 'Human review node for reveals, legality, and rulings.' },
    ]
  }
  if (templateId === 'travel-squad') {
    return [
      { title: '路线规划 Agent', body: 'Produces itinerary.json for the route and timeline.' },
      { title: '酒店 / 美食 Agent', body: 'Produces booking-candidates.json and places.json.' },
      { title: '预算与最终确认', body: 'Human approval nodes finalize budget.json and the travel brief.' },
    ]
  }
  return []
}

function compactDescription(value: string): string {
  const text = cleanText(value)
  return text.length > 180 ? `${text.slice(0, 177)}...` : text
}

function slugify(value: string): string {
  return value
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 42)
}

function uniqueNodeId(base: string, usedIds: Set<string>): string {
  let candidate = base
  let suffix = 2
  while (usedIds.has(candidate)) {
    candidate = `${base}-${suffix}`
    suffix += 1
  }
  usedIds.add(candidate)
  return candidate
}

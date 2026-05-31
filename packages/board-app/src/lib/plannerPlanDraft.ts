import type { PlanChange, PlanningNode } from '../types'

export interface PlannerConfirmedPlanStep {
  title: string
  body: string
}

export interface PlannerConfirmedPlanDraft {
  title: string
  intro: string
  steps: PlannerConfirmedPlanStep[]
  prompt?: string
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
    if (!title || steps.length === 0) return null
    return {
      title,
      intro: intro || 'Confirmed plan',
      steps,
      prompt: cleanText(item.prompt) || undefined,
    }
  } catch {
    return null
  }
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

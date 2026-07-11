import { stableRecapFingerprint } from './fingerprint.js'
import type {
  DisplaySessionTitle,
  DisplaySessionTitleInput,
  EvidenceRef,
  ProviderRecapIntent,
  ProviderRecapSignal,
  RecapConfidence,
  RecapStatusSignal,
  SessionRecap,
  SessionRecapBuildInput,
} from './types.js'

const TITLE_MAX = 48
const DETAIL_MAX = 180

export function buildSessionRecap(input: SessionRecapBuildInput): SessionRecap | null {
  const signals = (input.signals ?? [])
    .filter((signal) => signal.sessionId === input.sessionId && cleanText(signal.content))
    .sort(compareSignals)
  const primary = signals[0]
  const fallbackText = cleanText(input.currentTask) || latestAssistantText(input.recentMessages ?? [])
  const headlineSeed = primary?.content ?? fallbackText
  const headline = recapHeadline(headlineSeed)
  if (!headline) return null

  const details = unique([
    ...signals.map((signal) => recapDetail(signal.content)),
    fallbackText ? recapDetail(fallbackText) : '',
  ]).filter(Boolean).slice(0, 4)
  const evidenceRefs = [
    ...(input.evidenceRefs ?? []),
    ...signals.map(signalEvidenceRef),
  ]
  const displayTitle = primary && primary.intent !== 'context_compaction'
    ? displayTitleText(primary.content)
    : undefined
  const fingerprint = stableRecapFingerprint({
    sessionId: input.sessionId,
    provider: input.provider,
    title: input.title,
    status: input.status,
    currentTask: input.currentTask,
    signals: signals.map((signal) => ({
      id: signal.id,
      intent: signal.intent,
      content: signal.content,
      timestamp: signal.timestamp,
      confidence: signal.confidence,
    })),
    recentTail: (input.recentMessages ?? []).slice(-3),
    evidenceRefs: evidenceRefs.map((ref) => ref.id),
  })
  const generatedFrom = unique([
    ...signals.map((signal) => `provider-signal:${signal.intent}`),
    fallbackText ? 'session-state' : '',
  ]).filter(Boolean)

  return {
    scope: 'session',
    sessionId: input.sessionId,
    provider: input.provider,
    headline,
    ...(displayTitle ? { displayTitle } : {}),
    details,
    statusSignals: statusSignalsFor(input),
    evidenceRefs,
    source: {
      kind: signals.length > 0 ? (fallbackText ? 'mixed' : 'provider') : 'deterministic',
      provider: primary?.provider ?? input.provider,
      generatedFrom,
    },
    intent: primary?.intent,
    confidence: primary?.confidence ?? (primary ? 'medium' : 'low'),
    updatedAt: primary?.timestamp ?? input.now,
    fingerprint,
  }
}

export function deriveDisplaySessionTitle(input: DisplaySessionTitleInput): DisplaySessionTitle {
  const candidates: Array<{
    source: DisplaySessionTitle['source']
    confidence: RecapConfidence
    value?: string | null
  }> = [
    { source: 'manual_override', confidence: 'high', value: input.manualOverride },
    // Provider-owned semantic titles are stable conversation identity. Put them
    // ahead of recap/currentTask, which can change as work progresses. Generic
    // provider/project labels are rejected by isNoisyTitle and still fall back.
    { source: 'provider_title', confidence: 'high', value: input.providerTitle },
    {
      source: 'session_recap',
      confidence: input.sessionRecap?.confidence ?? 'medium',
      value: recapTitleCandidate(input.sessionRecap),
    },
    { source: 'current_task', confidence: 'medium', value: input.currentTask },
    { source: 'initial_prompt', confidence: 'medium', value: input.initialUserMessage },
    { source: 'fallback', confidence: 'low', value: input.fallbackTitle ?? input.providerDisplayName ?? 'Session' },
  ]
  for (const candidate of candidates) {
    const text = displayTitleText(candidate.value)
    if (text) {
      return { text, source: candidate.source, confidence: candidate.confidence }
    }
  }
  return { text: 'Session', source: 'fallback', confidence: 'low' }
}

export function displayTitleText(value: string | null | undefined): string | null {
  const cleaned = cleanTitle(value)
  if (!cleaned || isNoisyTitle(cleaned)) return null
  return truncate(cleaned, TITLE_MAX)
}

function recapTitleCandidate(recap: DisplaySessionTitleInput['sessionRecap']): string | null {
  if (!recap) return null
  if (recap.intent === 'context_compaction' && recap.confidence !== 'high') return null
  return recap.displayTitle || recap.headline
}

function recapHeadline(value: string | null | undefined): string | null {
  return displayTitleText(value) ?? (truncate(cleanText(value) ?? '', 64) || null)
}

function recapDetail(value: string | null | undefined): string {
  return truncate(cleanText(value) ?? '', DETAIL_MAX)
}

function cleanTitle(value: string | null | undefined): string | null {
  const raw = cleanText(value)
  if (!raw) return null
  const planRequest = extractPlanModeUserRequest(raw)
  if (planRequest) return cleanTitle(planRequest)
  if (/^Plan mode is enabled for this Codex session\./i.test(raw)) return null
  const firstLine = raw.split(/\n/)[0] ?? raw
  const firstSentence = firstLine.split(/。|[.!?]\s/)[0]?.trim() ?? firstLine
  const withoutSpeaker = firstSentence.replace(/^(user|assistant|human|system)\s*:\s*/i, '').trim()
  const withoutPlanSlash = withoutSpeaker.replace(/^\/plan(?:\s+|$)/i, '').trim()
  const withoutReportPrefix = withoutPlanSlash
    .replace(/^(final response summary|summary|recap)\s*[:：]\s*/i, '')
    .replace(/^(已完成|已经完成|正在处理|下一步是|implemented|completed)\s*[:：，,]?\s*/i, '')
    .trim()
  return withoutReportPrefix || null
}

function cleanText(value: string | null | undefined): string | null {
  const text = (value ?? '')
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/\[[^\]]+\]\([^)]+\)/g, '')
    .replace(/[#*_`>]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
  return text || null
}

function isNoisyTitle(value: string): boolean {
  const normalized = value.trim().toLowerCase()
  if (!normalized) return true
  if (/^https?:\/\//.test(normalized)) return true
  if (/^(codex|claude code|claude)$/i.test(value)) return true
  if (/^(codex|claude code|claude)\s+-\s+[^/\\]+$/i.test(value)) return true
  if (/^node\s+(?:node-)?[a-z0-9][a-z0-9-]{10,}(?:-transcript)?$/i.test(value)) return true
  if (/^(final response summary|summary|recap)\b/i.test(value)) return true
  if (value.length > 160) return true
  return false
}

function extractPlanModeUserRequest(value: string): string | null {
  const match = value.match(/User request:\s*([\s\S]+?)(?:\n\s*Important:|\n\s*We need|\n\s*Do not|$)/i)
  return match?.[1]?.trim() || null
}

function latestAssistantText(messages: Array<{ role: string; text: string }>): string | null {
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const message = messages[i]
    if (message.role.toLowerCase() === 'assistant' && cleanText(message.text)) return message.text
  }
  return null
}

function compareSignals(a: ProviderRecapSignal, b: ProviderRecapSignal): number {
  const scoreDiff = signalScore(b) - signalScore(a)
  if (scoreDiff !== 0) return scoreDiff
  return timestampMs(b.timestamp) - timestampMs(a.timestamp)
}

function signalScore(signal: ProviderRecapSignal): number {
  const intentScore: Record<ProviderRecapIntent, number> = {
    human_recap: 100,
    manual_note: 90,
    final_summary: 75,
    context_compaction: 50,
  }
  const confidenceScore: Record<RecapConfidence, number> = {
    high: 6,
    medium: 0,
    low: -18,
  }
  return intentScore[signal.intent] + confidenceScore[signal.confidence ?? 'medium']
}

function timestampMs(value: string | null | undefined): number {
  const parsed = Date.parse(value ?? '')
  return Number.isNaN(parsed) ? 0 : parsed
}

function signalEvidenceRef(signal: ProviderRecapSignal): EvidenceRef {
  return {
    id: `provider-recap:${signal.id}`,
    kind: 'transcript',
    title: providerRecapIntentLabel(signal.intent),
    reference: signal.sourceRef ?? signal.id,
    createdAt: signal.timestamp ?? undefined,
    sessionId: signal.sessionId,
  }
}

function providerRecapIntentLabel(intent: ProviderRecapIntent): string {
  switch (intent) {
  case 'human_recap':
    return 'Provider human recap'
  case 'context_compaction':
    return 'Provider context compaction'
  case 'final_summary':
    return 'Provider final summary'
  case 'manual_note':
    return 'Manual recap note'
  }
}

function statusSignalsFor(input: SessionRecapBuildInput): RecapStatusSignal[] {
  const status = (input.status ?? '').trim()
  if (!status) return []
  return [{
    kind: statusSignalKind(status),
    label: status,
    subjectId: input.sessionId,
  }]
}

function statusSignalKind(status: string): RecapStatusSignal['kind'] {
  const normalized = status.toLowerCase()
  if (normalized.includes('permission') || normalized.includes('waiting')) return 'needs_approval'
  if (normalized.includes('dead') || normalized.includes('fail')) return 'failed'
  if (normalized.includes('complete') || normalized.includes('done')) return 'done'
  if (normalized.includes('run') || normalized.includes('active') || normalized.includes('tool')) return 'active'
  if (normalized.includes('idle')) return 'idle'
  return 'unknown'
}

function unique<T>(items: T[]): T[] {
  return Array.from(new Set(items))
}

function truncate(value: string, max: number): string {
  if (value.length <= max) return value
  return `${value.slice(0, Math.max(1, max - 1)).trimEnd()}…`
}

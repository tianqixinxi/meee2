import {
  buildSessionRecap,
  deriveDisplaySessionTitle,
  type DisplaySessionTitle,
  type ProviderRecapSignal as CoreProviderRecapSignal,
  type ProviderRecapIntent,
  type RecapConfidence,
  type SessionRecap as CoreSessionRecap,
} from '@meee1/recap-core'
import type { ProviderRecapSignal, Session } from '../types'

export function normalizedSessionRecap(session: Session, now = new Date().toISOString()): CoreSessionRecap | null {
  return buildSessionRecap({
    now,
    sessionId: session.id,
    provider: providerKey(session),
    title: session.title,
    status: session.status,
    currentTask: session.currentTask,
    signals: providerRecapSignals(session),
    recentMessages: session.recentMessages,
    evidenceRefs: [],
  })
}

export function displaySessionTitle(session: Session, manualOverride?: string | null): DisplaySessionTitle {
  const recap = normalizedSessionRecap(session)
  return deriveDisplaySessionTitle({
    manualOverride,
    sessionRecap: recap,
    currentTask: session.currentTask,
    initialUserMessage: initialUserMessage(session),
    providerTitle: session.title,
    fallbackTitle: projectFallbackTitle(session.project) ?? session.pluginDisplayName,
    providerDisplayName: session.pluginDisplayName,
  })
}

function projectFallbackTitle(project: string): string | null {
  const normalized = project.trim().replace(/[\\/]+$/, '')
  if (!normalized) return null
  const parts = normalized.split(/[\\/]/).filter(Boolean)
  return parts[parts.length - 1] || normalized
}

export function sessionRecapProgressText(session: Session): string | null {
  const recap = normalizedSessionRecap(session)
  if (recap?.headline) return recap.headline
  return session.latestRecap?.content?.trim() || null
}

function providerRecapSignals(session: Session): CoreProviderRecapSignal[] {
  const explicit = (session.providerRecapSignals ?? [])
    .map((signal) => coerceProviderRecapSignal(signal, session.id))
    .filter((signal): signal is CoreProviderRecapSignal => Boolean(signal))
  if (explicit.length > 0) return explicit
  const legacy = session.latestRecap?.content?.trim()
  if (!legacy) return []
  return [{
    id: `${providerKey(session)}:${session.id}:legacy-latest-recap`,
    provider: providerKey(session),
    sessionId: session.id,
    intent: 'human_recap',
    content: legacy,
    timestamp: session.latestRecap?.timestamp ?? null,
    sourceRef: 'legacy:latestRecap',
    confidence: 'high',
    metadata: { format: 'legacy.latestRecap' },
  }]
}

function coerceProviderRecapSignal(signal: ProviderRecapSignal, sessionId: string): CoreProviderRecapSignal | null {
  const content = signal.content?.trim()
  if (!content) return null
  return {
    id: signal.id,
    provider: signal.provider || 'unknown',
    sessionId,
    intent: coerceIntent(signal.intent),
    content,
    timestamp: signal.timestamp ?? null,
    sourceRef: signal.sourceRef ?? null,
    confidence: coerceConfidence(signal.confidence),
    metadata: signal.metadata,
  }
}

function coerceIntent(value: string | null | undefined): ProviderRecapIntent {
  switch (value) {
  case 'human_recap':
  case 'context_compaction':
  case 'final_summary':
  case 'manual_note':
    return value
  default:
    return 'human_recap'
  }
}

function coerceConfidence(value: string | null | undefined): RecapConfidence {
  switch (value) {
  case 'high':
  case 'medium':
  case 'low':
    return value
  default:
    return 'medium'
  }
}

function initialUserMessage(session: Session): string | null {
  for (const entry of session.recentMessages ?? []) {
    if (entry.role.toLowerCase() === 'user' && entry.text.trim()) return entry.text
  }
  return null
}

function providerKey(session: Session): string {
  const raw = `${session.pluginId} ${session.pluginDisplayName}`.toLowerCase()
  if (raw.includes('codex')) return 'codex'
  if (raw.includes('claude')) return 'claude'
  return session.pluginId || 'unknown'
}

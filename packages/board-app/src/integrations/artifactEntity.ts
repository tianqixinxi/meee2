/**
 * artifactEntity — bridge between the *artifact* path and the *view* path.
 *
 * The AI session produces external data (a GitHub PR, a Lark doc, …) and
 * attaches it to a node as a `PlannerArtifact` (via the artifact picker /
 * `attach_artifact_to_node`). This module projects such an artifact into an
 * `IntegrationEntity { schemaId, payload }` so the canvas view layer can
 * render it through the matching `IntegrationViewSchema` (badge / preview /
 * affordances) instead of a generic "type" chip.
 *
 * Design note (2026-05-29): the integration layer only owns *schema + view*.
 * It never fetches — the real fields here come straight from the attached
 * artifact the session already produced. `schemaId` follows the
 * `<integrationId>:<entityKind>` convention consumed by `getViewSchema()`.
 *
 * v0.1 scope: GitHub (`pr` / `issue` / `check_run`) + Lark (`doc`).
 */

import type {
  ArtifactPayload,
  IntegrationBadgeStatus,
  IntegrationEntity,
  PlannerArtifact,
} from '../types'

/**
 * Normalized payload the view-schema renderer reads. Keeping the field names
 * stable (`title` / `secondary` / `status` / `url`) lets `entityFromSchema`
 * fill a badge without a per-widget field mapping.
 */
export interface IntegrationEntityPayload {
  id: string
  title: string
  secondary?: string
  status: IntegrationBadgeStatus
  url?: string
  [extra: string]: unknown
}

const GITHUB_HOST = /(^|\/\/|\.)github\.com\//
const LARK_HOST = /(feishu\.cn|larksuite\.com|larkoffice\.com)/

/** Pull the typed integration payload if the artifact carries one. */
function integrationTypedPayload(
  payload: ArtifactPayload | null | undefined,
): Extract<ArtifactPayload, { type: 'integration' }> | undefined {
  return payload && payload.type === 'integration' ? payload : undefined
}

/** GitHub PR status from the artifact's kind + typed payload. */
function githubPrStatus(artifact: PlannerArtifact): IntegrationBadgeStatus {
  if (artifact.kind === 'main-merge') return 'done'
  const tp = artifact.typedPayload
  if (tp && tp.type === 'impl-pr') {
    if (tp.ciStatus === 'fail') return 'blocked'
    if (tp.ciStatus === 'running') return 'running'
  }
  return 'running' // open PR
}

/** GitHub check-run status from the typed payload. */
function githubCheckStatus(artifact: PlannerArtifact): IntegrationBadgeStatus {
  const tp = artifact.typedPayload
  if (tp && tp.type === 'check-result') {
    if (tp.fail > 0) return 'blocked'
    if (tp.pass > 0 || tp.skip > 0) return 'done'
  }
  return 'todo'
}

/**
 * Map one attached artifact to an `IntegrationEntity`, or `undefined` if it is
 * not a GitHub / Lark entity we know how to render.
 */
export function artifactToIntegrationEntity(
  artifact: PlannerArtifact,
): IntegrationEntity | undefined {
  const ref = artifact.reference ?? ''
  const typed = integrationTypedPayload(artifact.typedPayload)
  const url = (typed?.externalUrl ?? ref) || undefined

  const base = (
    schemaId: string,
    status: IntegrationBadgeStatus,
    secondary?: string,
  ): IntegrationEntity => {
    const payload: IntegrationEntityPayload = {
      id: artifact.id,
      title: artifact.title || typed?.summary || schemaId,
      status,
      ...(secondary ? { secondary } : {}),
      ...(url ? { url } : {}),
    }
    return { schemaId, payload }
  }

  // ── GitHub ───────────────────────────────────────────────────────────────
  const isGithubRef = GITHUB_HOST.test(ref) || typed?.connector === 'github'
  if (artifact.kind === 'check-result') {
    return base('github:check_run', githubCheckStatus(artifact))
  }
  if (artifact.kind === 'impl-pr' || artifact.kind === 'main-merge') {
    const tp = artifact.typedPayload
    const branch =
      tp && tp.type === 'impl-pr' ? `${tp.baseBranch}..${tp.branch}` : undefined
    return base('github:pr', githubPrStatus(artifact), branch)
  }
  if (isGithubRef && ref.includes('/pull/')) {
    return base('github:pr', githubPrStatus(artifact))
  }
  if (isGithubRef && ref.includes('/issues/')) {
    return base('github:issue', 'todo')
  }

  // ── Lark ─────────────────────────────────────────────────────────────────
  if (artifact.kind === 'lark-doc' || LARK_HOST.test(ref) || typed?.connector === 'lark') {
    return base('lark:doc', 'done')
  }

  return undefined
}

/**
 * Project a list of attached artifacts into the canvas integration-entity
 * pool consumed by `external` widgets. Non-integration artifacts are skipped.
 */
export function deriveIntegrationEntities(
  artifacts: readonly PlannerArtifact[],
): IntegrationEntity[] {
  const out: IntegrationEntity[] = []
  for (const artifact of artifacts) {
    const entity = artifactToIntegrationEntity(artifact)
    if (entity) out.push(entity)
  }
  return out
}

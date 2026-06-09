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
 * v0.1 scope: GitHub (`pr` / `issue` / `check_run`) + Lark (`doc`) +
 * Google Sheets (`sheet` / `tab`).
 */

import type {
  ArtifactPayload,
  IntegrationBadgeStatus,
  IntegrationEntity,
  PlannerArtifact,
} from '../types'
import { normalizeArtifactPayload } from '../lib/artifactPayload'

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
const GOOGLE_SHEETS_HOST = /docs\.google\.com\/spreadsheets\//

/**
 * Pull the typed integration payload if the artifact carries one.
 *
 * 线上 DTO 目前只带 legacy `payload`(没有 `typedPayload` 字段),所以这里
 * 必须用 normalizeArtifactPayload 兜底 — 否则凡是依赖 connector 字段识别的
 * integration(google-sheets 等非 URL 可辨的)在真实数据上永远投影不出来。
 * GitHub/Lark 靠 kind/URL 匹配掩盖了这个缺口。
 */
function integrationTypedPayload(
  artifact: PlannerArtifact,
): Extract<ArtifactPayload, { type: 'integration' }> | undefined {
  const payload: ArtifactPayload | null =
    artifact.typedPayload
      ?? normalizeArtifactPayload(artifact.payload, artifact.reviewStatus, artifact.kind)
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
  const typed = integrationTypedPayload(artifact)
  // 内部约定 scheme(gsheet:// 槽位引用、meee2-artifact://)不是可点的链接,
  // 不进 url;lark:// github:// 等真实 deep-link 保持原行为。外链以 typed
  // 里显式给的 externalUrl 优先。
  const isInternalRef = /^(gsheet|meee2-artifact):\/\//.test(ref)
  const url = (typed?.externalUrl ?? (isInternalRef ? undefined : ref)) || undefined

  const base = (
    schemaId: string,
    status: IntegrationBadgeStatus,
    secondary?: string,
  ): IntegrationEntity => {
    const payload: IntegrationEntityPayload = {
      // typed.fields 先铺底:扁平元数据(tab/rows/columns/updated…)进 entity
      // payload,view-schema 的 preview detail 行按 label 取值。标准字段在后,
      // 不会被 fields 覆盖。
      ...(typed?.fields ?? {}),
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

  // ── Google Sheets ────────────────────────────────────────────────────────
  // Tracker 是活账本:节点输出的是「某个 tab 的最新状态」,不是一次性文件。
  // `#gid=` / fields.tab 表示绑定到单个 worksheet tab(节点级输出面),
  // 否则视为整本 tracker(画布级账本)。状态默认 running(账本常活)。
  if (GOOGLE_SHEETS_HOST.test(ref) || typed?.connector === 'google-sheets') {
    const tabName = typed?.fields?.tab
    const isTab = /[#?&]gid=/.test(url ?? ref) || tabName != null
    return base(
      isTab ? 'google-sheets:tab' : 'google-sheets:sheet',
      'running',
      tabName != null ? String(tabName) : undefined,
    )
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

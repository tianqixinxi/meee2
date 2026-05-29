/**
 * Integration view-schema registry (chunk I).
 *
 * Static catalog of `(integrationId, entityKind)` → `IntegrationViewSchema`
 * derived from PRD `integration.md` §4. v0.1 covers the dogfood
 * integrations (GitHub / Linear / Slack / Notion / Lark); third-party additions go
 * through the `~/.meee2/integrations/<id>/manifest.json` path described in
 * PRD §6 and merge into this registry at runtime.
 *
 * No runtime fetch happens here — these are pure TS literals consumed by the
 * canvas renderers (KanbanCanvas v0.1) to look up icon/status mapping for an
 * `IntegrationEntity { schemaId, payload }`.
 */

import type { IntegrationViewSchema } from '../../types'
import { githubViewSchemas } from './github'
import { linearViewSchemas } from './linear'
import { slackViewSchemas } from './slack'
import { notionViewSchemas } from './notion'
import { larkViewSchemas } from './lark'

/** Flat list of every view-schema literal known to v0.1. */
export const ALL_INTEGRATION_VIEW_SCHEMAS: IntegrationViewSchema[] = [
  ...githubViewSchemas,
  ...linearViewSchemas,
  ...slackViewSchemas,
  ...notionViewSchemas,
  ...larkViewSchemas,
]

/** Indexed by `<integrationId>:<entityKind>` for O(1) lookup. */
const INDEX: ReadonlyMap<string, IntegrationViewSchema> = new Map(
  ALL_INTEGRATION_VIEW_SCHEMAS.map((s) => [`${s.integrationId}:${s.entityKind}`, s] as const),
)

/**
 * Look up the view-schema for an (integrationId, entityKind) pair.
 *
 * Returns `undefined` if unknown — the renderer should fall back to a
 * generic "unknown integration entity" badge rather than throw, so a stale
 * canvas referencing a removed integration doesn't crash the board.
 */
export function getViewSchema(
  integrationId: string,
  entityKind: string,
): IntegrationViewSchema | undefined {
  return INDEX.get(`${integrationId}:${entityKind}`)
}

export {
  githubViewSchemas,
  linearViewSchemas,
  slackViewSchemas,
  notionViewSchemas,
  larkViewSchemas,
}

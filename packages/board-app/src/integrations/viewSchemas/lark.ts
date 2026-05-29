/**
 * Lark integration view-schema literals.
 *
 * v0.1 entity kind: `doc` (Lark / Feishu cloud document). Matches the
 * `lark-doc` PlannerArtifactKind produced by the artifact picker
 * (`/api/integrations/lark/docs`) and the artifact → entity mapper.
 *
 * Like the GitHub literals these are *templates*: title / secondary / status
 * are filled from the attached artifact at runtime; the constants below pin
 * the static shape (icon, accent, affordances) that doesn't depend on the
 * entity.
 *
 * Real data is produced by the AI session (Lark MCP tools) and attached as an
 * artifact — the integration layer only owns this schema + the view rendering.
 */

import type { IntegrationViewSchema } from '../../types'

const LARK = 'lark'

export const larkDocViewSchema: IntegrationViewSchema = {
  integrationId: LARK,
  entityKind: 'doc',
  badge: {
    title: 'Lark doc',
    secondary: '',
    status: 'done',
    icon: 'file-text',
    accentColor: '#00d6b9', // Lark / Feishu teal
  },
  preview: {
    summary: 'Lark document',
    details: [
      { label: 'owner', value: '', kind: 'text' },
      { label: 'last edited', value: '', kind: 'text' },
      { label: 'link', value: '', kind: 'link' },
    ],
  },
  affordances: [
    { id: 'open-in-lark', label: 'Open in Lark', kind: 'link', payload: { url: '' } },
    { id: 'copy-url', label: 'Copy link', kind: 'copy', payload: { value: '' } },
  ],
}

export const larkViewSchemas: IntegrationViewSchema[] = [larkDocViewSchema]

/**
 * Google Sheets integration view-schema literals (PRD `integration.md` §4,
 * google-sheets addendum: workspace doc/prd/google-sheets-tracker-template.md).
 *
 * Two entity kinds:
 *   - `sheet` — a whole spreadsheet used as a living tracker (e.g. the
 *     venture-sourcing tracker). The canvas-level "ledger" view.
 *   - `tab`   — one worksheet tab inside a tracker. This is the per-node
 *     output surface: each step node writes its results into its own tab
 *     (Pipeline / Research / Market / Scoring), so the node's view renders
 *     the tab it owns, not the whole book.
 *
 * Like every integration here, this is *schema + view only* — no fetch.
 * Tab metadata (rows / columns / updated) rides in the attached artifact's
 * `typedPayload.fields` and is filled into the preview detail rows by
 * `entityFromSchema` (label-keyed lookup).
 */

import type { IntegrationViewSchema } from '../../types'

const GOOGLE_SHEETS = 'google-sheets'

export const googleSheetsSheetViewSchema: IntegrationViewSchema = {
  integrationId: GOOGLE_SHEETS,
  entityKind: 'sheet',
  badge: {
    title: 'Tracker',
    secondary: 'spreadsheet',
    status: 'running', // a tracker is a living ledger — default to active
    icon: 'table',
    accentColor: '#188038', // Sheets green
  },
  preview: {
    summary: 'Google Sheets tracker',
    details: [
      { label: 'tabs', value: '', kind: 'text' },
      { label: 'rows', value: '', kind: 'text' },
      { label: 'updated', value: '', kind: 'text' },
      { label: 'open', value: '', kind: 'link' },
    ],
  },
  affordances: [
    { id: 'open-in-sheets', label: 'Open in Google Sheets', kind: 'link', payload: { url: '' } },
    { id: 'copy-url', label: 'Copy sheet URL', kind: 'copy', payload: { value: '' } },
  ],
}

export const googleSheetsTabViewSchema: IntegrationViewSchema = {
  integrationId: GOOGLE_SHEETS,
  entityKind: 'tab',
  badge: {
    title: 'Tab',
    secondary: 'tracker tab',
    status: 'running',
    icon: 'table',
    accentColor: '#188038',
  },
  preview: {
    summary: 'Google Sheets tracker tab',
    details: [
      { label: 'tab', value: '', kind: 'text' },
      { label: 'rows', value: '', kind: 'text' },
      { label: 'columns', value: '', kind: 'text' },
      { label: 'updated', value: '', kind: 'text' },
    ],
  },
  affordances: [
    { id: 'open-tab', label: 'Open tab', kind: 'link', payload: { url: '' } },
    { id: 'copy-url', label: 'Copy tab URL', kind: 'copy', payload: { value: '' } },
  ],
}

export const googleSheetsViewSchemas: IntegrationViewSchema[] = [
  googleSheetsSheetViewSchema,
  googleSheetsTabViewSchema,
]

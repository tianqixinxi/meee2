/**
 * Notion integration view-schema literals (PRD `integration.md` §4.4).
 *
 * Entity kinds: `page`, `database`, `db_item`.
 */

import type { IntegrationViewSchema } from '../../types'

const NOTION = 'notion'

export const notionPageViewSchema: IntegrationViewSchema = {
  integrationId: NOTION,
  entityKind: 'page',
  badge: {
    title: 'Page —',
    secondary: 'breadcrumbs',
    status: 'todo',
    icon: 'file-text',
    accentColor: '#000000', // Notion mono
  },
  preview: {
    summary: 'Notion page',
    details: [
      { label: 'excerpt', value: '', kind: 'text' },
      { label: 'block stats', value: '0 paragraph · 0 todo · 0 code', kind: 'text' },
      { label: 'last edited by', value: '', kind: 'text' },
      { label: 'subpages', value: '', kind: 'text' },
    ],
  },
  affordances: [
    { id: 'open-in-notion', label: 'Open in Notion', kind: 'link', payload: { url: '' } },
    {
      id: 'append-block',
      label: 'Append block',
      kind: 'mcp_call',
      payload: { tool: 'mcp__notion__append_block' },
    },
    {
      id: 'export-markdown',
      label: 'Export to canvas artifact',
      kind: 'mcp_call',
      payload: { tool: 'mcp__notion__export_page' },
    },
  ],
}

export const notionDatabaseViewSchema: IntegrationViewSchema = {
  integrationId: NOTION,
  entityKind: 'database',
  badge: {
    title: 'DB —',
    secondary: '0 items',
    status: 'done',
    icon: 'database',
    accentColor: '#000000',
  },
  preview: {
    summary: 'Notion database',
    details: [
      { label: 'properties', value: '', kind: 'text' },
      { label: 'item count', value: '', kind: 'text' },
      { label: 'last edited', value: '', kind: 'text' },
    ],
  },
  affordances: [
    { id: 'open-in-notion', label: 'Open in Notion', kind: 'link', payload: { url: '' } },
    {
      id: 'add-item',
      label: 'Add item',
      kind: 'mcp_call',
      payload: { tool: 'mcp__notion__create_db_item' },
    },
  ],
}

export const notionDbItemViewSchema: IntegrationViewSchema = {
  integrationId: NOTION,
  entityKind: 'db_item',
  badge: {
    title: 'Item —',
    secondary: 'properties',
    status: 'todo',
    icon: 'rows',
    accentColor: '#000000',
  },
  preview: {
    summary: 'Notion database item',
    details: [
      { label: 'status', value: '', kind: 'text' },
      { label: 'assignee', value: '', kind: 'text' },
      { label: 'due', value: '', kind: 'text' },
      { label: 'tags', value: '', kind: 'text' },
    ],
  },
  affordances: [
    { id: 'open-in-notion', label: 'Open in Notion', kind: 'link', payload: { url: '' } },
    {
      id: 'update-status',
      label: 'Update status',
      kind: 'mcp_call',
      payload: { tool: 'mcp__notion__update_db_item' },
    },
  ],
}

export const notionViewSchemas: IntegrationViewSchema[] = [
  notionPageViewSchema,
  notionDatabaseViewSchema,
  notionDbItemViewSchema,
]

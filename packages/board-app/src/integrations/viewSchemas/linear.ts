/**
 * Linear integration view-schema literals (PRD `integration.md` §4.2).
 *
 * Entity kinds: `issue`, `cycle`, `project`.
 */

import type { IntegrationViewSchema } from '../../types'

const LINEAR = 'linear'

export const linearIssueViewSchema: IntegrationViewSchema = {
  integrationId: LINEAR,
  entityKind: 'issue',
  badge: {
    title: 'ENG-— —',
    secondary: 'cycle / priority',
    status: 'todo',
    icon: 'circle-half',
    accentColor: '#5e6ad2', // Linear brand
  },
  preview: {
    summary: 'Linear issue',
    details: [
      { label: 'assignee', value: '', kind: 'text' },
      { label: 'estimate', value: '', kind: 'text' },
      { label: 'comments', value: '', kind: 'text' },
      { label: 'linked PRs', value: '', kind: 'link' },
      { label: 'description', value: '', kind: 'text' },
    ],
  },
  affordances: [
    { id: 'view-in-linear', label: 'View in Linear', kind: 'link', payload: { url: '' } },
    {
      id: 'update-status',
      label: 'Update status',
      kind: 'mcp_call',
      payload: { tool: 'mcp__linear__update_issue' },
    },
    {
      id: 'add-comment',
      label: 'Add comment',
      kind: 'mcp_call',
      payload: { tool: 'mcp__linear__create_comment' },
    },
    { id: 'copy-url', label: 'Copy issue URL', kind: 'copy', payload: { value: '' } },
  ],
}

export const linearCycleViewSchema: IntegrationViewSchema = {
  integrationId: LINEAR,
  entityKind: 'cycle',
  badge: {
    title: 'Cycle —',
    secondary: 'team',
    status: 'todo',
    icon: 'repeat',
    accentColor: '#5e6ad2',
  },
  preview: {
    summary: 'Linear cycle',
    details: [
      { label: 'starts', value: '', kind: 'text' },
      { label: 'ends', value: '', kind: 'text' },
      { label: 'scope', value: '', kind: 'text' },
      { label: 'completed', value: '', kind: 'text' },
    ],
  },
  affordances: [
    { id: 'view-in-linear', label: 'View in Linear', kind: 'link', payload: { url: '' } },
  ],
}

export const linearProjectViewSchema: IntegrationViewSchema = {
  integrationId: LINEAR,
  entityKind: 'project',
  badge: {
    title: 'Project —',
    secondary: '0%',
    status: 'todo',
    icon: 'target',
    accentColor: '#5e6ad2',
  },
  preview: {
    summary: 'Linear project',
    details: [
      { label: 'lead', value: '', kind: 'text' },
      { label: 'target date', value: '', kind: 'text' },
      { label: 'progress', value: '', kind: 'text' },
      { label: 'description', value: '', kind: 'text' },
    ],
  },
  affordances: [
    { id: 'view-in-linear', label: 'View in Linear', kind: 'link', payload: { url: '' } },
  ],
}

export const linearViewSchemas: IntegrationViewSchema[] = [
  linearIssueViewSchema,
  linearCycleViewSchema,
  linearProjectViewSchema,
]

/**
 * GitHub integration view-schema literals (PRD `integration.md` §4.1).
 *
 * Three entity kinds: `pr`, `issue`, `check_run`. Each literal here is a
 * *template* — title / secondary / status are filled by the data adapter at
 * runtime; the constant values below describe the *shape* of the view + the
 * static affordances (icons, action buttons) that don't depend on the entity.
 */

import type { IntegrationViewSchema } from '../../types'

const GITHUB = 'github'

export const githubPrViewSchema: IntegrationViewSchema = {
  integrationId: GITHUB,
  entityKind: 'pr',
  badge: {
    title: '#— PR',
    secondary: 'base..head',
    status: 'running',
    icon: 'git-pull-request',
    accentColor: '#1f883d', // PR-open green
  },
  preview: {
    summary: 'GitHub pull request',
    details: [
      { label: 'branch', value: '', kind: 'link' },
      { label: 'reviewers', value: '', kind: 'text' },
      { label: 'checks', value: '✓ 0 / ✗ 0 / ⏳ 0', kind: 'text' },
      { label: 'last commit', value: '', kind: 'text' },
      { label: 'diff', value: '', kind: 'diff' },
    ],
  },
  affordances: [
    { id: 'view-on-github', label: 'View on GitHub', kind: 'link', payload: { url: '' } },
    {
      id: 'request-review',
      label: 'Request review',
      kind: 'mcp_call',
      payload: { tool: 'mcp__github__request_review' },
    },
    {
      id: 'comment',
      label: 'Comment',
      kind: 'mcp_call',
      payload: { tool: 'mcp__github__create_pr_comment' },
    },
    { id: 'copy-url', label: 'Copy PR URL', kind: 'copy', payload: { value: '' } },
  ],
}

export const githubIssueViewSchema: IntegrationViewSchema = {
  integrationId: GITHUB,
  entityKind: 'issue',
  badge: {
    title: '#— Issue',
    secondary: 'labels',
    status: 'todo',
    icon: 'circle-dot',
    accentColor: '#1f883d',
  },
  preview: {
    summary: 'GitHub issue',
    details: [
      { label: 'assignees', value: '', kind: 'text' },
      { label: 'labels', value: '', kind: 'text' },
      { label: 'comments', value: '', kind: 'text' },
      { label: 'linked PRs', value: '', kind: 'link' },
    ],
  },
  affordances: [
    { id: 'view-on-github', label: 'View on GitHub', kind: 'link', payload: { url: '' } },
    {
      id: 'comment',
      label: 'Comment',
      kind: 'mcp_call',
      payload: { tool: 'mcp__github__create_issue_comment' },
    },
    {
      id: 'close',
      label: 'Close',
      kind: 'mcp_call',
      payload: { tool: 'mcp__github__close_issue' },
    },
    { id: 'copy-url', label: 'Copy issue URL', kind: 'copy', payload: { value: '' } },
  ],
}

export const githubCheckRunViewSchema: IntegrationViewSchema = {
  integrationId: GITHUB,
  entityKind: 'check_run',
  badge: {
    title: 'CI: —',
    secondary: 'sha-—',
    status: 'todo',
    icon: 'check-circle',
  },
  preview: {
    summary: 'GitHub Actions check run',
    details: [
      { label: 'status', value: '', kind: 'text' },
      { label: 'conclusion', value: '', kind: 'text' },
      { label: 'started', value: '', kind: 'text' },
      { label: 'logs', value: '', kind: 'link' },
    ],
  },
  affordances: [
    { id: 'view-run', label: 'View run', kind: 'link', payload: { url: '' } },
    {
      id: 'rerun',
      label: 'Re-run',
      kind: 'mcp_call',
      payload: { tool: 'mcp__github__rerun_check' },
    },
    { id: 'copy-url', label: 'Copy run URL', kind: 'copy', payload: { value: '' } },
  ],
}

export const githubViewSchemas: IntegrationViewSchema[] = [
  githubPrViewSchema,
  githubIssueViewSchema,
  githubCheckRunViewSchema,
]

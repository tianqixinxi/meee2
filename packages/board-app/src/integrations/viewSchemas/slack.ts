/**
 * Slack integration view-schema literals (PRD `integration.md` §4.3).
 *
 * Entity kinds: `thread`, `channel`, `dm`.
 */

import type { IntegrationViewSchema } from '../../types'

const SLACK = 'slack'

export const slackThreadViewSchema: IntegrationViewSchema = {
  integrationId: SLACK,
  entityKind: 'thread',
  badge: {
    title: 'thread …',
    secondary: '#channel · 0 replies',
    status: 'awaiting',
    icon: 'message-square',
    accentColor: '#611f69', // Slack brand
  },
  preview: {
    summary: 'Slack thread',
    details: [
      { label: 'starter', value: '', kind: 'text' },
      { label: 'last reply', value: '', kind: 'text' },
      { label: 'mentions', value: '', kind: 'text' },
      { label: 'attachments', value: '', kind: 'image' },
    ],
  },
  affordances: [
    { id: 'open-in-slack', label: 'Open in Slack', kind: 'link', payload: { url: '' } },
    {
      id: 'reply',
      label: 'Reply',
      kind: 'mcp_call',
      payload: { tool: 'mcp__slack__post_message' },
    },
    {
      id: 'mark-read',
      label: 'Mark read',
      kind: 'mcp_call',
      payload: { tool: 'mcp__slack__mark_read' },
    },
    { id: 'copy-link', label: 'Copy thread link', kind: 'copy', payload: { value: '' } },
  ],
}

export const slackChannelViewSchema: IntegrationViewSchema = {
  integrationId: SLACK,
  entityKind: 'channel',
  badge: {
    title: '#channel',
    secondary: '0 members · 0 unread',
    status: 'done',
    icon: 'hash',
    accentColor: '#611f69',
  },
  preview: {
    summary: 'Slack channel',
    details: [
      { label: 'topic', value: '', kind: 'text' },
      { label: 'members', value: '', kind: 'text' },
      { label: 'last activity', value: '', kind: 'text' },
    ],
  },
  affordances: [
    { id: 'open-in-slack', label: 'Open in Slack', kind: 'link', payload: { url: '' } },
    {
      id: 'post-message',
      label: 'Post message',
      kind: 'mcp_call',
      payload: { tool: 'mcp__slack__post_message' },
    },
  ],
}

export const slackDmViewSchema: IntegrationViewSchema = {
  integrationId: SLACK,
  entityKind: 'dm',
  badge: {
    title: 'DM',
    secondary: '0 unread',
    status: 'blocked',
    icon: 'at-sign',
    accentColor: '#611f69',
  },
  preview: {
    summary: 'Slack direct message',
    details: [
      { label: 'with', value: '', kind: 'text' },
      { label: 'last message', value: '', kind: 'text' },
    ],
  },
  affordances: [
    { id: 'open-in-slack', label: 'Open in Slack', kind: 'link', payload: { url: '' } },
    {
      id: 'reply',
      label: 'Reply',
      kind: 'mcp_call',
      payload: { tool: 'mcp__slack__post_message' },
    },
  ],
}

export const slackViewSchemas: IntegrationViewSchema[] = [
  slackThreadViewSchema,
  slackChannelViewSchema,
  slackDmViewSchema,
]

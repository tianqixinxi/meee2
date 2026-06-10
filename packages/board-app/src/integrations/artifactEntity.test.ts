import { describe, expect, it } from 'vitest'
import { artifactToIntegrationEntity } from './artifactEntity'
import { getViewSchema } from './viewSchemas'
import type { PlannerArtifact } from '../types'

function sheetArtifact(overrides: Partial<PlannerArtifact> = {}): PlannerArtifact {
  return {
    id: 'art-1',
    canvasId: 'canvas-a',
    nodeId: 'node-1',
    kind: 'generic',
    title: 'Venture Tracker',
    reference: 'https://docs.google.com/spreadsheets/d/abc123/edit',
    status: 'ready',
    createdAt: '2026-06-09T00:00:00Z',
    ...overrides,
  }
}

describe('artifactToIntegrationEntity · google-sheets', () => {
  it('projects a bare spreadsheet URL to google-sheets:sheet', () => {
    const entity = artifactToIntegrationEntity(sheetArtifact())
    expect(entity?.schemaId).toBe('google-sheets:sheet')
    expect(getViewSchema('google-sheets', 'sheet')).toBeDefined()
  })

  it('projects a gid-anchored URL to google-sheets:tab', () => {
    const entity = artifactToIntegrationEntity(
      sheetArtifact({ reference: 'https://docs.google.com/spreadsheets/d/abc123/edit#gid=42' }),
    )
    expect(entity?.schemaId).toBe('google-sheets:tab')
    expect(getViewSchema('google-sheets', 'tab')).toBeDefined()
  })

  it('projects connector=google-sheets typedPayload with a tab field to :tab and surfaces fields', () => {
    const entity = artifactToIntegrationEntity(
      sheetArtifact({
        reference: 'meee2-artifact://tracker-pipeline',
        typedPayload: {
          type: 'integration',
          connector: 'google-sheets',
          externalId: 'abc123#gid=42',
          externalUrl: 'https://docs.google.com/spreadsheets/d/abc123/edit#gid=42',
          summary: 'Pipeline · 12 companies',
          fields: { tab: 'Pipeline', rows: 12, columns: 13 },
        },
      }),
    )
    expect(entity?.schemaId).toBe('google-sheets:tab')
    const payload = entity?.payload as Record<string, unknown>
    // fields 铺进 entity payload(view detail 行按 label 取值)
    expect(payload.tab).toBe('Pipeline')
    expect(payload.rows).toBe(12)
    // tab 名作为 badge secondary
    expect(payload.secondary).toBe('Pipeline')
    // 标准字段不被 fields 覆盖
    expect(payload.title).toBe('Venture Tracker')
    expect(payload.url).toBe('https://docs.google.com/spreadsheets/d/abc123/edit#gid=42')
  })

  it('projects the on-the-wire DTO shape (legacy payload only, no typedPayload)', () => {
    // BoardServer 的 artifact DTO 只带 legacy `payload` — 投影必须经
    // normalizeArtifactPayload 兜底,且内部 gsheet:// 引用不得变成可点链接。
    const entity = artifactToIntegrationEntity(
      sheetArtifact({
        reference: 'gsheet://venture-tracker/Pipeline',
        payload: {
          type: 'integration',
          connector: 'google-sheets',
          externalId: 'venture-tracker-template#Pipeline',
          summary: 'Pipeline tab · 模板就绪待建表',
          fields: { tab: 'Pipeline', columns: 13, rows: 0, updated: '2026-06-09' },
        },
      }),
    )
    expect(entity?.schemaId).toBe('google-sheets:tab')
    const payload = entity?.payload as Record<string, unknown>
    expect(payload.tab).toBe('Pipeline')
    expect(payload.columns).toBe(13)
    expect(payload.url).toBeUndefined()
  })

  it('does not shadow google-docs URLs', () => {
    const entity = artifactToIntegrationEntity(
      sheetArtifact({ reference: 'https://docs.google.com/document/d/abc123/edit' }),
    )
    expect(entity).toBeUndefined()
  })
})

import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { IntegrationArtifactView } from './IntegrationArtifactView'
import type { PlannerArtifact } from '../types'

// google-sheets tab 快照渲染:同步会话写回的 fields.values(二维行值)要画成
// 真实表体;老快照(只有 rows 计数)退回占位并在 footer 指路「同步快照」。

function sheetTabArtifact(fields: Record<string, unknown>): PlannerArtifact {
  return {
    id: 'art-sheet',
    canvasId: 'canvas-a',
    nodeId: 'node-a',
    kind: 'generic',
    title: 'Tracker · Pipeline',
    reference: 'gsheet://venture-tracker/Pipeline',
    status: 'done',
    createdAt: '2026-06-11T00:00:00.000Z',
    payload: {
      type: 'integration',
      connector: 'google-sheets',
      externalId: 'sheet-1#gid=0',
      externalUrl: 'https://docs.google.com/spreadsheets/d/sheet-1/edit?gid=0#gid=0',
      summary: 'Pipeline tab',
      fields: {
        tab: 'Pipeline',
        header: 'Company, Stage, Source',
        columns: 3,
        updated: '2026-06-11',
        ...fields,
      },
    },
  }
}

describe('IntegrationArtifactView · google-sheets tab', () => {
  it('renders real rows from fields.values', () => {
    render(
      <IntegrationArtifactView
        artifact={sheetTabArtifact({
          rows: 2,
          values: [
            ['Modal', 'Series C', 'TechCrunch'],
            ['Acme', 'Seed', 'YC'],
          ],
        })}
      />,
    )
    expect(screen.getByText('Modal')).toBeTruthy()
    expect(screen.getByText('Series C')).toBeTruthy()
    expect(screen.getByText('Acme')).toBeTruthy()
    // 有行值时不出现「快照未含行值」提示
    expect(screen.queryByText(/快照未含行值/)).toBeNull()
  })

  it('caps preview rows and surfaces the cap in footer facts', () => {
    const values = Array.from({ length: 12 }, (_, i) => [`Co-${i}`, 'Seed', 'src'])
    render(<IntegrationArtifactView artifact={sheetTabArtifact({ rows: 12, values })} />)
    expect(screen.getByText('Co-0')).toBeTruthy()
    expect(screen.getByText('Co-7')).toBeTruthy()
    expect(screen.queryByText('Co-8')).toBeNull()
    expect(screen.getByText(/显示前 8 行/)).toBeTruthy()
  })

  it('falls back to placeholder + sync hint when snapshot has counts but no values', () => {
    render(<IntegrationArtifactView artifact={sheetTabArtifact({ rows: 4 })} />)
    expect(screen.getByText('Company')).toBeTruthy()
    expect(screen.getByText(/4 行/)).toBeTruthy()
    expect(screen.getByText(/快照未含行值/)).toBeTruthy()
  })

  it('ignores malformed values without crashing', () => {
    render(
      <IntegrationArtifactView
        artifact={sheetTabArtifact({
          rows: 1,
          values: ['not-a-row', { bad: true }, [['nested'], null, 42]],
        })}
      />,
    )
    // 只有一行勉强合法(非标量格子置空,数字转字符串)
    expect(screen.getByText('42')).toBeTruthy()
  })
})

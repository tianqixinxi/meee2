import { describe, expect, it } from 'vitest'
import { parseArtifactJSON, parseTabular } from './TabularArtifactPreview'

describe('parseTabular', () => {
  it('projects an array of objects into columns + rows', () => {
    const data = parseTabular([
      { company: 'Acme', industry: 'AI infra', stage: 'Seed' },
      { company: 'Beta', industry: 'agentic AI', stage: 'A', website: 'https://beta.ai' },
    ])
    expect(data?.columns).toEqual(['company', 'industry', 'stage', 'website'])
    expect(data?.rows[0]).toEqual(['Acme', 'AI infra', 'Seed', ''])
    expect(data?.rows[1][3]).toBe('https://beta.ai')
    expect(data?.totalRows).toBe(2)
    expect(data?.droppedColumns).toBe(0)
  })

  it('caps rows at 30 and reports the real total', () => {
    const rows = Array.from({ length: 50 }, (_, i) => ({ company: `c${i}` }))
    const data = parseTabular(rows)
    expect(data?.rows.length).toBe(30)
    expect(data?.totalRows).toBe(50)
  })

  it('discovers columns from every rendered row, not just an early prefix', () => {
    // 键在第 25 行才首次出现 — 行在渲染范围内(MAX_ROWS=30),列必须被发现。
    const rows: Array<Record<string, unknown>> = Array.from({ length: 30 }, (_, i) => ({ company: `c${i}` }))
    rows[24].late_field = 'surfaced'
    const data = parseTabular(rows)
    expect(data?.columns).toContain('late_field')
    expect(data?.rows[24][1]).toBe('surfaced')
  })

  it('caps columns at 8 and counts dropped ones', () => {
    const wide = Object.fromEntries(Array.from({ length: 12 }, (_, i) => [`k${i}`, i]))
    const data = parseTabular([wide])
    expect(data?.columns.length).toBe(8)
    expect(data?.droppedColumns).toBe(4)
  })

  it('renders scalar arrays as a single value column', () => {
    const data = parseTabular(['a', 'b'])
    expect(data?.columns).toEqual(['value'])
    expect(data?.rows).toEqual([['a'], ['b']])
  })

  it('flattens nested string arrays into readable cells', () => {
    const data = parseTabular([{ company: 'Acme', founders: ['Ada', 'Bob'] }])
    expect(data?.rows[0][1]).toBe('Ada, Bob')
  })

  it('unwraps the dominant array field from an object root', () => {
    // 真实节点输出形状:{ thesis: {...}, candidates: [54], summary: {...} }
    const data = parseTabular({
      thesis: { stated: 'AI infra' },
      candidates: [
        { company: 'Acme', stage: 'Seed' },
        { company: 'Beta', stage: 'A' },
      ],
      summary: { total: 2 },
    })
    expect(data?.sourceKey).toBe('candidates')
    expect(data?.columns).toEqual(['company', 'stage'])
    expect(data?.totalRows).toBe(2)
  })

  it('rejects non-tabular shapes', () => {
    expect(parseTabular({ a: 1 })).toBeNull()
    expect(parseTabular('text')).toBeNull()
    expect(parseTabular([])).toBeNull()
    expect(parseTabular(null)).toBeNull()
  })
})

describe('parseArtifactJSON', () => {
  it('parses valid JSON and rejects invalid / oversized input', () => {
    expect(parseArtifactJSON('[{"a":1}]')).toEqual([{ a: 1 }])
    expect(parseArtifactJSON('not json')).toBeNull()
    expect(parseArtifactJSON(null)).toBeNull()
    expect(parseArtifactJSON('[1]', 1)).toBeNull()
  })
})

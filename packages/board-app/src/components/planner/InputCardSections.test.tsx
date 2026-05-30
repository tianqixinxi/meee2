import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import {
  InputCardSections,
  connectorFromSource,
  deriveExternalInputs,
  deriveUpstream,
  shortRef,
} from './InputCardSections'
import type { ContextSource, PlanningNode } from '../../types'

function node(overrides: Partial<PlanningNode> = {}): PlanningNode {
  return {
    id: 'node-1',
    canvasId: 'c1',
    title: 'Consumer',
    schema: { inputs: [], outputs: [], goal: '' },
    contextSources: [],
    executionMode: 'auto',
    executorType: 'claude',
    doerId: '',
    reviewerIds: [],
    approverIds: [],
    handoffPolicy: 'none',
    status: 'ready',
    ...overrides,
  } as PlanningNode
}

describe('deriveUpstream', () => {
  it('uses the first dependency as the upstream source node', () => {
    expect(deriveUpstream(node({ dependsOnNodeIds: ['dep-a', 'dep-b'] }))).toEqual({
      mode: 'passthrough',
      source_node: 'dep-a',
    })
  })

  it('returns a null source node (canvas entry) when there are no dependencies', () => {
    expect(deriveUpstream(node({ dependsOnNodeIds: [] }))).toEqual({
      mode: 'passthrough',
      source_node: null,
    })
    expect(deriveUpstream(node({ dependsOnNodeIds: null })).source_node).toBeNull()
  })
})

describe('deriveExternalInputs', () => {
  it('excludes chatHistory sources and maps the rest to external rows', () => {
    const sources: ContextSource[] = [
      { kind: 'chatHistory', title: 'chat', reference: '' },
      { kind: 'repository', title: 'repo', reference: 'github://acme/widgets' },
      { kind: 'document', title: 'Doc', reference: '' },
    ]
    const rows = deriveExternalInputs(node({ contextSources: sources }))
    expect(rows).toEqual([
      { connector: 'github', ref: 'github://acme/widgets', sync_session: null },
      { connector: 'document', ref: 'Doc', sync_session: null },
    ])
  })
})

describe('connectorFromSource', () => {
  it('extracts the scheme from the reference when present', () => {
    expect(connectorFromSource({ kind: 'repository', title: 't', reference: 'Lark://doc/123' })).toBe('lark')
  })

  it('falls back to the source kind when the reference has no scheme', () => {
    expect(connectorFromSource({ kind: 'document', title: 't', reference: 'plain-ref' })).toBe('document')
  })
})

describe('shortRef', () => {
  it('returns an em dash for empty refs', () => {
    expect(shortRef('')).toBe('—')
    expect(shortRef('   ')).toBe('—')
  })

  it('returns the ref unchanged at or under 36 chars', () => {
    expect(shortRef('repo://short/ref')).toBe('repo://short/ref')
  })

  it('elides the middle of a long ref keeping first 16 + last 16 chars', () => {
    const long = 'github://acme/widgets/very/long/path/segment/here.md'
    const result = shortRef(long)
    expect(result).toBe(`${long.slice(0, 16)}…${long.slice(-16)}`)
    expect(result).toContain('…')
  })
})

describe('InputCardSections (modal variant)', () => {
  it('renders the localized Chinese section labels and CTA', () => {
    const sources: ContextSource[] = [
      { kind: 'repository', title: 'repo', reference: 'github://acme/widgets' },
    ]
    render(
      <InputCardSections
        node={node({ contextSources: sources, dependsOnNodeIds: ['dep-a'] })}
        variant="modal"
      />,
    )
    expect(screen.getByText('上游')).toBeInTheDocument()
    expect(screen.getByText('外部源')).toBeInTheDocument()
    expect(screen.getByText('接入数据源')).toBeInTheDocument()
    expect(screen.getByText('全量传入')).toBeInTheDocument()
  })
})

import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import {
  InputCardSections,
  connectorFromSource,
  deriveDataSourceInputs,
  deriveExternalInputs,
  deriveUpstream,
  deriveUpstreamLinks,
  edgeModeLabel,
  shortRef,
} from './InputCardSections'
import type { CanvasEdge, ContextSource, DataSourceRecord, PlanningNode } from '../../types'

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

describe('deriveUpstream (legacy fallback)', () => {
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

describe('deriveExternalInputs (legacy fallback)', () => {
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

describe('edgeModeLabel (canvas runtime EdgeMode → 时机)', () => {
  it('maps document-snapshot strategies', () => {
    expect(edgeModeLabel({ mode: 'document-snapshot', strategy: { kind: 'follow-latest' } })).toBe('跟随最新')
    expect(edgeModeLabel({ mode: 'document-snapshot', strategy: { kind: 'pin-at-attempt-start' } })).toBe('开工时冻结')
    expect(edgeModeLabel({ mode: 'document-snapshot' })).toBe('跟随最新')
  })
  it('maps queue-claim with ordering, and dependency', () => {
    expect(edgeModeLabel({ mode: 'queue-claim', ordering: 'fifo' })).toBe('逐条认领 · fifo')
    expect(edgeModeLabel({ mode: 'dependency' })).toBe('依赖')
  })
})

describe('deriveUpstreamLinks (step → artifact → step)', () => {
  it('keeps every edge targeting this node and carries the intermediary artifact dataSourceId', () => {
    const edges: CanvasEdge[] = [
      {
        id: 'e1',
        sourceRef: { nodeId: 'main', sourceKey: 'frontend_spec', dataSourceId: 'art-1' },
        targetRef: { nodeId: 'node-1', inputKey: 'frontend_spec' },
        edgeMode: { mode: 'document-snapshot', strategy: { kind: 'follow-latest' } },
      },
      {
        id: 'e3',
        sourceRef: { nodeId: 'main' },
        targetRef: { nodeId: 'other' }, // 别的 target → 不算
        edgeMode: { mode: 'queue-claim' },
      },
    ]
    const links = deriveUpstreamLinks(node(), edges)
    expect(links).toHaveLength(1)
    expect(links[0]).toMatchObject({
      sourceNodeId: 'main',
      sourceKey: 'frontend_spec',
      inputKey: 'frontend_spec',
      artifactId: 'art-1', // 中介 artifact 不再被排除
    })
  })
})

describe('deriveDataSourceInputs (edge.dataSourceId → DataSource)', () => {
  it('resolves identity/selector/semantics from the bound DataSource', () => {
    const edges: CanvasEdge[] = [
      {
        id: 'e1',
        sourceRef: { nodeId: 'x', dataSourceId: 'ds-1' },
        targetRef: { nodeId: 'node-1', inputKey: 'docs' },
        edgeMode: { mode: 'document-snapshot' },
      },
    ]
    const dataSources: DataSourceRecord[] = [
      {
        id: 'ds-1',
        title: 'legacy-title',
        kind: 'fs',
        currentVersion: 0,
        identity: { connectorKind: 'fs', realm: 'fs:.' },
        selector: { mode: 'declarative', dialect: 'glob', expr: 'prd/**' },
        semantics: { label: 'PRD 草稿' },
      },
    ]
    const rows = deriveDataSourceInputs(node(), edges, dataSources)
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ label: 'PRD 草稿', connectorKind: 'fs', selectorHint: 'prd/**', inputKey: 'docs' })
  })
})

describe('InputCardSections (modal variant)', () => {
  it('falls back to legacy upstream pill (no硬编码 mode) when no canvas edges', () => {
    render(<InputCardSections node={node({ dependsOnNodeIds: ['dep-a'] })} variant="modal" />)
    expect(screen.getByText('上游')).toBeInTheDocument()
    expect(screen.getByText('外部源')).toBeInTheDocument()
    expect(screen.getByText('添加输入')).toBeInTheDocument()
    expect(screen.getByText('dep-a')).toBeInTheDocument()
    // 旧的硬编码「全量传入」已移除 —— fallback 不再假造 EdgeMode
    expect(screen.queryByText('全量传入')).not.toBeInTheDocument()
  })

  it('renders real EdgeMode timing + source node name from canvas edges', () => {
    const edges: CanvasEdge[] = [
      {
        id: 'e1',
        sourceRef: { nodeId: 'main', sourceKey: 'frontend_spec' },
        targetRef: { nodeId: 'node-1', inputKey: 'frontend_spec' },
        edgeMode: { mode: 'document-snapshot', strategy: { kind: 'follow-latest' } },
      },
    ]
    render(
      <InputCardSections
        node={node()}
        variant="modal"
        canvasEdges={edges}
        nodeTitleById={{ main: '主 Agent' }}
      />,
    )
    expect(screen.getByText('跟随最新')).toBeInTheDocument()
    expect(screen.getByText('主 Agent')).toBeInTheDocument()
  })

  it('renders the intermediary artifact label on an upstream link (step→artifact→step)', () => {
    const edges: CanvasEdge[] = [
      {
        id: 'e1',
        sourceRef: { nodeId: 'main', sourceKey: 'ideas', dataSourceId: 'art-ideas' },
        targetRef: { nodeId: 'node-1', inputKey: 'ideas' },
        edgeMode: { mode: 'document-snapshot', strategy: { kind: 'follow-latest' } },
      },
    ]
    const dataSources: DataSourceRecord[] = [
      { id: 'art-ideas', title: '本周想法清单', kind: 'canvas-runtime', currentVersion: 0, semantics: { label: '本周想法清单' } },
    ]
    render(
      <InputCardSections
        node={node()}
        variant="modal"
        canvasEdges={edges}
        canvasDataSources={dataSources}
        nodeTitleById={{ main: 'Capture ideas' }}
      />,
    )
    expect(screen.getByText('Capture ideas')).toBeInTheDocument()
    expect(screen.getByText('本周想法清单')).toBeInTheDocument() // 中介 artifact label
    expect(screen.getByText('跟随最新')).toBeInTheDocument()
  })

  it('renders sub-views from schema.subViews (Part C)', () => {
    render(
      <InputCardSections
        node={node({
          schema: {
            inputs: ['docs'],
            outputs: [],
            goal: '',
            subViews: { docs: { semantics: { label: '本周草稿' }, project: ['files'] } },
          },
        })}
        variant="modal"
      />,
    )
    expect(screen.getByText('子视图')).toBeInTheDocument()
    expect(screen.getByText('本周草稿')).toBeInTheDocument()
  })
})

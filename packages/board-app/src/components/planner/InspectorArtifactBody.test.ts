import { describe, expect, it } from 'vitest'
import { isOutputArtifactNode, isSeedAuthorableNode } from './InspectorArtifactBody'
import type { PlanningNode } from '../../types'

// Minimal artifact-node factory — only the fields isOutputArtifactNode reads.
function node(overrides: Partial<PlanningNode> = {}): PlanningNode {
  return {
    id: 'n1',
    canvasId: 'c1',
    title: 'Artifact',
    schema: { inputs: [], outputs: [], goal: '' },
    contextSources: [],
    executionMode: 'auto',
    executorType: 'claude',
    doerId: '',
    reviewerIds: [],
    approverIds: [],
    handoffPolicy: 'none',
    status: 'ready',
    nodeKind: 'artifact',
    dependsOnNodeIds: [],
    ...overrides,
  } as PlanningNode
}

describe('isOutputArtifactNode — gates the 数据来源 binding section', () => {
  // OUTPUT (execution product / derived) → NOT bindable, visualization only.
  it('upstream producer ⇒ output', () => {
    expect(isOutputArtifactNode(node({ dependsOnNodeIds: ['up-1'] }))).toBe(true)
  })

  it('declared input slot ⇒ output (transform/execution)', () => {
    expect(
      isOutputArtifactNode(node({ schema: { inputs: ['in'], outputs: [], goal: '' } })),
    ).toBe(true)
  })

  it('canvas-runtime artifactSource (Monitor) ⇒ output', () => {
    expect(isOutputArtifactNode(node({ artifactSource: { kind: 'canvas-runtime' } }))).toBe(true)
  })

  // BINDABLE (seed / mirrored) → keeps the 数据来源 picker.
  it('plain seed (no upstream, no inputs) ⇒ bindable', () => {
    expect(isOutputArtifactNode(node())).toBe(false)
  })

  it('mirrored dataSource (no upstream) ⇒ bindable — its binding is the point', () => {
    expect(
      isOutputArtifactNode(node({ artifactSource: { kind: 'dataSource', sourceId: 'src-1' } })),
    ).toBe(false)
  })

  // The seed-vs-exec discriminator: a slot/output *seed* with no upstream
  // producer is still hand-authorable, so it must remain bindable — proving we
  // don't naively treat every slot/output as an execution output.
  it('slot/output seed without upstream ⇒ bindable', () => {
    expect(
      isOutputArtifactNode(
        node({ artifactSource: { kind: 'slot', nodeId: 'n1', slotKey: 'out', direction: 'output' } }),
      ),
    ).toBe(false)
  })
})

describe('isSeedAuthorableNode — gates manual editor', () => {
  it('does not allow manual authoring for execution outputs with upstream producers', () => {
    expect(isSeedAuthorableNode(node({ dependsOnNodeIds: ['producer'] }))).toBe(false)
  })

  it('does not allow manual authoring for dataSource/canvas-runtime artifacts', () => {
    expect(isSeedAuthorableNode(node({ artifactSource: { kind: 'dataSource', sourceId: 'src-1' } }))).toBe(false)
    expect(isSeedAuthorableNode(node({ artifactSource: { kind: 'canvas-runtime' } }))).toBe(false)
  })

  it('allows manual authoring only for seed output slots', () => {
    expect(isSeedAuthorableNode(node({
      artifactSource: { kind: 'slot', nodeId: 'n1', slotKey: 'out', direction: 'output' },
    }))).toBe(true)
  })
})

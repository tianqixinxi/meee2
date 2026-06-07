import { useMemo } from 'react'
import type { Node } from '@xyflow/react'
import type { PlannerGraphEdge, PlannerGraphNode } from './plannerGraphAdapter'

interface Props {
  nodes: Array<PlannerGraphNode | Node<Record<string, unknown>>>
  edges: PlannerGraphEdge[]
}

interface NodeBox {
  id: string
  x: number
  y: number
  width: number
  height: number
  perception: string
}

const WIDTH = 220
const HEIGHT = 144
const PADDING = 14

export function PlannerOverviewMap({ nodes, edges }: Props) {
  const model = useMemo(() => buildOverviewModel(nodes), [nodes])

  if (model.boxes.length === 0) {
    return (
      <div className="planner-overview-map" aria-label="Graph overview">
        <span>No nodes</span>
      </div>
    )
  }

  return (
    <div className="planner-overview-map" aria-label="Graph overview">
      <svg viewBox={`0 0 ${WIDTH} ${HEIGHT}`} role="img" aria-label="Global graph overview">
        <rect className="planner-overview-map__frame" x="0.5" y="0.5" width={WIDTH - 1} height={HEIGHT - 1} rx="7" />
        {edges.map((edge) => {
          const source = model.boxById.get(edge.source)
          const target = model.boxById.get(edge.target)
          if (!source || !target) return null
          const sx = source.x + source.width
          const sy = source.y + source.height / 2
          const tx = target.x
          const ty = target.y + target.height / 2
          const midX = sx + Math.max(10, (tx - sx) / 2)
          const points = [
            `${sx.toFixed(1)},${sy.toFixed(1)}`,
            `${midX.toFixed(1)},${sy.toFixed(1)}`,
            `${midX.toFixed(1)},${ty.toFixed(1)}`,
            `${tx.toFixed(1)},${ty.toFixed(1)}`,
          ].join(' ')
          return (
            <polyline
              key={edge.id}
              className={`planner-overview-map__edge is-${edge.data?.perception ?? 'not-reached'}`}
              points={points}
            />
          )
        })}
        {model.boxes.map((box) => (
          <rect
            key={box.id}
            className={`planner-overview-map__node is-${box.perception}`}
            x={box.x}
            y={box.y}
            width={box.width}
            height={box.height}
            rx="3"
          />
        ))}
      </svg>
    </div>
  )
}

function buildOverviewModel(nodes: Props['nodes']): {
  boxes: NodeBox[]
  boxById: Map<string, NodeBox>
} {
  const rawBoxes = nodes.map((node) => {
    const maybePlanner = node as PlannerGraphNode
    const width = node.width ?? node.measured?.width ?? maybePlanner.data?.node?.layout?.width ?? 286
    const height = node.height ?? node.measured?.height ?? maybePlanner.data?.node?.layout?.height ?? 142
    return {
      id: node.id,
      x: node.position.x,
      y: node.position.y,
      width,
      height,
      perception: typeof maybePlanner.data?.perception === 'string' ? maybePlanner.data.perception : 'neutral',
    }
  })
  const minX = Math.min(...rawBoxes.map((box) => box.x))
  const minY = Math.min(...rawBoxes.map((box) => box.y))
  const maxX = Math.max(...rawBoxes.map((box) => box.x + box.width))
  const maxY = Math.max(...rawBoxes.map((box) => box.y + box.height))
  const graphWidth = Math.max(1, maxX - minX)
  const graphHeight = Math.max(1, maxY - minY)
  const scale = Math.min((WIDTH - PADDING * 2) / graphWidth, (HEIGHT - PADDING * 2) / graphHeight)
  const offsetX = (WIDTH - graphWidth * scale) / 2
  const offsetY = (HEIGHT - graphHeight * scale) / 2
  const boxes = rawBoxes.map((box) => ({
    id: box.id,
    x: offsetX + (box.x - minX) * scale,
    y: offsetY + (box.y - minY) * scale,
    width: Math.max(8, box.width * scale),
    height: Math.max(5, box.height * scale),
    perception: box.perception,
  }))
  return {
    boxes,
    boxById: new Map(boxes.map((box) => [box.id, box])),
  }
}

/**
 * UI-4 · "+ Transform" floating-button edge.
 *
 * A React Flow custom edge that renders the regular bezier path plus an
 * inline + button at the midpoint. The button is invisible by default and
 * fades in on hover (via planner.css). Clicking it asks the parent to insert
 * a transform-session node mid-edge, preserving the upstream/downstream
 * connections.
 *
 * The transform node is just a regular session-kind step — no special type —
 * matching the spec: "its prompt slot is editable as usual".
 */

import {
  BaseEdge,
  EdgeLabelRenderer,
  getBezierPath,
  type EdgeProps,
} from '@xyflow/react'
import { Plus } from 'lucide-react'

export interface TransformInsertEdgeData extends Record<string, unknown> {
  preview: boolean
  perception: string
  onInsertTransform?: (sourceNodeId: string, targetNodeId: string) => void
  /**
   * Suppress the + button (e.g. for preview / virtual artifact edges where
   * inserting a transform makes no sense).
   */
  suppressInsert?: boolean
}

export function TransformInsertEdge(props: EdgeProps) {
  const {
    id,
    sourceX,
    sourceY,
    targetX,
    targetY,
    sourcePosition,
    targetPosition,
    markerEnd,
    style,
    source,
    target,
    data,
  } = props
  const [path, labelX, labelY] = getBezierPath({
    sourceX,
    sourceY,
    sourcePosition,
    targetX,
    targetY,
    targetPosition,
  })
  const edgeData = (data ?? {}) as TransformInsertEdgeData
  const handler = edgeData.onInsertTransform
  const suppressed = edgeData.suppressInsert === true || edgeData.preview === true

  return (
    <>
      <BaseEdge id={id} path={path} style={style} markerEnd={markerEnd} />
      {!suppressed && handler && (
        <EdgeLabelRenderer>
          <div
            className="planner-edge-insert"
            style={{
              position: 'absolute',
              transform: `translate(-50%, -50%) translate(${labelX}px, ${labelY}px)`,
              pointerEvents: 'all',
            }}
          >
            <button
              type="button"
              className="planner-edge-insert__button nodrag nopan"
              aria-label={`Insert transform session between ${source} and ${target}`}
              title="Insert transform session"
              onClick={(event) => {
                event.stopPropagation()
                handler(source, target)
              }}
            >
              <Plus size={12} aria-hidden />
            </button>
          </div>
        </EdgeLabelRenderer>
      )}
    </>
  )
}

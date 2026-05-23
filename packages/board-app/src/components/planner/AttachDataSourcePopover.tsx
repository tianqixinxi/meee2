/**
 * UI-4 · Attach Data Source popover.
 *
 * Lists the user's connected connectors (from INT-1's
 * `/api/v1/connect/connectors` endpoint) and lets the user pick one + supply
 * a ref. On submit, asks the container to bind it to the node — today this
 * is a no-op + TODO; INT-2 wires it to a sync-session bind.
 *
 * When the endpoint returns an empty list (INT-2 not yet landed) we degrade
 * to a single stub row so the popover is still demonstrable end-to-end.
 */

import { Plug, X } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'

export interface ConnectorRow {
  id: string
  /** Display label e.g. "Notion", "GitHub Sandbox". */
  label: string
  /** Slug stored on `NodeContractExternalInput.connector`. */
  slug: string
}

export interface AttachDataSourcePopoverProps {
  nodeId: string
  onClose: () => void
  onSubmit: (input: { connectorSlug: string; ref: string }) => Promise<void> | void
}

export function AttachDataSourcePopover({
  nodeId,
  onClose,
  onSubmit,
}: AttachDataSourcePopoverProps) {
  const [connectors, setConnectors] = useState<ConnectorRow[]>([])
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [selectedSlug, setSelectedSlug] = useState<string>('')
  const [refValue, setRefValue] = useState<string>('')
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const refInputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    setLoadError(null)
    fetchConnectorsSafe()
      .then((rows) => {
        if (cancelled) return
        const list = rows.length > 0 ? rows : ECHO_REFERENCE_FALLBACK
        setConnectors(list)
        setSelectedSlug((current) => current || list[0]?.slug || '')
      })
      .catch((err) => {
        if (cancelled) return
        setConnectors(ECHO_REFERENCE_FALLBACK)
        setSelectedSlug(ECHO_REFERENCE_FALLBACK[0].slug)
        setLoadError((err as Error).message || 'Failed to load connectors')
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    refInputRef.current?.focus()
  }, [selectedSlug])

  const handleSubmit = async () => {
    const trimmedRef = refValue.trim()
    if (!selectedSlug || !trimmedRef) {
      setSubmitError('Pick a connector and provide a ref.')
      return
    }
    setSubmitting(true)
    setSubmitError(null)
    try {
      await onSubmit({ connectorSlug: selectedSlug, ref: trimmedRef })
      onClose()
    } catch (err) {
      setSubmitError((err as Error).message || 'Failed to attach data source')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div
      className="planner-attach-popover-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <div
        className="planner-attach-popover"
        role="dialog"
        aria-modal="true"
        aria-label={`Attach data source to node ${nodeId}`}
        onClick={(event) => event.stopPropagation()}
      >
        <div className="planner-attach-popover__header">
          <strong>
            <Plug size={12} aria-hidden /> Attach data source
          </strong>
          <button
            type="button"
            className="planner-attach-popover__close"
            onClick={onClose}
            aria-label="Close attach popover"
          >
            <X size={13} aria-hidden />
          </button>
        </div>

        {loading ? (
          <p className="planner-attach-popover__muted">Loading your connectors…</p>
        ) : (
          <>
            {loadError && (
              <p className="planner-attach-popover__warn">
                Connector hub unavailable ({loadError}). Showing reference
                connectors only.
              </p>
            )}
            <label className="planner-attach-popover__field">
              <span>Connector</span>
              <select
                value={selectedSlug}
                disabled={submitting}
                onChange={(event) => setSelectedSlug(event.target.value)}
              >
                {connectors.map((row) => (
                  <option key={row.id} value={row.slug}>
                    {row.label}
                  </option>
                ))}
              </select>
            </label>
            <label className="planner-attach-popover__field">
              <span>Ref</span>
              <input
                ref={refInputRef}
                value={refValue}
                disabled={submitting}
                onChange={(event) => setRefValue(event.target.value)}
                placeholder="e.g. acme/repo, doc-id, page-id"
              />
            </label>
            {submitError && (
              <p className="planner-attach-popover__error">{submitError}</p>
            )}
            <div className="planner-attach-popover__actions">
              <button
                type="button"
                onClick={onClose}
                disabled={submitting}
              >
                Cancel
              </button>
              <button
                type="button"
                className="primary"
                onClick={handleSubmit}
                disabled={submitting || !selectedSlug || refValue.trim().length === 0}
              >
                {submitting ? 'Attaching…' : 'Attach'}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  )
}

/** Echo / reference connector — what INT-1 currently exposes. */
const ECHO_REFERENCE_FALLBACK: ConnectorRow[] = [
  { id: 'echo-reference', label: 'Echo (reference)', slug: 'echo' },
]

/**
 * Wrap the connectors fetch so a 404 (INT-1 not yet deployed) or non-JSON
 * response does not break the popover. INT-2 will replace this with a typed
 * helper exported from `../../api`.
 */
async function fetchConnectorsSafe(): Promise<ConnectorRow[]> {
  try {
    const response = await fetch('/api/v1/connect/connectors', {
      headers: { Accept: 'application/json' },
    })
    if (!response.ok) return []
    const body = (await response.json()) as { connectors?: Array<{
      id?: string
      slug?: string
      label?: string
      name?: string
      title?: string
    }> }
    const rows = Array.isArray(body?.connectors) ? body.connectors : []
    return rows
      .map((row, index): ConnectorRow | null => {
        const slug = String(row.slug ?? row.id ?? '').trim()
        if (!slug) return null
        const label = String(row.label ?? row.name ?? row.title ?? slug).trim()
        return {
          id: String(row.id ?? `${slug}-${index}`),
          label,
          slug,
        }
      })
      .filter((row): row is ConnectorRow => Boolean(row))
  } catch {
    return []
  }
}

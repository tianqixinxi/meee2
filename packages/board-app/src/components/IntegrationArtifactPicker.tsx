import { ArrowLeft, GitPullRequest, Loader2, MessageSquareText } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import {
  attachPlannerArtifactToNode,
  fetchGithubIssues,
  fetchGithubPulls,
  fetchGithubRepos,
  fetchLarkDocs,
} from '../api'
import type { ExternalItem, ExternalItemsResult, PlannerArtifactKind } from '../types'

/**
 * Phase 5 — Integration artifact picker.
 *
 * Lets the user browse GitHub / Lark external items and, when a target
 * planner node is supplied, add the selected item as node output evidence.
 *
 * The output addition goes through the EXISTING endpoint
 * (`attachPlannerArtifactToNode`) — this component builds no parallel attach
 * path. Adding output is always an explicit user action: nothing is inferred.
 */

interface AttachTarget {
  canvasId: string
  nodeId: string
  nodeTitle: string
}

interface Props {
  /** Which provider to browse. */
  provider: 'github' | 'lark'
  /**
   * When set, each item gets an "Add output" action that calls the existing
   * artifact endpoint. When omitted the picker is browse-only.
   */
  attachTarget?: AttachTarget
  /** Called after a successful attach (e.g. to refresh graph state). */
  onAttached?: (reference: string, kind: PlannerArtifactKind) => void
  /** Called when the user dismisses the picker. */
  onClose?: () => void
}

type GithubLevel =
  | { kind: 'repos' }
  | { kind: 'repo'; owner: string; repo: string; tab: 'pulls' | 'issues' }

const ARTIFACT_KIND_LABEL: Record<PlannerArtifactKind, string> = {
  'idea-draft': 'idea draft',
  prd: 'PRD',
  'impl-pr': 'implementation PR',
  'prerelease-verdict': 'prerelease verdict',
  'main-merge': 'merged to main',
  'lark-doc': 'Lark doc',
  'check-result': 'CI check result',
  generic: 'generic',
}

const ARTIFACT_KIND_ORDER: PlannerArtifactKind[] = [
  'impl-pr',
  'main-merge',
  'check-result',
  'idea-draft',
  'prd',
  'lark-doc',
  'prerelease-verdict',
  'generic',
]

export function IntegrationArtifactPicker({ provider, attachTarget, onAttached, onClose }: Props) {
  const [level, setLevel] = useState<GithubLevel>({ kind: 'repos' })
  const [result, setResult] = useState<ExternalItemsResult | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [attachingId, setAttachingId] = useState<string | null>(null)

  const load = useCallback(() => {
    setLoading(true)
    setError(null)
    let request: Promise<ExternalItemsResult>
    if (provider === 'lark') {
      request = fetchLarkDocs()
    } else if (level.kind === 'repos') {
      request = fetchGithubRepos()
    } else if (level.tab === 'pulls') {
      request = fetchGithubPulls(level.owner, level.repo)
    } else {
      request = fetchGithubIssues(level.owner, level.repo)
    }
    request
      .then((res) => setResult(res))
      .catch((err: unknown) => {
        setResult(null)
        setError(err instanceof Error ? err.message : 'Failed to load items')
      })
      .finally(() => setLoading(false))
  }, [provider, level])

  useEffect(() => {
    load()
  }, [load])

  const handleAttach = useCallback(
    (item: ExternalItem, kind: PlannerArtifactKind) => {
      if (!attachTarget) return
      setAttachingId(item.id)
      setError(null)
      attachPlannerArtifactToNode(attachTarget.canvasId, attachTarget.nodeId, {
        kind,
        title: item.title,
        reference: item.reference,
        status: 'attached',
      })
        .then(() => onAttached?.(item.reference, kind))
        .catch((err: unknown) => {
          setError(err instanceof Error ? err.message : 'Add output failed')
        })
        .finally(() => setAttachingId(null))
    },
    [attachTarget, onAttached],
  )

  const Icon = provider === 'github' ? GitPullRequest : MessageSquareText

  return (
    <div className="integration-picker">
      <div className="integration-picker__bar">
        {provider === 'github' && level.kind === 'repo' ? (
          <button
            type="button"
            className="integration-picker__back"
            onClick={() => setLevel({ kind: 'repos' })}
          >
            <ArrowLeft size={13} aria-hidden /> Repos
          </button>
        ) : (
          <span className="integration-picker__title">
            <Icon size={14} aria-hidden />
            {provider === 'github' ? 'GitHub' : 'Lark'}
          </span>
        )}
        <div className="integration-picker__bar-actions">
          {provider === 'github' && level.kind === 'repo' && (
            <div className="integration-picker__tabs">
              <button
                type="button"
                className={level.tab === 'pulls' ? 'is-active' : ''}
                onClick={() => setLevel({ ...level, tab: 'pulls' })}
              >
                Pull requests
              </button>
              <button
                type="button"
                className={level.tab === 'issues' ? 'is-active' : ''}
                onClick={() => setLevel({ ...level, tab: 'issues' })}
              >
                Issues
              </button>
            </div>
          )}
          {onClose && (
            <button type="button" className="integration-picker__close" onClick={onClose}>
              Done
            </button>
          )}
        </div>
      </div>

      {provider === 'github' && level.kind === 'repo' && (
        <p className="integration-picker__crumb">
          {level.owner}/{level.repo}
        </p>
      )}

      {error && <p className="integration-picker__error">{error}</p>}
      {result?.notice && <p className="integration-picker__notice">{result.notice}</p>}

      {loading ? (
        <p className="integration-picker__empty">
          <Loader2 size={13} className="spin" aria-hidden /> Loading…
        </p>
      ) : !result || result.items.length === 0 ? (
        <p className="integration-picker__empty">
          {error ? 'Could not load items.' : 'No items to show.'}
        </p>
      ) : (
        <ul className="integration-picker__list">
          {result.items.map((item) => (
            <li key={item.id} className="integration-picker__item">
              <div className="integration-picker__item-main">
                <strong>{item.title}</strong>
                {item.subtitle && <em>{item.subtitle}</em>}
                <code>{item.reference}</code>
              </div>
              <div className="integration-picker__item-actions">
                {provider === 'github' && level.kind === 'repos' ? (
                  <button
                    type="button"
                    onClick={() => {
                      const [owner, repo] = item.id.split('/')
                      if (owner && repo) {
                        setLevel({ kind: 'repo', owner, repo, tab: 'pulls' })
                      }
                    }}
                  >
                    Browse
                  </button>
                ) : attachTarget ? (
                  <AttachControl
                    item={item}
                    busy={attachingId === item.id}
                    nodeTitle={attachTarget.nodeTitle}
                    onAttach={handleAttach}
                  />
                ) : (
                  <a href={item.reference} target="_blank" rel="noreferrer">
                    Open
                  </a>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

/**
 * Per-item output control — lets the user confirm (or override) the output
 * kind before adding it through the existing endpoint.
 */
function AttachControl({
  item,
  busy,
  nodeTitle,
  onAttach,
}: {
  item: ExternalItem
  busy: boolean
  nodeTitle: string
  onAttach: (item: ExternalItem, kind: PlannerArtifactKind) => void
}) {
  const [kind, setKind] = useState<PlannerArtifactKind>(item.suggestedArtifactKind)
  return (
    <div className="integration-picker__attach">
      <select
        value={kind}
        onChange={(event) => setKind(event.target.value as PlannerArtifactKind)}
        aria-label="Artifact kind"
        disabled={busy}
      >
        {ARTIFACT_KIND_ORDER.map((value) => (
          <option key={value} value={value}>
            {ARTIFACT_KIND_LABEL[value]}
          </option>
        ))}
      </select>
      <button
        type="button"
        onClick={() => onAttach(item, kind)}
        disabled={busy}
        title={`Add output to ${nodeTitle}`}
      >
        {busy ? 'Adding…' : 'Add output'}
      </button>
    </div>
  )
}

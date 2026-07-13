import { CheckCircle2, ExternalLink, FileText, Loader2, RotateCw, X, XCircle } from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { getArtifactVersionContent, getPlannerArtifactContent, listArtifactVersions } from '../../api'
import type { ArtifactIndexItem } from '../../lib/artifactIndex'
import { resolvedArtifactPayload } from '../../lib/artifactPayload'
import { useI18n } from '../../lib/i18n'
import type {
  ArtifactReviewStatus,
  PlannerArtifact,
  PlannerArtifactContent,
  PlannerArtifactVersion,
} from '../../types'
import { ArtifactViewTabs } from './ArtifactViewTabs'

interface ArtifactPreviewDialogProps {
  item: ArtifactIndexItem
  activeCanvasId: string
  reviewActionKey: string | null
  onClose: () => void
  onOpenCanvas: (canvasId: string) => void
  onOpenSource: (item: ArtifactIndexItem) => void
  onOpenExternal: (item: ArtifactIndexItem) => boolean
  onReviewArtifact: (item: ArtifactIndexItem, status: ArtifactReviewStatus) => void
}

export function ArtifactPreviewDialog({
  item,
  activeCanvasId,
  reviewActionKey,
  onClose,
  onOpenCanvas,
  onOpenSource,
  onOpenExternal,
  onReviewArtifact,
}: ArtifactPreviewDialogProps) {
  const { t } = useI18n()
  const [content, setContent] = useState<PlannerArtifactContent | null>(null)
  const [contentLoading, setContentLoading] = useState(false)
  const [contentError, setContentError] = useState<string | null>(null)
  const [contentAttempt, setContentAttempt] = useState(0)
  const [versions, setVersions] = useState<PlannerArtifactVersion[] | null>(null)
  const [versionsLoading, setVersionsLoading] = useState(true)
  const [versionContent, setVersionContent] = useState<PlannerArtifactContent | null>(null)
  const [versionContentLoading, setVersionContentLoading] = useState(false)
  const [versionContentError, setVersionContentError] = useState<string | null>(null)
  const [versionContentAttempt, setVersionContentAttempt] = useState(0)
  const [selectedVersionId, setSelectedVersionId] = useState<string>('latest')

  const needsRemoteContent = (
    !resolvedArtifactPayload(item.latest) && item.latest.payload == null
  ) || Boolean(item.latest.views?.some((view) => view.sourcePath))

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [onClose])

  useEffect(() => {
    let cancelled = false
    setContent(null)
    setContentError(null)
    if (!needsRemoteContent) {
      setContentLoading(false)
      return () => { cancelled = true }
    }
    setContentLoading(true)
    getPlannerArtifactContent(item.canvas.id, item.latest.id)
      .then((next) => {
        if (!cancelled) setContent(next)
      })
      .catch((error) => {
        if (!cancelled) setContentError((error as Error).message || t('artifacts.previewLoadFailed'))
      })
      .finally(() => {
        if (!cancelled) setContentLoading(false)
      })
    return () => { cancelled = true }
  }, [contentAttempt, item.canvas.id, item.latest.id, needsRemoteContent, t])

  useEffect(() => {
    let cancelled = false
    setVersions(null)
    setVersionsLoading(true)
    setSelectedVersionId('latest')
    setVersionContent(null)
    setVersionContentError(null)
    listArtifactVersions(item.canvas.id, item.latest.nodeId, item.latest.reference)
      .then(({ versions: next }) => {
        if (!cancelled) setVersions(next)
      })
      .catch(() => {
        if (!cancelled) setVersions([])
      })
      .finally(() => {
        if (!cancelled) setVersionsLoading(false)
      })
    return () => { cancelled = true }
  }, [item.canvas.id, item.latest.nodeId, item.latest.reference])

  const selectedVersion = selectedVersionId === 'latest'
    ? null
    : versions?.find((version) => version.version_id === selectedVersionId) ?? null
  const previewArtifact = useMemo(
    () => selectedVersion ? artifactFromVersion(item.latest, selectedVersion) : item.latest,
    [item.latest, selectedVersion],
  )
  const selectedVersionNeedsRemoteContent = Boolean(
    selectedVersion?.payload_inline
      && typeof selectedVersion.payload_inline === 'object'
      && !Array.isArray(selectedVersion.payload_inline)
      && (selectedVersion.payload_inline as Record<string, unknown>).blobRef,
  )
  const previewContent = selectedVersion ? versionContent : content
  const previewLoading = selectedVersion
    ? selectedVersionNeedsRemoteContent && (versionContentLoading || (!versionContent && !versionContentError))
    : contentLoading
  const previewError = selectedVersion ? versionContentError : contentError
  const hasInlinePreview = Boolean(
    resolvedArtifactPayload(previewArtifact, previewContent ?? undefined)
      || previewArtifact.payload != null
      || previewContent?.content
      || previewContent?.payload != null
      || previewContent?.type === 'file',
  )

  useEffect(() => {
    let cancelled = false
    setVersionContent(null)
    setVersionContentError(null)
    if (!selectedVersion || !selectedVersionNeedsRemoteContent) {
      setVersionContentLoading(false)
      return () => { cancelled = true }
    }
    setVersionContentLoading(true)
    getArtifactVersionContent(item.canvas.id, selectedVersion.version_id)
      .then((next) => {
        if (!cancelled) setVersionContent(next)
      })
      .catch((error) => {
        if (!cancelled) setVersionContentError((error as Error).message || t('artifacts.previewLoadFailed'))
      })
      .finally(() => {
        if (!cancelled) setVersionContentLoading(false)
      })
    return () => { cancelled = true }
  }, [item.canvas.id, selectedVersion, selectedVersionNeedsRemoteContent, t, versionContentAttempt])

  return (
    <div className="artifact-preview-dialog__backdrop" role="presentation" onClick={onClose}>
      <section
        className="artifact-preview-dialog"
        role="dialog"
        aria-modal="true"
        aria-label={t('artifacts.contentModalTitle')}
        onClick={(event) => event.stopPropagation()}
      >
        <header className="artifact-preview-dialog__header">
          <div className="artifact-preview-dialog__identity">
            <span>{item.typeLabel}</span>
            <h2>{item.latest.title}</h2>
            <p>{item.latest.reference}</p>
          </div>
          <div className="artifact-preview-dialog__header-actions">
            <span className={`artifacts-state-badge is-${item.displayState}`}>
              {previewStateLabel(item.displayState, t)}
            </span>
            <button type="button" aria-label={t('common.close')} onClick={onClose}>
              <X size={16} aria-hidden />
            </button>
          </div>
        </header>

        <div className="artifact-preview-dialog__toolbar">
          <dl>
            <div><dt>{t('artifacts.tableCanvas')}</dt><dd>{item.canvas.name || item.canvas.id}</dd></div>
            <div><dt>{t('artifacts.node')}</dt><dd>{item.node?.title ?? item.latest.nodeId}</dd></div>
            <div><dt>{t('artifacts.latest')}</dt><dd>{formatDate(item.latest.createdAt)}</dd></div>
          </dl>
          <label>
            <span>{t('artifacts.version')}</span>
            <select
              value={selectedVersionId}
              disabled={versionsLoading}
              onChange={(event) => setSelectedVersionId(event.target.value)}
            >
              <option value="latest">{versionsLoading ? t('artifacts.loadingVersions') : t('artifacts.latest')}</option>
              {(versions ?? []).slice(1).map((version) => (
                <option key={version.version_id} value={version.version_id}>
                  {formatDate(version.created_at)} · {version.submitted_by ?? version.submitted_by_kind}
                </option>
              ))}
            </select>
          </label>
        </div>

        <main className="artifact-preview-dialog__canvas">
          {previewLoading ? (
            <div className="artifact-preview-dialog__state" role="status">
              <Loader2 size={18} className="spin" aria-hidden />
              <span>{t('artifacts.loadingLatest')}</span>
            </div>
          ) : previewError && !hasInlinePreview ? (
            <div className="artifact-preview-dialog__state" role="alert">
              <strong>{t('artifacts.previewLoadFailed')}</strong>
              <p>{previewError}</p>
              <button type="button" onClick={() => selectedVersion
                ? setVersionContentAttempt((value) => value + 1)
                : setContentAttempt((value) => value + 1)}>
                <RotateCw size={14} aria-hidden />
                <span>{t('common.retry')}</span>
              </button>
            </div>
          ) : hasInlinePreview ? (
            <ArtifactPreviewCanvas artifact={previewArtifact} content={previewContent} />
          ) : (
            <div className="artifact-preview-dialog__state">
              <strong>{t('artifacts.unsupportedPreview')}</strong>
              <p>{t('artifacts.unsupportedPreviewHint')}</p>
              <button type="button" onClick={() => onOpenExternal(item) || onOpenSource(item)}>
                <ExternalLink size={14} aria-hidden />
                <span>{t('artifacts.openExternally')}</span>
              </button>
            </div>
          )}
        </main>

        <footer className="artifact-preview-dialog__footer">
          <div>
            {item.displayState === 'needs-review' && (
              <>
                <button
                  type="button"
                  className="primary"
                  disabled={Boolean(reviewActionKey)}
                  onClick={() => onReviewArtifact(item, 'approved')}
                >
                  <CheckCircle2 size={14} aria-hidden />
                  <span>{reviewActionKey ? t('artifacts.reviewSubmitting') : t('artifacts.approve')}</span>
                </button>
                <button
                  type="button"
                  className="danger"
                  disabled={Boolean(reviewActionKey)}
                  onClick={() => onReviewArtifact(item, 'rejected')}
                >
                  <XCircle size={14} aria-hidden />
                  <span>{reviewActionKey ? t('artifacts.reviewSubmitting') : t('artifacts.reject')}</span>
                </button>
              </>
            )}
          </div>
          <div>
            <button type="button" onClick={() => onOpenSource(item)}>
              <ExternalLink size={14} aria-hidden />
              <span>{t('artifacts.revealSource')}</span>
            </button>
            <button type="button" onClick={() => onOpenCanvas(item.canvas.id)}>
              <FileText size={14} aria-hidden />
              <span>{item.canvas.id === activeCanvasId ? t('artifacts.currentCanvas') : t('artifacts.openCanvasButton')}</span>
            </button>
          </div>
        </footer>
      </section>
    </div>
  )
}

function ArtifactPreviewCanvas({
  artifact,
  content,
}: {
  artifact: PlannerArtifact
  content: PlannerArtifactContent | null
}) {
  const { t } = useI18n()
  if (content?.type === 'html' && !artifact.views?.length) {
    return <iframe className="artifact-preview-dialog__html" title={artifact.title} sandbox="" srcDoc={content.content ?? ''} />
  }
  if (content?.type === 'file' && !resolvedArtifactPayload(artifact, content)) {
    return (
      <dl className="artifact-preview-dialog__file">
        <div><dt>{t('artifacts.filename')}</dt><dd>{content.filename ?? t('artifacts.fileArtifact')}</dd></div>
        <div><dt>{t('artifacts.mimeType')}</dt><dd>{content.mimeType || 'application/octet-stream'}</dd></div>
        <div><dt>{t('artifacts.size')}</dt><dd>{formatBytes(content.size, t('artifacts.notRecorded'))}</dd></div>
        <div><dt>SHA-256</dt><dd>{content.sha256 ?? t('artifacts.notRecorded')}</dd></div>
      </dl>
    )
  }
  return <ArtifactViewTabs artifact={artifact} content={content} emptyLabel={t('artifacts.noPreview')} />
}

function artifactFromVersion(latest: PlannerArtifact, version: PlannerArtifactVersion): PlannerArtifact {
  return {
    ...latest,
    id: version.artifact_id,
    createdAt: version.created_at,
    payload: version.payload_inline,
    typedPayload: undefined,
  }
}

function formatDate(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
}

function formatBytes(value: number | null | undefined, fallback: string): string {
  if (value == null) return fallback
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  return `${(value / (1024 * 1024)).toFixed(1)} MB`
}

function previewStateLabel(
  state: ArtifactIndexItem['displayState'],
  t: ReturnType<typeof useI18n>['t'],
): string {
  switch (state) {
    case 'ready': return t('artifacts.stateReady')
    case 'needs-review': return t('artifacts.stateNeedsReview')
    case 'rejected': return t('artifacts.stateRejected')
    case 'failed': return t('artifacts.stateFailed')
    case 'stale': return t('artifacts.stateStale')
    case 'working': return t('artifacts.stateWorking')
    case 'other': return t('artifacts.stateOther')
  }
}

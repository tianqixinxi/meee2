import {
  ArrowLeft,
  FileCode2,
  Gamepad2,
  GitPullRequest,
  Globe2,
  LockKeyhole,
  Moon,
  Plus,
  Rocket,
  Search,
  Sparkles,
  Users,
  Upload,
  Wrench,
  RefreshCw,
  type LucideIcon,
} from 'lucide-react'
import { type ChangeEvent, useEffect, useMemo, useState } from 'react'
import type { BoardState, CanvasInfo, CanvasScope } from '../types'
import {
  fetchCanvasTemplates,
  fetchClaudeWorkflows,
  fetchTeamMembers,
  type ClaudeWorkflow,
  type ClaudeWorkflowList,
  type CanvasTemplate,
  type UserProfile,
} from '../api'
import { useI18n } from '../lib/i18n'
import { PlannerGraph } from './planner/PlannerGraph'

interface OwnerIdentity {
  name: string
  avatarUrl: string | null
  initials: string
}

interface TemplatesViewProps {
  canvases: CanvasInfo[]
  activeCanvasId: string
  userProfile: UserProfile | null
  boardState: BoardState | null
  onOpenCanvas: (canvasId: string) => void
  onCreateTemplate: (name: string, scope: CanvasScope) => Promise<string>
  /**
   * Chunk F · Official templates gallery. Applies a builtin `CanvasTemplate`
   * — backend creates a fresh canvas (with the template's `kind`) and seeds
   * its default nodes. Caller is expected to switch to the new canvas.
   */
  onApplyTemplate: (templateId: string, name: string, scope: CanvasScope) => Promise<string>
  onImportClaudeWorkflow: (workflowId: string, name: string, scope: CanvasScope) => Promise<string>
  onUploadClaudeWorkflow: (filename: string, source: string, name: string, scope: CanvasScope) => Promise<string>
}

type GalleryCategory = 'engineering' | 'team' | 'demo'

// Whitelisted lucide icons used by the builtin gallery. Falls back to
// `Sparkles` for any unknown name so a future-added template doesn't crash
// the UI while the front-end is still on the old bundle.
const ICONS_BY_NAME: Record<string, LucideIcon> = {
  'git-pull-request': GitPullRequest,
  rocket: Rocket,
  moon: Moon,
  users: Users,
  tool: Wrench,
  'gamepad-2': Gamepad2,
}

const CATEGORY_ORDER: GalleryCategory[] = ['engineering', 'team', 'demo']
const CLAUDE_WORKFLOW_MAX_BYTES = 256 * 1024

type WorkflowImportTarget =
  | { kind: 'library'; id: string; name: string; commandName: string; path: string }
  | { kind: 'upload'; filename: string; source: string; name: string; commandName: string; path: string }

const CATEGORY_I18N_KEY: Record<GalleryCategory, 'templates.gallery.category.engineering' | 'templates.gallery.category.team' | 'templates.gallery.category.demo'> = {
  engineering: 'templates.gallery.category.engineering',
  team: 'templates.gallery.category.team',
  demo: 'templates.gallery.category.demo',
}

export function TemplatesView({
  canvases,
  activeCanvasId,
  userProfile,
  boardState,
  onOpenCanvas,
  onCreateTemplate,
  onApplyTemplate,
  onImportClaudeWorkflow,
  onUploadClaudeWorkflow,
}: TemplatesViewProps) {
  const { t } = useI18n()
  const [selectedTemplateId, setSelectedTemplateId] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [creating, setCreating] = useState(false)
  const [nameDraft, setNameDraft] = useState('')
  const [scopeDraft, setScopeDraft] = useState<CanvasScope>('personal')
  const [error, setError] = useState<string | null>(null)
  const [ownersById, setOwnersById] = useState<Record<string, OwnerIdentity>>({})

  // Gallery (builtin templates from /api/templates).
  const [galleryTemplates, setGalleryTemplates] = useState<CanvasTemplate[]>([])
  const [galleryError, setGalleryError] = useState<string | null>(null)
  const [activeCategory, setActiveCategory] = useState<GalleryCategory>('engineering')
  const [applyTarget, setApplyTarget] = useState<CanvasTemplate | null>(null)
  const [applyNameDraft, setApplyNameDraft] = useState('')
  const [applyScopeDraft, setApplyScopeDraft] = useState<CanvasScope>('personal')
  const [applyError, setApplyError] = useState<string | null>(null)
  const [applying, setApplying] = useState(false)
  const [workflowList, setWorkflowList] = useState<ClaudeWorkflowList | null>(null)
  const [workflowError, setWorkflowError] = useState<string | null>(null)
  const [workflowsLoading, setWorkflowsLoading] = useState(false)
  const [workflowImportTarget, setWorkflowImportTarget] = useState<WorkflowImportTarget | null>(null)
  const [workflowNameDraft, setWorkflowNameDraft] = useState('')
  const [workflowScopeDraft, setWorkflowScopeDraft] = useState<CanvasScope>('personal')
  const [workflowImportError, setWorkflowImportError] = useState<string | null>(null)
  const [workflowImporting, setWorkflowImporting] = useState(false)
  const [workflowUploadError, setWorkflowUploadError] = useState<string | null>(null)

  // epsilon (session-hide): `nodeKind === 'session'` is deprecated as a
  // user-creatable surface — new work seeds `step` nodes with
  // `dispatch.runner = 'claude'` instead. The templates listing here
  // operates at canvas granularity (it only renders canvas names; node
  // kinds aren't materialized in this view), so there's nothing to
  // filter at the canvas-row level. Any session-kind nodes that exist
  // inside legacy template canvases are still readable when the user
  // opens the template into PlannerGraph below (decode/updateNode keep
  // legacy compat). New template authoring should avoid session-kind.
  const templates = useMemo(
    () => canvases.filter((canvas) => canvas.kind === 'template'),
    [canvases],
  )
  const selectedTemplate = selectedTemplateId
    ? templates.find((template) => template.id === selectedTemplateId) ?? null
    : null
  const filteredTemplates = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase()
    if (!normalizedQuery) return templates
    return templates.filter((template) => [
      template.name,
      template.id,
      template.ownerUserId ?? '',
      ownerIdentity(template, userProfile, ownersById).name,
      visibilityLabel(template, t),
      template.scope === 'team' ? 'public' : 'private',
    ].some((value) => value.toLowerCase().includes(normalizedQuery)))
  }, [ownersById, query, t, templates, userProfile])

  useEffect(() => {
    let cancelled = false
    fetchTeamMembers()
      .then(({ members }) => {
        if (cancelled) return
        setOwnersById(Object.fromEntries(
          members
            .filter((member) => member.userId)
            .map((member) => {
              const name = member.displayName || member.userId
              return [member.userId, {
                name,
                avatarUrl: member.avatarUrl ?? null,
                initials: initialsFor(name),
              }]
            }),
        ))
      })
      .catch(() => {
        if (!cancelled) setOwnersById({})
      })
    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    let cancelled = false
    fetchCanvasTemplates()
      .then((entries) => {
        if (cancelled) return
        setGalleryTemplates(entries)
        setGalleryError(null)
      })
      .catch((err) => {
        if (cancelled) return
        setGalleryError((err as Error).message || t('templates.gallery.loadFailed'))
      })
    return () => {
      cancelled = true
    }
  }, [])

  const refreshWorkflows = () => {
    setWorkflowsLoading(true)
    setWorkflowError(null)
    fetchClaudeWorkflows()
      .then((result) => {
        setWorkflowList(result)
        setWorkflowError(result.error ?? null)
      })
      .catch((err) => {
        setWorkflowError((err as Error).message || 'Failed to load Claude Code workflows')
      })
      .finally(() => setWorkflowsLoading(false))
  }

  useEffect(() => {
    refreshWorkflows()
  }, [])

  const galleryByCategory = useMemo(() => {
    const buckets: Record<GalleryCategory, CanvasTemplate[]> = {
      engineering: [],
      team: [],
      demo: [],
    }
    for (const tpl of galleryTemplates) {
      const cat = (CATEGORY_ORDER as string[]).includes(tpl.category)
        ? (tpl.category as GalleryCategory)
        : 'demo'
      buckets[cat].push(tpl)
    }
    return buckets
  }, [galleryTemplates])

  const visibleGallery = galleryByCategory[activeCategory]

  const submitCreate = () => {
    const name = nameDraft.trim()
    if (!name) return
    setError(null)
    onCreateTemplate(name, scopeDraft)
      .then((canvasId) => {
        setSelectedTemplateId(canvasId)
        setNameDraft('')
        setScopeDraft('personal')
        setCreating(false)
      })
      .catch((err) => setError((err as Error).message || t('templates.createFailed')))
  }

  const openApplyDialog = (template: CanvasTemplate) => {
    setApplyTarget(template)
    // Default name = template name (user can override).
    setApplyNameDraft(template.name)
    setApplyScopeDraft('personal')
    setApplyError(null)
  }

  const closeApplyDialog = () => {
    setApplyTarget(null)
    setApplyNameDraft('')
    setApplyError(null)
    setApplying(false)
  }

  const submitApply = () => {
    if (!applyTarget) return
    const name = applyNameDraft.trim()
    if (!name) {
      setApplyError(t('templates.gallery.canvasNameRequired'))
      return
    }
    setApplying(true)
    setApplyError(null)
    onApplyTemplate(applyTarget.id, name, applyScopeDraft)
      .then(() => {
        closeApplyDialog()
      })
      .catch((err) => {
        setApplyError((err as Error).message || t('templates.gallery.applyFailed'))
        setApplying(false)
      })
  }

  const openWorkflowImportDialog = (workflow: ClaudeWorkflow) => {
    setWorkflowImportTarget({
      kind: 'library',
      id: workflow.id,
      name: workflow.name,
      commandName: workflow.commandName,
      path: workflow.path,
    })
    setWorkflowNameDraft(workflow.name)
    setWorkflowScopeDraft('personal')
    setWorkflowImportError(null)
  }

  const handleWorkflowUploadSelected = (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.currentTarget.files?.[0] ?? null
    event.currentTarget.value = ''
    if (!file) return
    if (!file.name.toLowerCase().endsWith('.js')) {
      setWorkflowUploadError('Choose a Claude Code workflow .js file.')
      return
    }
    if (file.size > CLAUDE_WORKFLOW_MAX_BYTES) {
      setWorkflowUploadError(`Workflow is too large to import (${formatBytes(file.size)}, max ${formatBytes(CLAUDE_WORKFLOW_MAX_BYTES)}).`)
      return
    }
    file.text()
      .then((source) => {
        const baseName = file.name.replace(/\.js$/i, '') || 'uploaded-workflow'
        setWorkflowImportTarget({
          kind: 'upload',
          filename: file.name,
          source,
          name: baseName,
          commandName: `/${baseName}`,
          path: `uploaded:${file.name}`,
        })
        setWorkflowNameDraft(baseName)
        setWorkflowScopeDraft('personal')
        setWorkflowImportError(null)
        setWorkflowUploadError(null)
      })
      .catch((err) => {
        setWorkflowUploadError((err as Error).message || 'Failed to read workflow file')
      })
  }

  const closeWorkflowImportDialog = () => {
    setWorkflowImportTarget(null)
    setWorkflowNameDraft('')
    setWorkflowImportError(null)
    setWorkflowImporting(false)
  }

  const submitWorkflowImport = () => {
    if (!workflowImportTarget) return
    const name = workflowNameDraft.trim()
    if (!name) {
      setWorkflowImportError(t('templates.gallery.canvasNameRequired'))
      return
    }
    setWorkflowImporting(true)
    setWorkflowImportError(null)
    const request = workflowImportTarget.kind === 'library'
      ? onImportClaudeWorkflow(workflowImportTarget.id, name, workflowScopeDraft)
      : onUploadClaudeWorkflow(workflowImportTarget.filename, workflowImportTarget.source, name, workflowScopeDraft)
    request
      .then(() => closeWorkflowImportDialog())
      .catch((err) => {
        setWorkflowImportError((err as Error).message || 'Failed to import Claude Code workflow')
        setWorkflowImporting(false)
      })
  }

  if (selectedTemplate) {
    const selectedVisibilityLabel = visibilityLabel(selectedTemplate, t)
    return (
      <section className="templates-workspace templates-workspace--editor" aria-label={t('templates.editorKicker')}>
        <div className="templates-editor-bar">
          <button
            type="button"
            className="templates-editor-bar__back"
            onClick={() => setSelectedTemplateId(null)}
          >
            <ArrowLeft size={15} aria-hidden />
            {t('templates.kicker')}
          </button>
          <div className="templates-editor-bar__title">
            <span>{t('templates.editorKicker')}</span>
            <strong>{displayCanvasName(selectedTemplate)}</strong>
          </div>
          <span className={`templates-visibility templates-visibility--${visibilityTone(selectedTemplate)}`}>
            {selectedTemplate.scope === 'team' ? <Globe2 size={11} aria-hidden /> : <LockKeyhole size={11} aria-hidden />}
            {selectedVisibilityLabel}
          </span>
        </div>
        <PlannerGraph
          canvasId={selectedTemplate.id}
          canvasName={displayCanvasName(selectedTemplate)}
          variant="template"
          userProfile={userProfile}
          boardState={boardState}
          onOpenSubCanvas={onOpenCanvas}
        />
      </section>
    )
  }

  return (
    <section className="templates-workspace" aria-label={t('templates.kicker')}>
      <div className="templates-workspace__inner">
        <header className="templates-workspace__header">
          <div>
            <span>{t('templates.kicker')}</span>
            <h1>{t('templates.title')}</h1>
          </div>
          <div className="templates-workspace__tools">
            <label className="templates-search">
              <Search size={14} aria-hidden />
              <input
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder={t('templates.searchPlaceholder')}
              />
            </label>
            <button
              type="button"
              className="primary templates-new-button"
              onClick={() => {
                setError(null)
                setScopeDraft('personal')
                setCreating(true)
              }}
            >
              <Plus size={14} aria-hidden />
              {t('templates.new')}
            </button>
          </div>
        </header>

        {/* Builtin gallery — Chunk F */}
        <section className="template-gallery" aria-label={t('templates.gallery.officialAriaLabel')}>
          <div className="template-gallery__header">
            <h2 className="template-gallery__title">{t('templates.gallery.title')}</h2>
            <div className="template-gallery__tabs" role="tablist">
              {CATEGORY_ORDER.map((cat) => {
                const count = galleryByCategory[cat].length
                const isActive = cat === activeCategory
                return (
                  <button
                    key={cat}
                    type="button"
                    role="tab"
                    aria-selected={isActive}
                    className={`template-gallery__tab${isActive ? ' is-active' : ''}`}
                    onClick={() => setActiveCategory(cat)}
                  >
                    {t(CATEGORY_I18N_KEY[cat])}
                    <span className="template-gallery__tab-count">{count}</span>
                  </button>
                )
              })}
            </div>
          </div>

          {galleryError ? (
            <div className="inline-error template-gallery__error">{galleryError}</div>
          ) : visibleGallery.length === 0 ? (
            <div className="template-gallery__empty">
              {galleryTemplates.length === 0 ? t('templates.gallery.loading') : t('templates.gallery.emptyCategory')}
            </div>
          ) : (
            <div className="template-gallery__grid">
              {visibleGallery.map((tpl) => (
                <GalleryCard key={tpl.id} template={tpl} onUse={() => openApplyDialog(tpl)} t={t} />
              ))}
            </div>
          )}
        </section>

        <section className="claude-workflows" aria-label="Claude Code workflows">
          <div className="template-gallery__header">
            <div>
              <h2 className="template-gallery__title">Claude Code workflows</h2>
              <p className="claude-workflows__root">{workflowList?.root ?? '~/.claude/workflows'}</p>
            </div>
            <div className="claude-workflows__actions">
              <label className="ghost claude-workflows__refresh claude-workflows__upload">
                <Upload size={13} aria-hidden />
                Upload .js
                <input
                  type="file"
                  accept=".js,text/javascript,application/javascript"
                  className="claude-workflows__file-input"
                  onClick={() => setWorkflowUploadError(null)}
                  onChange={handleWorkflowUploadSelected}
                />
              </label>
              <button type="button" className="ghost claude-workflows__refresh" onClick={refreshWorkflows} disabled={workflowsLoading}>
                <RefreshCw size={13} aria-hidden />
                {workflowsLoading ? 'Scanning…' : 'Refresh'}
              </button>
            </div>
          </div>
          {workflowUploadError ? (
            <div className="inline-error template-gallery__error">{workflowUploadError}</div>
          ) : workflowError ? (
            <div className="inline-error template-gallery__error">{workflowError}</div>
          ) : !workflowList || workflowsLoading ? (
            <div className="template-gallery__empty">Scanning global Claude Code workflows…</div>
          ) : workflowList.workflows.length === 0 ? (
            <div className="template-gallery__empty">No global <code>*.js</code> workflows found.</div>
          ) : (
            <div className="claude-workflows__list">
              {workflowList.workflows.map((workflow) => (
                <WorkflowRow
                  key={workflow.id}
                  workflow={workflow}
                  onImport={() => openWorkflowImportDialog(workflow)}
                />
              ))}
            </div>
          )}
        </section>

        {error && <div className="inline-error templates-error">{error}</div>}

        {filteredTemplates.length > 0 && (
          <section className="template-gallery__custom" aria-label={t('templates.gallery.customSection')}>
            <h2 className="template-gallery__title">{t('templates.gallery.customSection')}</h2>
            <div className="templates-list">
              {filteredTemplates.map((template) => {
                const isActive = template.id === activeCanvasId
                const owner = ownerIdentity(template, userProfile, ownersById)
                return (
                  <button
                    key={template.id}
                    type="button"
                    className={`template-row${isActive ? ' is-active' : ''}`}
                    onClick={() => {
                      onOpenCanvas(template.id)
                      setSelectedTemplateId(template.id)
                    }}
                  >
                    <div className="template-row__main">
                      <strong>{displayCanvasName(template)}</strong>
                    </div>
                    <div className="template-row__side">
                      <span
                        className="template-row__owner"
                        title={t('templates.owner', { name: owner.name })}
                        aria-label={t('templates.owner', { name: owner.name })}
                      >
                        <span className={`template-row__owner-avatar${owner.avatarUrl ? ' has-image' : ''}`}>
                          {owner.avatarUrl ? <img src={owner.avatarUrl} alt="" /> : owner.initials}
                        </span>
                        <span className="template-row__owner-name">{owner.name}</span>
                      </span>
                      <span className={`templates-visibility templates-visibility--${visibilityTone(template)}`}>
                        {template.scope === 'team' ? <Globe2 size={11} aria-hidden /> : <LockKeyhole size={11} aria-hidden />}
                        {visibilityLabel(template, t)}
                      </span>
                    </div>
                  </button>
                )
              })}
            </div>
          </section>
        )}

        {filteredTemplates.length === 0 && query.trim() && (
          <div className="templates-empty">{t('templates.noMatch')}</div>
        )}
      </div>

      {creating && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setCreating(false)
          }}
        >
          <div className="modal canvas-confirm-modal" role="dialog" aria-modal="true" aria-label={t('templates.new')}>
            <div className="modal-header">
              <div className="modal-title">{t('templates.new')}</div>
              <div className="modal-subtitle">{t('templates.newSubtitle')}</div>
            </div>
            <div className="modal-body col" style={{ gap: 10 }}>
              <input
                value={nameDraft}
                onChange={(event) => setNameDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') submitCreate()
                  if (event.key === 'Escape') setCreating(false)
                }}
                placeholder={t('templates.namePlaceholder')}
                autoFocus
              />
              <div className="canvas-toolbar__scope-toggle" role="group" aria-label={t('templates.visibility')}>
                {(['personal', 'team'] as CanvasScope[]).map((scope) => (
                  <button
                    key={scope}
                    type="button"
                    className={scopeDraft === scope ? 'is-selected' : ''}
                    aria-pressed={scopeDraft === scope}
                    onClick={() => setScopeDraft(scope)}
                  >
                    {scope === 'team' ? t('templates.public') : t('templates.private')}
                  </button>
                ))}
              </div>
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setCreating(false)}>{t('common.cancel')}</button>
              <button
                className="primary"
                type="button"
                onClick={submitCreate}
                disabled={!nameDraft.trim()}
              >
                {t('common.create')}
              </button>
            </div>
          </div>
        </div>
      )}

      {applyTarget && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget && !applying) closeApplyDialog()
          }}
        >
          <div
            className="modal canvas-confirm-modal template-gallery__apply-modal"
            role="dialog"
            aria-modal="true"
            aria-label={t('templates.gallery.useTemplateAria', { name: applyTarget.name })}
          >
            <div className="modal-header">
              <div className="modal-title">{t('templates.gallery.applyTitle', { name: applyTarget.name })}</div>
              <div className="modal-subtitle">
                {t('templates.gallery.applySubtitle', {
                  count: applyTarget.defaultNodes.length,
                  plural: applyTarget.defaultNodes.length === 1 ? '' : 's',
                })}
              </div>
            </div>
            <div className="modal-body col" style={{ gap: 10 }}>
              <input
                value={applyNameDraft}
                onChange={(event) => setApplyNameDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') submitApply()
                  if (event.key === 'Escape' && !applying) closeApplyDialog()
                }}
                placeholder={t('templates.gallery.canvasNamePlaceholder')}
                autoFocus
                disabled={applying}
              />
              <div className="canvas-toolbar__scope-toggle" role="group" aria-label={t('templates.gallery.visibilityAriaLabel')}>
                {(['personal', 'team'] as CanvasScope[]).map((scope) => (
                  <button
                    key={scope}
                    type="button"
                    className={applyScopeDraft === scope ? 'is-selected' : ''}
                    aria-pressed={applyScopeDraft === scope}
                    disabled={applying}
                    onClick={() => setApplyScopeDraft(scope)}
                  >
                    {scope === 'team' ? t('templates.public') : t('templates.private')}
                  </button>
                ))}
              </div>
              {applyError && <div className="inline-error">{applyError}</div>}
            </div>
            <div className="modal-footer">
              <button
                className="ghost"
                type="button"
                onClick={closeApplyDialog}
                disabled={applying}
              >
                {t('common.cancel')}
              </button>
              <button
                className="primary"
                type="button"
                onClick={submitApply}
                disabled={applying || !applyNameDraft.trim()}
              >
                {applying ? t('templates.gallery.creating') : t('templates.gallery.createCanvas')}
              </button>
            </div>
          </div>
        </div>
      )}

      {workflowImportTarget && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget && !workflowImporting) closeWorkflowImportDialog()
          }}
        >
          <div
            className="modal canvas-confirm-modal template-gallery__apply-modal"
            role="dialog"
            aria-modal="true"
            aria-label={`Import ${workflowImportTarget.commandName}`}
          >
            <div className="modal-header">
              <div className="modal-title">Import {workflowImportTarget.commandName}</div>
              <div className="modal-subtitle">
                meee2 will read workflow metadata and phases to create a canvas plan. The script is not executed.
              </div>
            </div>
            <div className="modal-body col" style={{ gap: 10 }}>
              <input
                value={workflowNameDraft}
                onChange={(event) => setWorkflowNameDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') submitWorkflowImport()
                  if (event.key === 'Escape' && !workflowImporting) closeWorkflowImportDialog()
                }}
                placeholder={t('templates.gallery.canvasNamePlaceholder')}
                autoFocus
                disabled={workflowImporting}
              />
              <div className="canvas-toolbar__scope-toggle" role="group" aria-label={t('templates.gallery.visibilityAriaLabel')}>
                {(['personal', 'team'] as CanvasScope[]).map((scope) => (
                  <button
                    key={scope}
                    type="button"
                    className={workflowScopeDraft === scope ? 'is-selected' : ''}
                    aria-pressed={workflowScopeDraft === scope}
                    disabled={workflowImporting}
                    onClick={() => setWorkflowScopeDraft(scope)}
                  >
                    {scope === 'team' ? t('templates.public') : t('templates.private')}
                  </button>
                ))}
              </div>
              <code className="claude-workflows__modal-path">{workflowImportTarget.path}</code>
              {workflowImportError && <div className="inline-error">{workflowImportError}</div>}
            </div>
            <div className="modal-footer">
              <button
                className="ghost"
                type="button"
                onClick={closeWorkflowImportDialog}
                disabled={workflowImporting}
              >
                {t('common.cancel')}
              </button>
              <button
                className="primary"
                type="button"
                onClick={submitWorkflowImport}
                disabled={workflowImporting || !workflowNameDraft.trim()}
              >
                {workflowImporting ? 'Importing…' : 'Import workflow'}
              </button>
            </div>
          </div>
        </div>
      )}
    </section>
  )
}

interface GalleryCardProps {
  template: CanvasTemplate
  onUse: () => void
  t: ReturnType<typeof useI18n>['t']
}

function GalleryCard({ template, onUse, t }: GalleryCardProps) {
  const Icon = ICONS_BY_NAME[template.icon] ?? Sparkles
  const count = template.defaultNodes.length
  return (
    <article className="template-gallery__card">
      <div className="template-gallery__card-head">
        <span className="template-gallery__card-icon" aria-hidden>
          <Icon size={18} />
        </span>
      </div>
      <h3 className="template-gallery__card-name">{template.name}</h3>
      <p className="template-gallery__card-desc">{template.description}</p>
      <div className="template-gallery__card-foot">
        <span className="template-gallery__node-count">
          {t('templates.gallery.nodeCount', { count, plural: count === 1 ? '' : 's' })}
        </span>
        <button
          type="button"
          className="primary template-gallery__use-button"
          onClick={onUse}
          aria-label={t('templates.gallery.useTemplateAria', { name: template.name })}
        >
          {t('templates.gallery.useTemplate')}
        </button>
      </div>
    </article>
  )
}

interface WorkflowRowProps {
  workflow: ClaudeWorkflow
  onImport: () => void
}

function WorkflowRow({ workflow, onImport }: WorkflowRowProps) {
  const description = workflow.description?.trim() || workflow.preview || workflow.path
  const visiblePhases = (workflow.phases ?? []).slice(0, 6)
  return (
    <article className="claude-workflows__row" data-readable={workflow.readable ? 'true' : 'false'}>
      <span className="claude-workflows__icon" aria-hidden>
        <FileCode2 size={17} />
      </span>
      <div className="claude-workflows__main">
        <div className="claude-workflows__title-row">
          <strong>{workflow.name}</strong>
          <code>{workflow.commandName}</code>
          <span>{formatBytes(workflow.sizeBytes)}</span>
        </div>
        <p>{description}</p>
        {visiblePhases.length > 0 && (
          <ol className="claude-workflows__phases" aria-label={`${workflow.name} phases`}>
            {visiblePhases.map((phase, index) => (
              <li key={`${phase.title}-${index}`} title={phase.detail ?? phase.title}>
                <span>{index + 1}</span>
                <strong>{phase.title}</strong>
              </li>
            ))}
          </ol>
        )}
        {!workflow.readable && workflow.error && <em>{workflow.error}</em>}
      </div>
      <button type="button" className="primary claude-workflows__import" onClick={onImport} disabled={!workflow.readable}>
        Import
      </button>
    </article>
  )
}

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B'
  const units = ['B', 'KB', 'MB']
  let value = bytes
  let idx = 0
  while (value >= 1024 && idx < units.length - 1) {
    value /= 1024
    idx += 1
  }
  return `${idx === 0 ? Math.round(value) : value.toFixed(value < 10 ? 1 : 0)} ${units[idx]}`
}


function visibilityTone(canvas: CanvasInfo): 'private' | 'public' {
  return canvas.scope === 'team' ? 'public' : 'private'
}

function visibilityLabel(canvas: CanvasInfo, t: ReturnType<typeof useI18n>['t']): string {
  return canvas.scope === 'team' ? t('templates.public') : t('templates.private')
}

function ownerIdentity(
  canvas: CanvasInfo,
  userProfile: UserProfile | null,
  ownersById: Record<string, OwnerIdentity>,
): OwnerIdentity {
  const ownerId = canvas.ownerUserId?.trim()
  if (!ownerId) return { name: 'Unknown owner', avatarUrl: null, initials: '?' }
  if (ownerId === 'local-user') {
    const name = userProfile?.connected ? userProfile.displayName || 'You' : 'You'
    return {
      name,
      avatarUrl: userProfile?.userAvatarUrl || null,
      initials: userProfile?.initials || initialsFor(name),
    }
  }
  if (userProfile?.connected && ownerMatchesProfile(ownerId, userProfile)) {
    const name = userProfile.displayName || 'You'
    return {
      name,
      avatarUrl: userProfile.userAvatarUrl || null,
      initials: userProfile.initials || initialsFor(name),
    }
  }
  return ownersById[ownerId] ?? { name: ownerId, avatarUrl: null, initials: initialsFor(ownerId) }
}

function ownerMatchesProfile(ownerId: string, userProfile: UserProfile): boolean {
  return [userProfile.userId, userProfile.userName, userProfile.userEmail]
    .filter(Boolean)
    .includes(ownerId)
}

function displayCanvasName(canvas: CanvasInfo): string {
  return canvas.name === 'Default canvas' ? 'My' : canvas.name
}

function initialsFor(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean)
  if (parts.length >= 2) return `${parts[0][0]}${parts[1][0]}`.toUpperCase()
  return (parts[0] ?? '?').slice(0, 2).toUpperCase()
}

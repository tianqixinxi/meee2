import {
  FileCode2,
  Gamepad2,
  GitPullRequest,
  Globe2,
  Eye,
  LockKeyhole,
  Moon,
  RefreshCw,
  Rocket,
  Search,
  Sparkles,
  Upload,
  Users,
  Wrench,
  type LucideIcon,
} from 'lucide-react'
import { type ChangeEvent, type ReactNode, useEffect, useMemo, useState } from 'react'
import type { BoardState, CanvasInfo, CanvasObject, CanvasRelation, CanvasScope } from '../types'
import {
  fetchClaudeWorkflows,
  fetchTeamMembers,
  fetchTemplateCatalog,
  type CanvasTemplate,
  type CanvasTemplateSource,
  type ClaudeWorkflow,
  type ClaudeWorkflowList,
  type TemplateMetadataInput,
  type UserProfile,
} from '../api'

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
  onApplyTemplate: (templateId: string, name: string, scope: CanvasScope) => Promise<string>
  onCreateTemplateDraft: (templateId: string) => Promise<string>
  onReplaceTemplate: (templateId: string, canvasId: string, input: TemplateMetadataInput) => Promise<string>
  onUpdateTemplateMetadata: (templateId: string, input: TemplateMetadataInput) => Promise<string>
  onImportClaudeWorkflow: (workflowId: string, name: string, scope: CanvasScope) => Promise<string>
  onUploadClaudeWorkflow: (filename: string, source: string, name: string, scope: CanvasScope) => Promise<string>
}

type WorkflowImportTarget =
  | { kind: 'library'; id: string; name: string; commandName: string; path: string }
  | { kind: 'upload'; filename: string; source: string; name: string; commandName: string; path: string }

const SOURCE_ORDER: CanvasTemplateSource[] = ['official', 'team', 'private', 'canvas-script']
const SOURCE_LABEL: Record<CanvasTemplateSource, string> = {
  official: 'Official',
  team: 'Team',
  private: 'Private',
  'canvas-script': 'Canvas Script',
}
const CLAUDE_WORKFLOW_MAX_BYTES = 256 * 1024

const ICONS_BY_NAME: Record<string, LucideIcon> = {
  'git-pull-request': GitPullRequest,
  rocket: Rocket,
  moon: Moon,
  users: Users,
  tool: Wrench,
  'gamepad-2': Gamepad2,
  sparkles: Sparkles,
}

export function TemplatesView({
  canvases,
  activeCanvasId,
  userProfile,
  boardState: _boardState,
  onOpenCanvas: _onOpenCanvas,
  onApplyTemplate,
  onCreateTemplateDraft,
  onReplaceTemplate: _onReplaceTemplate,
  onUpdateTemplateMetadata,
  onImportClaudeWorkflow,
  onUploadClaudeWorkflow,
}: TemplatesViewProps) {
  void _boardState
  void _onOpenCanvas
  void _onReplaceTemplate
  const [query, setQuery] = useState('')
  const [source, setSource] = useState<CanvasTemplateSource>('official')
  const [selectedTags, setSelectedTags] = useState<string[]>([])
  const [templates, setTemplates] = useState<CanvasTemplate[]>([])
  const [availableTags, setAvailableTags] = useState<string[]>([])
  const [catalogError, setCatalogError] = useState<string | null>(null)
  const [ownersById, setOwnersById] = useState<Record<string, OwnerIdentity>>({})
  const [previewTarget, setPreviewTarget] = useState<CanvasTemplate | null>(null)
  const [applyTarget, setApplyTarget] = useState<CanvasTemplate | null>(null)
  const [applyNameDraft, setApplyNameDraft] = useState('')
  const [applyScopeDraft, setApplyScopeDraft] = useState<CanvasScope>('personal')
  const [applyError, setApplyError] = useState<string | null>(null)
  const [applying, setApplying] = useState(false)
  const [metadataMode, setMetadataMode] = useState<'edit' | null>(null)
  const [metadataTarget, setMetadataTarget] = useState<CanvasTemplate | null>(null)
  const [metadataName, setMetadataName] = useState('')
  const [metadataDescription, setMetadataDescription] = useState('')
  const [metadataScope, setMetadataScope] = useState<CanvasScope>('personal')
  const [metadataTags, setMetadataTags] = useState<string[]>([])
  const [metadataError, setMetadataError] = useState<string | null>(null)
  const [metadataSaving, setMetadataSaving] = useState(false)
  const [workflowList, setWorkflowList] = useState<ClaudeWorkflowList | null>(null)
  const [workflowError, setWorkflowError] = useState<string | null>(null)
  const [workflowsLoading, setWorkflowsLoading] = useState(false)
  const [workflowImportTarget, setWorkflowImportTarget] = useState<WorkflowImportTarget | null>(null)
  const [workflowNameDraft, setWorkflowNameDraft] = useState('')
  const [workflowScopeDraft, setWorkflowScopeDraft] = useState<CanvasScope>('personal')
  const [workflowImportError, setWorkflowImportError] = useState<string | null>(null)
  const [workflowImporting, setWorkflowImporting] = useState(false)
  const [workflowUploadError, setWorkflowUploadError] = useState<string | null>(null)
  void canvases
  void activeCanvasId

  const refreshCatalog = () => {
    fetchTemplateCatalog()
      .then((catalog) => {
        setTemplates(catalog.templates)
        setAvailableTags(catalog.tags)
        setCatalogError(null)
      })
      .catch((err) => setCatalogError((err as Error).message || "Couldn't load templates. Refresh to retry."))
  }

  useEffect(refreshCatalog, [])

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

  const refreshWorkflows = () => {
    setWorkflowsLoading(true)
    setWorkflowError(null)
    fetchClaudeWorkflows()
      .then((result) => {
        setWorkflowList(result)
        setWorkflowError(result.error ?? null)
      })
      .catch((err) => setWorkflowError((err as Error).message || 'Failed to load Claude Code workflows'))
      .finally(() => setWorkflowsLoading(false))
  }

  useEffect(refreshWorkflows, [])

  const visibleTemplates = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase()
    return templates.filter((template) => {
      if (template.source !== source) return false
      if (selectedTags.length > 0 && !selectedTags.every((tag) => template.tags.includes(tag))) return false
      if (!normalizedQuery) return true
      const haystack = [
        template.name,
        template.description,
        template.ownerName ?? '',
        template.ownerUserId ?? '',
        ...template.tags,
      ].join(' ').toLowerCase()
      return haystack.includes(normalizedQuery)
    })
  }, [query, selectedTags, source, templates])

  const openApplyDialog = (template: CanvasTemplate) => {
    setApplyTarget(template)
    setApplyNameDraft(template.name)
    setApplyScopeDraft('personal')
    setApplyError(null)
  }

  const submitApply = () => {
    if (!applyTarget) return
    const name = applyNameDraft.trim()
    if (!name) {
      setApplyError('Give your canvas a name first')
      return
    }
    setApplying(true)
    setApplyError(null)
    onApplyTemplate(applyTarget.id, name, applyScopeDraft)
      .then(() => {
        setApplyTarget(null)
        setApplyNameDraft('')
        setApplying(false)
      })
      .catch((err) => {
        setApplyError((err as Error).message || "Couldn't apply that template.")
        setApplying(false)
      })
  }

  const openMetadataDialog = (template: CanvasTemplate) => {
    setMetadataMode('edit')
    setMetadataTarget(template)
    setMetadataName(template.name)
    setMetadataDescription(template.description)
    setMetadataScope(template.source === 'team' ? 'team' : 'personal')
    setMetadataTags(template.tags)
    setMetadataError(null)
  }

  const closeMetadataDialog = () => {
    setMetadataMode(null)
    setMetadataTarget(null)
    setMetadataSaving(false)
    setMetadataError(null)
  }

  const submitMetadata = () => {
    const name = metadataName.trim()
    if (!name) {
      setMetadataError('Template name is required')
      return
    }
    const input: TemplateMetadataInput = {
      name,
      description: metadataDescription.trim(),
      scope: metadataScope,
      tags: metadataTags,
      icon: metadataTarget?.icon ?? 'sparkles',
      defaultCanvasKind: metadataTarget?.defaultCanvasKind,
    }
    setMetadataSaving(true)
    setMetadataError(null)
    const request = metadataTarget
      ? onUpdateTemplateMetadata(metadataTarget.id, input)
      : Promise.reject(new Error('No template selected'))
    request
      .then(() => {
        closeMetadataDialog()
        refreshCatalog()
      })
      .catch((err) => {
        setMetadataError((err as Error).message || 'Failed to save template')
        setMetadataSaving(false)
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
      .catch((err) => setWorkflowUploadError((err as Error).message || 'Failed to read workflow file'))
  }

  const submitWorkflowImport = () => {
    if (!workflowImportTarget) return
    const name = workflowNameDraft.trim()
    if (!name) {
      setWorkflowImportError('Give your canvas a name first')
      return
    }
    setWorkflowImporting(true)
    setWorkflowImportError(null)
    const request = workflowImportTarget.kind === 'library'
      ? onImportClaudeWorkflow(workflowImportTarget.id, name, workflowScopeDraft)
      : onUploadClaudeWorkflow(workflowImportTarget.filename, workflowImportTarget.source, name, workflowScopeDraft)
    request
      .then(() => {
        setWorkflowImportTarget(null)
        setWorkflowNameDraft('')
        setWorkflowImporting(false)
      })
      .catch((err) => {
        setWorkflowImportError((err as Error).message || 'Failed to import Claude Code workflow')
        setWorkflowImporting(false)
      })
  }

  return (
    <section className="templates-workspace" aria-label="Templates">
      <div className="templates-workspace__inner">
        <header className="templates-workspace__header">
          <div>
            <span>Templates</span>
            <h1>Canvas templates</h1>
            <p className="templates-workspace__hint">Templates are created from tuned canvases. Open or create a canvas, then save it from Canvas settings.</p>
          </div>
          <div className="templates-workspace__tools">
            <label className="templates-search">
              <Search size={14} aria-hidden />
              <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Find template" />
            </label>
          </div>
        </header>

        <section className="template-gallery" aria-label="Template catalog">
          <div className="template-gallery__header">
            <h2 className="template-gallery__title">Start from a template</h2>
            <div className="template-gallery__tabs" role="tablist">
              {SOURCE_ORDER.map((entry) => {
                const count = templates.filter((template) => template.source === entry).length
                const active = source === entry
                return (
                  <button
                    key={entry}
                    type="button"
                    role="tab"
                    aria-selected={active}
                    className={`template-gallery__tab${active ? ' is-active' : ''}`}
                    onClick={() => setSource(entry)}
                  >
                    {SOURCE_LABEL[entry]}
                    <span className="template-gallery__tab-count">{count}</span>
                  </button>
                )
              })}
            </div>
          </div>

          <div className="template-gallery__tags" aria-label="Template tags">
            {availableTags.map((tag) => {
              const active = selectedTags.includes(tag)
              return (
                <button
                  key={tag}
                  type="button"
                  className={`template-gallery__tag${active ? ' is-active' : ''}`}
                  aria-pressed={active}
                  onClick={() => setSelectedTags((prev) => active ? prev.filter((item) => item !== tag) : [...prev, tag])}
                >
                  {tag}
                </button>
              )
            })}
          </div>

          {catalogError ? (
            <div className="inline-error template-gallery__error">{catalogError}</div>
          ) : visibleTemplates.length === 0 ? (
            <div className="template-gallery__empty">
              No templates match this view. To create one, open or create a canvas, tune it, then save it from Canvas settings.
            </div>
          ) : (
            <div className="template-gallery__grid">
              {visibleTemplates.map((template) => (
                <GalleryCard
                  key={template.id}
                  template={template}
                  owner={ownerIdentityForTemplate(template, userProfile, ownersById)}
                  onUse={() => openApplyDialog(template)}
                  onPreview={() => setPreviewTarget(template)}
                  onEdit={() => void onCreateTemplateDraft(template.id)}
                  onMetadata={() => openMetadataDialog(template)}
                />
              ))}
            </div>
          )}
        </section>

        <section className="claude-workflows" aria-label="Claude Code workflows">
          <div className="template-gallery__header">
            <div>
              <h2 className="template-gallery__title">Claude Code workflows</h2>
              <p className="claude-workflows__root">{workflowList?.root ?? '~/.claude/workflows'}</p>
              <p className="claude-workflows__root">Imported workflows create a canvas directly; tune it, then save the canvas as a template.</p>
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
                {workflowsLoading ? 'Scanning...' : 'Refresh'}
              </button>
            </div>
          </div>
          {workflowUploadError ? (
            <div className="inline-error template-gallery__error">{workflowUploadError}</div>
          ) : workflowError ? (
            <div className="inline-error template-gallery__error">{workflowError}</div>
          ) : !workflowList || workflowsLoading ? (
            <div className="template-gallery__empty">Scanning global Claude Code workflows...</div>
          ) : workflowList.workflows.length === 0 ? (
            <div className="template-gallery__empty">No global <code>*.js</code> workflows found.</div>
          ) : (
            <div className="claude-workflows__list">
              {workflowList.workflows.map((workflow) => (
                <WorkflowRow key={workflow.id} workflow={workflow} onImport={() => openWorkflowImportDialog(workflow)} />
              ))}
            </div>
          )}
        </section>
      </div>

      {applyTarget && (
        <TemplateModal title={`Use template - ${applyTarget.name}`} subtitle={`Creates a new canvas from v${applyTarget.version}.`} onClose={() => !applying && setApplyTarget(null)}>
          <input value={applyNameDraft} onChange={(event) => setApplyNameDraft(event.target.value)} placeholder="Canvas name" autoFocus disabled={applying} />
          <ScopeToggle value={applyScopeDraft} onChange={setApplyScopeDraft} disabled={applying} />
          {applyError && <div className="inline-error">{applyError}</div>}
          <ModalFooter onCancel={() => setApplyTarget(null)} onSubmit={submitApply} submitLabel={applying ? 'Creating...' : 'Create canvas'} disabled={applying || !applyNameDraft.trim()} />
        </TemplateModal>
      )}

      {previewTarget && (
        <TemplateModal
          title={`Preview - ${previewTarget.name}`}
          subtitle="Read-only template canvas. Preview does not create a canvas."
          onClose={() => setPreviewTarget(null)}
        >
          <TemplatePreviewCanvas template={previewTarget} />
          <div className="template-preview__actions">
            {!previewTarget.readOnly && (
              <button
                type="button"
                className="ghost"
                onClick={() => void onCreateTemplateDraft(previewTarget.id)}
                disabled={!previewTarget.canEdit}
              >
                Edit draft
              </button>
            )}
            <button
              type="button"
              className="primary"
              onClick={() => {
                const target = previewTarget
                setPreviewTarget(null)
                openApplyDialog(target)
              }}
            >
              Use template
            </button>
          </div>
        </TemplateModal>
      )}

      {metadataMode && (
        <TemplateModal
          title="Edit template details"
          subtitle="Only the owner can change Team template metadata."
          onClose={() => !metadataSaving && closeMetadataDialog()}
        >
          <input value={metadataName} onChange={(event) => setMetadataName(event.target.value)} placeholder="Template name" autoFocus disabled={metadataSaving} />
          <textarea value={metadataDescription} onChange={(event) => setMetadataDescription(event.target.value)} placeholder="Description" disabled={metadataSaving} />
          <ScopeToggle value={metadataScope} onChange={setMetadataScope} disabled={metadataSaving} />
          <div className="template-gallery__tags" aria-label="Choose tags">
            {availableTags.map((tag) => {
              const active = metadataTags.includes(tag)
              return (
                <button
                  key={tag}
                  type="button"
                  className={`template-gallery__tag${active ? ' is-active' : ''}`}
                  aria-pressed={active}
                  disabled={metadataSaving}
                  onClick={() => setMetadataTags((prev) => active ? prev.filter((item) => item !== tag) : [...prev, tag])}
                >
                  {tag}
                </button>
              )
            })}
          </div>
          {metadataError && <div className="inline-error">{metadataError}</div>}
          <ModalFooter onCancel={closeMetadataDialog} onSubmit={submitMetadata} submitLabel={metadataSaving ? 'Saving...' : 'Save'} disabled={metadataSaving || !metadataName.trim()} />
        </TemplateModal>
      )}

      {workflowImportTarget && (
        <TemplateModal title={`Import ${workflowImportTarget.commandName}`} subtitle="meee2 reads workflow metadata and phases to create a canvas plan. The script is not executed." onClose={() => !workflowImporting && setWorkflowImportTarget(null)}>
          <input value={workflowNameDraft} onChange={(event) => setWorkflowNameDraft(event.target.value)} placeholder="Canvas name" autoFocus disabled={workflowImporting} />
          <ScopeToggle value={workflowScopeDraft} onChange={setWorkflowScopeDraft} disabled={workflowImporting} />
          <code className="claude-workflows__modal-path">{workflowImportTarget.path}</code>
          {workflowImportError && <div className="inline-error">{workflowImportError}</div>}
          <ModalFooter onCancel={() => setWorkflowImportTarget(null)} onSubmit={submitWorkflowImport} submitLabel={workflowImporting ? 'Importing...' : 'Import workflow'} disabled={workflowImporting || !workflowNameDraft.trim()} />
        </TemplateModal>
      )}
    </section>
  )
}

interface GalleryCardProps {
  template: CanvasTemplate
  owner: OwnerIdentity
  onUse: () => void
  onPreview: () => void
  onEdit: () => void
  onMetadata: () => void
}

function GalleryCard({ template, owner, onUse, onPreview, onEdit, onMetadata }: GalleryCardProps) {
  const Icon = ICONS_BY_NAME[template.icon] ?? Sparkles
  const nodeCount = template.defaultNodesCount || template.defaultNodes.length
  return (
    <article className="template-gallery__card">
      <div className="template-gallery__card-head">
        <span className="template-gallery__card-icon" aria-hidden><Icon size={18} /></span>
        <span className={`templates-visibility templates-visibility--${template.source === 'team' ? 'public' : 'private'}`}>
          {template.source === 'team' ? <Globe2 size={11} aria-hidden /> : template.source === 'private' ? <LockKeyhole size={11} aria-hidden /> : <Sparkles size={11} aria-hidden />}
          {SOURCE_LABEL[template.source]}
        </span>
      </div>
      <h3 className="template-gallery__card-name">{template.name}</h3>
      <p className="template-gallery__card-desc">{template.description || 'Reusable canvas structure'}</p>
      <div className="template-gallery__tags">
        {template.tags.slice(0, 4).map((tag) => <span key={tag} className="template-gallery__tag">{tag}</span>)}
      </div>
      {template.source === 'team' && (
        <span className="template-row__owner" title={`Owner: ${owner.name}`}>
          <span className={`template-row__owner-avatar${owner.avatarUrl ? ' has-image' : ''}`}>
            {owner.avatarUrl ? <img src={owner.avatarUrl} alt="" /> : owner.initials}
          </span>
          <span className="template-row__owner-name">{owner.name}</span>
        </span>
      )}
      <div className="template-gallery__card-foot">
        <span className="template-gallery__node-count">{nodeCount} node{nodeCount === 1 ? '' : 's'} · v{template.version}</span>
        <div className="template-gallery__card-actions">
          <button type="button" className="ghost template-gallery__preview-button" onClick={onPreview} aria-label={`Preview template ${template.name}`}>
            <Eye size={12} aria-hidden />
            Preview
          </button>
          <button type="button" className="primary template-gallery__use-button" onClick={onUse} aria-label={`Use template ${template.name}`}>Use template</button>
        </div>
      </div>
      {!template.readOnly && (
        <div className="template-gallery__card-foot">
          <button type="button" className="ghost" onClick={onMetadata} disabled={!template.canEdit} title={template.canEdit ? 'Edit template metadata' : 'Only the owner can edit this template'}>Details</button>
          <button type="button" className="ghost" onClick={onEdit} disabled={!template.canEdit} title={template.canEdit ? 'Create an editable draft canvas' : 'Only the owner can edit this template'}>Edit draft</button>
        </div>
      )}
    </article>
  )
}

function TemplateModal({ title, subtitle, onClose, children }: { title: string; subtitle: string; onClose: () => void; children: ReactNode }) {
  return (
    <div className="modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose() }}>
      <div className="modal canvas-confirm-modal template-gallery__apply-modal" role="dialog" aria-modal="true" aria-label={title}>
        <div className="modal-header">
          <div className="modal-title">{title}</div>
          <div className="modal-subtitle">{subtitle}</div>
        </div>
        <div className="modal-body col" style={{ gap: 10 }}>{children}</div>
      </div>
    </div>
  )
}

function ModalFooter({ onCancel, onSubmit, submitLabel, disabled }: { onCancel: () => void; onSubmit: () => void; submitLabel: string; disabled: boolean }) {
  return (
    <div className="modal-footer">
      <button className="ghost" type="button" onClick={onCancel}>Cancel</button>
      <button className="primary" type="button" onClick={onSubmit} disabled={disabled}>{submitLabel}</button>
    </div>
  )
}

interface TemplatePreviewObject {
  id: string
  label: string
  kind: string
  x: number
  y: number
  width: number
  height: number
}

interface TemplatePreviewModel {
  objects: TemplatePreviewObject[]
  relations: Array<{ id: string; source: string; target: string; kind: string }>
  bounds: { minX: number; minY: number; width: number; height: number }
}

function TemplatePreviewCanvas({ template }: { template: CanvasTemplate }) {
  const model = useMemo(() => buildTemplatePreviewModel(template), [template])
  const sceneKind = template.renderProfile?.logic.layout === 'spatial' || template.sceneSpec ? template.sceneSpec?.kind : null
  if (model.objects.length === 0) {
    return (
      <div className="template-preview template-preview--empty">
        <strong>{template.name}</strong>
        <span>No preview objects are available for this template.</span>
      </div>
    )
  }
  const objectById = new Map(model.objects.map((object) => [object.id, object]))
  return (
    <div className={`template-preview${sceneKind ? ' template-preview--scene' : ''}`} aria-label={`${template.name} preview`}>
      {sceneKind && <span className="template-preview__scene-pill">{sceneKind}</span>}
      <svg className="template-preview__edges" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden>
        {model.relations.map((relation) => {
          const source = objectById.get(relation.source)
          const target = objectById.get(relation.target)
          if (!source || !target) return null
          const a = objectCenterPercent(source, model.bounds)
          const b = objectCenterPercent(target, model.bounds)
          return (
            <line
              key={relation.id}
              className={`template-preview__edge template-preview__edge--${cssToken(relation.kind)}`}
              x1={a.x}
              y1={a.y}
              x2={b.x}
              y2={b.y}
            />
          )
        })}
      </svg>
      {model.objects.map((object) => {
        const frame = objectFramePercent(object, model.bounds)
        return (
          <div
            key={object.id}
            className={`template-preview__object template-preview__object--${cssToken(object.kind)}`}
            style={{
              left: `${frame.left}%`,
              top: `${frame.top}%`,
              width: `${frame.width}%`,
              height: `${frame.height}%`,
            }}
            title={object.label}
          >
            <span>{object.kind}</span>
            <strong>{object.label}</strong>
          </div>
        )
      })}
    </div>
  )
}

function ScopeToggle({ value, onChange, disabled }: { value: CanvasScope; onChange: (scope: CanvasScope) => void; disabled: boolean }) {
  return (
    <div className="canvas-toolbar__scope-toggle" role="group" aria-label="Visibility">
      {(['personal', 'team'] as CanvasScope[]).map((scope) => (
        <button key={scope} type="button" className={value === scope ? 'is-selected' : ''} aria-pressed={value === scope} disabled={disabled} onClick={() => onChange(scope)}>
          {scope === 'team' ? 'Team' : 'Private'}
        </button>
      ))}
    </div>
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
      <span className="claude-workflows__icon" aria-hidden><FileCode2 size={17} /></span>
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
      <button type="button" className="primary claude-workflows__import" onClick={onImport} disabled={!workflow.readable}>Import</button>
    </article>
  )
}

function ownerIdentityForTemplate(
  template: CanvasTemplate,
  userProfile: UserProfile | null,
  ownersById: Record<string, OwnerIdentity>,
): OwnerIdentity {
  const ownerId = template.ownerUserId?.trim()
  if (!ownerId) return { name: template.ownerName ?? 'meee2', avatarUrl: null, initials: 'M' }
  if (ownerId === 'local-user' || (userProfile?.connected && ownerMatchesProfile(ownerId, userProfile))) {
    const name = userProfile?.connected ? userProfile.displayName || 'You' : template.ownerName || 'You'
    return { name, avatarUrl: userProfile?.userAvatarUrl || null, initials: userProfile?.initials || initialsFor(name) }
  }
  return ownersById[ownerId] ?? { name: template.ownerName || ownerId, avatarUrl: null, initials: initialsFor(template.ownerName || ownerId) }
}

function ownerMatchesProfile(ownerId: string, userProfile: UserProfile): boolean {
  return [userProfile.userId, userProfile.userName, userProfile.userEmail].filter(Boolean).includes(ownerId)
}

function buildTemplatePreviewModel(template: CanvasTemplate): TemplatePreviewModel {
  const objects = previewObjectsForTemplate(template)
  const relations = (template.renderRelations ?? [])
    .filter((relation) => relation.values?.visible !== false)
    .map((relation) => ({
      id: relation.id,
      source: relation.source.objectId,
      target: relation.target.objectId,
      kind: relation.kind,
    }))
  return {
    objects,
    relations,
    bounds: boundsForObjects(objects),
  }
}

function previewObjectsForTemplate(template: CanvasTemplate): TemplatePreviewObject[] {
  const objects = (template.renderObjects ?? [])
    .filter((object) => object.values?.hidden !== true && object.renderOnly?.kind !== 'background')
    .map(previewObjectFromCanvasObject)
  if (objects.length > 0) return objects
  return template.defaultNodes.map((node, index) => {
    const width = node.positionHint?.width ?? 240
    const height = node.positionHint?.height ?? 120
    return {
      id: `node:${index}`,
      label: node.title,
      kind: node.widget ? 'widget' : 'node',
      x: node.positionHint?.x ?? (index % 3) * 280,
      y: node.positionHint?.y ?? Math.floor(index / 3) * 160,
      width,
      height,
    }
  })
}

function previewObjectFromCanvasObject(object: CanvasObject): TemplatePreviewObject {
  const values = object.values ?? {}
  const size = defaultPreviewSize(object)
  return {
    id: object.id,
    label: object.label,
    kind: object.entityRef?.kind ?? object.renderOnly?.kind ?? object.renderer,
    x: typeof values.x === 'number' ? values.x : 0,
    y: typeof values.y === 'number' ? values.y : 0,
    width: typeof values.width === 'number' ? values.width : size.width,
    height: typeof values.height === 'number' ? values.height : size.height,
  }
}

function defaultPreviewSize(object: CanvasObject): { width: number; height: number } {
  switch (object.renderer) {
    case 'kanban':
    case 'matrix':
    case 'grid': return { width: 320, height: 190 }
    case 'list':
    case 'document': return { width: 260, height: 150 }
    case 'avatar': return { width: 150, height: 90 }
    case 'container': return { width: 280, height: 150 }
    default: return { width: 220, height: 110 }
  }
}

function boundsForObjects(objects: TemplatePreviewObject[]): TemplatePreviewModel['bounds'] {
  if (objects.length === 0) return { minX: 0, minY: 0, width: 1, height: 1 }
  const minX = Math.min(...objects.map((object) => object.x))
  const minY = Math.min(...objects.map((object) => object.y))
  const maxX = Math.max(...objects.map((object) => object.x + object.width))
  const maxY = Math.max(...objects.map((object) => object.y + object.height))
  return {
    minX,
    minY,
    width: Math.max(1, maxX - minX),
    height: Math.max(1, maxY - minY),
  }
}

function objectFramePercent(object: TemplatePreviewObject, bounds: TemplatePreviewModel['bounds']) {
  const pad = 6
  const available = 100 - pad * 2
  return {
    left: pad + ((object.x - bounds.minX) / bounds.width) * available,
    top: pad + ((object.y - bounds.minY) / bounds.height) * available,
    width: Math.max(10, (object.width / bounds.width) * available),
    height: Math.max(8, (object.height / bounds.height) * available),
  }
}

function objectCenterPercent(object: TemplatePreviewObject, bounds: TemplatePreviewModel['bounds']) {
  const frame = objectFramePercent(object, bounds)
  return {
    x: frame.left + frame.width / 2,
    y: frame.top + frame.height / 2,
  }
}

function cssToken(value: string): string {
  return value.replace(/([a-z])([A-Z])/g, '$1-$2').replace(/[^a-zA-Z0-9_-]+/g, '-').toLowerCase()
}

function initialsFor(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean)
  if (parts.length >= 2) return `${parts[0][0]}${parts[1][0]}`.toUpperCase()
  return (parts[0] ?? '?').slice(0, 2).toUpperCase()
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

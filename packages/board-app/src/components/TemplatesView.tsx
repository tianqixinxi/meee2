import { ArrowLeft, Globe2, LockKeyhole, Plus, Search } from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import type { BoardState, CanvasInfo, CanvasScope } from '../types'
import { fetchTeamMembers, type UserProfile } from '../api'
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
}

export function TemplatesView({
  canvases,
  activeCanvasId,
  userProfile,
  boardState,
  onOpenCanvas,
  onCreateTemplate,
}: TemplatesViewProps) {
  const { t } = useI18n()
  const [selectedTemplateId, setSelectedTemplateId] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [creating, setCreating] = useState(false)
  const [nameDraft, setNameDraft] = useState('')
  const [scopeDraft, setScopeDraft] = useState<CanvasScope>('personal')
  const [error, setError] = useState<string | null>(null)
  const [ownersById, setOwnersById] = useState<Record<string, OwnerIdentity>>({})

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
      template.scope === 'team' ? 'public' : 'private',
    ].some((value) => value.toLowerCase().includes(normalizedQuery)))
  }, [ownersById, query, templates, userProfile])

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

        {error && <div className="inline-error templates-error">{error}</div>}

        {filteredTemplates.length > 0 ? (
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
        ) : (
          <div className="templates-empty">
            {templates.length === 0 ? t('templates.empty') : t('templates.noMatch')}
          </div>
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
    </section>
  )
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

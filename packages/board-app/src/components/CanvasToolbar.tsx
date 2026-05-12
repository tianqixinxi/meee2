import { useEffect, useRef, useState } from 'react'
import { Check, ChevronDown, Layers, LayoutGrid, Pencil, Plus, Trash2 } from 'lucide-react'
import type { CanvasInfo, CanvasScope } from '../types'
import { useI18n } from '../i18n'

interface Props {
  canvases: CanvasInfo[]
  activeCanvasId: string
  onActiveCanvasChange: (canvasId: string) => void
  onCreateCanvas: (name: string, scope: CanvasScope) => Promise<void> | void
  onRenameCanvas: (canvasId: string, name: string) => Promise<void> | void
  onDeleteCanvas: (canvasId: string) => Promise<void> | void
  onArrangeSessions: () => void
}

export function CanvasToolbar({
  canvases,
  activeCanvasId,
  onActiveCanvasChange,
  onCreateCanvas,
  onRenameCanvas,
  onDeleteCanvas,
  onArrangeSessions,
}: Props) {
  const { t } = useI18n()
  const rootRef = useRef<HTMLDivElement | null>(null)
  const [menuOpen, setMenuOpen] = useState(false)
  const [creating, setCreating] = useState(false)
  const [renaming, setRenaming] = useState(false)
  const [deleteConfirming, setDeleteConfirming] = useState(false)
  const [canvasNameDraft, setCanvasNameDraft] = useState('')
  const [canvasScopeDraft, setCanvasScopeDraft] = useState<CanvasScope>('personal')

  const activeCanvas = canvases.find((canvas) => canvas.id === activeCanvasId) ?? canvases[0]

  const closePanels = () => {
    setCreating(false)
    setRenaming(false)
    setDeleteConfirming(false)
  }

  useEffect(() => {
    if (!menuOpen) return
    const onPointerDown = (event: PointerEvent) => {
      const node = rootRef.current
      if (node && event.target instanceof Node && node.contains(event.target)) return
      setMenuOpen(false)
      closePanels()
    }
    document.addEventListener('pointerdown', onPointerDown, true)
    return () => document.removeEventListener('pointerdown', onPointerDown, true)
  }, [menuOpen])

  const submitCreate = () => {
    const name = canvasNameDraft.trim()
    if (!name) return
    Promise.resolve(onCreateCanvas(name, canvasScopeDraft)).then(() => {
      setCanvasNameDraft('')
      setCanvasScopeDraft('personal')
      setCreating(false)
      setMenuOpen(false)
    })
  }

  const submitRename = () => {
    const name = canvasNameDraft.trim()
    if (!activeCanvas || !name) return
    Promise.resolve(onRenameCanvas(activeCanvas.id, name)).then(() => {
      setCanvasNameDraft('')
      setRenaming(false)
      setMenuOpen(false)
    })
  }

  const submitDelete = () => {
    if (!activeCanvas || activeCanvas.isDefault) return
    Promise.resolve(onDeleteCanvas(activeCanvas.id)).then(() => {
      setDeleteConfirming(false)
      setMenuOpen(false)
    })
  }

  if (!activeCanvas) return null

  return (
    <div className="canvas-toolbar" ref={rootRef}>
      <div className="canvas-toolbar__main">
        <button
          type="button"
          className="canvas-toolbar__trigger"
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          onClick={() => {
            closePanels()
            setMenuOpen((value) => !value)
          }}
        >
          <Layers size={15} aria-hidden />
          <span className="canvas-toolbar__scope">
            {activeCanvas.scope === 'team' ? t('scope.team') : t('scope.personal')}
          </span>
          <span className="canvas-toolbar__name">{activeCanvas.name}</span>
          {activeCanvas.isDefault && (
            <span className="canvas-toolbar__badge">{t('map.default')}</span>
          )}
          <ChevronDown size={14} aria-hidden />
        </button>
      </div>

      {menuOpen && (
        <div className="canvas-toolbar__panel">
          <div className="canvas-toolbar__list">
            {canvases.map((canvas) => {
              const selected = canvas.id === activeCanvas.id
              return (
                <button
                  key={canvas.id}
                  type="button"
                  className={'canvas-toolbar__item' + (selected ? ' is-selected' : '')}
                  onClick={() => {
                    closePanels()
                    setMenuOpen(false)
                    onActiveCanvasChange(canvas.id)
                  }}
                >
                  <span className="canvas-toolbar__check">
                    {selected && <Check size={13} aria-hidden />}
                  </span>
                  <span className="canvas-toolbar__item-text">
                    <span>{canvas.name}</span>
                    <span>
                      {canvas.scope === 'team' ? t('scope.team') : t('scope.personal')}
                      {canvas.isDefault ? ` · ${t('map.default')}` : ''}
                    </span>
                  </span>
                </button>
              )
            })}
          </div>
          <div className="canvas-toolbar__actions">
            <button
              type="button"
              onClick={() => {
                setCanvasNameDraft('')
                setCreating(true)
                setMenuOpen(false)
                setRenaming(false)
                setDeleteConfirming(false)
              }}
            >
              <Plus size={13} aria-hidden /> {t('map.new')}
            </button>
            <button
              type="button"
              onClick={() => {
                closePanels()
                setMenuOpen(false)
                onArrangeSessions()
              }}
            >
              <LayoutGrid size={13} aria-hidden /> {t('map.arrange')}
            </button>
            <button
              type="button"
              onClick={() => {
                setCanvasNameDraft(activeCanvas.name)
                setRenaming((value) => !value)
                setCreating(false)
                setDeleteConfirming(false)
              }}
            >
              <Pencil size={13} aria-hidden /> {t('map.rename')}
            </button>
            <button
              type="button"
              className="canvas-toolbar__danger-action"
              onClick={() => {
                setDeleteConfirming(true)
                setMenuOpen(false)
                setCreating(false)
                setRenaming(false)
              }}
              disabled={activeCanvas.isDefault}
              title={activeCanvas.isDefault ? 'Default map cannot be deleted' : t('map.delete')}
            >
              <Trash2 size={13} aria-hidden /> Delete
            </button>
          </div>
          {renaming && (
            <div className="canvas-toolbar__form canvas-toolbar__form--rename">
              <input
                value={canvasNameDraft}
                onChange={(event) => setCanvasNameDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') submitRename()
                  if (event.key === 'Escape') setRenaming(false)
                }}
                placeholder={t('map.namePlaceholder')}
                autoFocus
              />
              <button
                type="button"
                className="canvas-toolbar__submit"
                onClick={submitRename}
                disabled={!canvasNameDraft.trim()}
              >
                Save
              </button>
            </div>
          )}
        </div>
      )}

      {creating && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setCreating(false)
          }}
        >
          <div className="modal canvas-confirm-modal" role="dialog" aria-modal="true" aria-label={t('map.create')}>
            <div className="modal-header">
              <div className="modal-title">{t('map.create')}</div>
              <div className="modal-subtitle">{t('map.createSubtitle')}</div>
            </div>
            <div className="modal-body col" style={{ gap: 10 }}>
              <input
                value={canvasNameDraft}
                onChange={(event) => setCanvasNameDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') submitCreate()
                  if (event.key === 'Escape') setCreating(false)
                }}
                placeholder={t('map.namePlaceholder')}
                autoFocus
              />
              <div className="canvas-toolbar__scope-toggle" role="group" aria-label="Canvas scope">
                {(['personal', 'team'] as CanvasScope[]).map((scope) => (
                  <button
                    key={scope}
                    type="button"
                    className={canvasScopeDraft === scope ? 'is-selected' : ''}
                    aria-pressed={canvasScopeDraft === scope}
                    onClick={() => setCanvasScopeDraft(scope)}
                  >
                    {scope === 'team' ? t('scope.team') : t('scope.personal')}
                  </button>
                ))}
              </div>
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setCreating(false)}>{t('action.cancel')}</button>
              <button
                className="primary"
                type="button"
                onClick={submitCreate}
                disabled={!canvasNameDraft.trim()}
              >
                {t('action.create')}
              </button>
            </div>
          </div>
        </div>
      )}
      {deleteConfirming && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setDeleteConfirming(false)
          }}
        >
          <div className="modal canvas-confirm-modal" role="dialog" aria-modal="true" aria-label={t('map.delete')}>
            <div className="modal-header">
              <div className="modal-title">{t('map.delete')}</div>
              <div className="modal-subtitle">{t('map.deleteSubtitle')}</div>
            </div>
            <div className="modal-body col" style={{ gap: 8 }}>
              <strong>{activeCanvas.name}</strong>
              <span className="muted" style={{ fontSize: 12, lineHeight: 1.4 }}>
                {t('map.deleteBody')}
              </span>
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setDeleteConfirming(false)}>{t('action.cancel')}</button>
              <button className="danger" type="button" onClick={submitDelete}>{t('action.delete')}</button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

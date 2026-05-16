import { useEffect, useRef, useState } from 'react'
import { Check, ChevronDown, Layers, Pencil, Plus, Trash2 } from 'lucide-react'
import type { CanvasInfo, CanvasScope } from '../types'
import { resolveCanvasConflict } from '../api'

interface Props {
  canvases: CanvasInfo[]
  activeCanvasId: string
  onActiveCanvasChange: (canvasId: string) => void
  onCreateCanvas: (name: string, scope: CanvasScope) => Promise<void> | void
  onRenameCanvas: (canvasId: string, name: string) => Promise<void> | void
  onDeleteCanvas: (canvasId: string) => Promise<void> | void
}

export function CanvasToolbar({
  canvases,
  activeCanvasId,
  onActiveCanvasChange,
  onCreateCanvas,
  onRenameCanvas,
  onDeleteCanvas,
}: Props) {
  const rootRef = useRef<HTMLDivElement | null>(null)
  const [menuOpen, setMenuOpen] = useState(false)
  const [creating, setCreating] = useState(false)
  const [renaming, setRenaming] = useState(false)
  const [deleteConfirming, setDeleteConfirming] = useState(false)
  const [canvasNameDraft, setCanvasNameDraft] = useState('')
  const [canvasScopeDraft, setCanvasScopeDraft] = useState<CanvasScope>('personal')
  const [resolvingConflict, setResolvingConflict] = useState(false)

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

  const resolveConflict = (choice: 'current' | 'remote') => {
    if (!activeCanvas || activeCanvas.syncStatus !== 'conflict') return
    setResolvingConflict(true)
    Promise.resolve(resolveCanvasConflict(activeCanvas.id, choice))
      .then(() => {
        window.location.reload()
      })
      .finally(() => setResolvingConflict(false))
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
            {activeCanvas.scope === 'team' ? 'Team' : 'Personal'}
          </span>
          <span className="canvas-toolbar__name">{activeCanvas.name}</span>
          {activeCanvas.isDefault && (
            <span className="canvas-toolbar__badge">Default</span>
          )}
          {activeCanvas.syncStatus === 'conflict' && (
            <span className="canvas-toolbar__badge">Conflict</span>
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
                      {canvas.scope === 'team' ? 'Team' : 'Personal'}
                      {canvas.isDefault ? ' · Default' : ''}
                      {canvas.syncStatus === 'conflict' ? ' · Conflict' : ''}
                      {canvas.syncStatus === 'pending' || canvas.syncStatus === 'force-pending' ? ' · Syncing' : ''}
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
              <Plus size={13} aria-hidden /> New canvas
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
              <Pencil size={13} aria-hidden /> Rename
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
              title={activeCanvas.isDefault ? 'Default canvas cannot be deleted' : 'Delete canvas'}
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
                placeholder="Canvas name"
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

      {activeCanvas.syncStatus === 'conflict' && (
        <div className="canvas-toolbar__conflict" role="status">
          <span>Remote changes conflict with this team canvas.</span>
          <button type="button" disabled={resolvingConflict} onClick={() => resolveConflict('current')}>
            Use current
          </button>
          <button type="button" disabled={resolvingConflict} onClick={() => resolveConflict('remote')}>
            Use remote
          </button>
        </div>
      )}

      {creating && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setCreating(false)
          }}
        >
          <div className="modal canvas-confirm-modal" role="dialog" aria-modal="true" aria-label="Create canvas">
            <div className="modal-header">
              <div className="modal-title">Create canvas</div>
              <div className="modal-subtitle">Name it and choose where it lives.</div>
            </div>
            <div className="modal-body col" style={{ gap: 10 }}>
              <input
                value={canvasNameDraft}
                onChange={(event) => setCanvasNameDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') submitCreate()
                  if (event.key === 'Escape') setCreating(false)
                }}
                placeholder="Canvas name"
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
                    {scope === 'team' ? 'Team' : 'Personal'}
                  </button>
                ))}
              </div>
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setCreating(false)}>Cancel</button>
              <button
                className="primary"
                type="button"
                onClick={submitCreate}
                disabled={!canvasNameDraft.trim()}
              >
                Create
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
          <div className="modal canvas-confirm-modal" role="dialog" aria-modal="true" aria-label="Delete canvas">
            <div className="modal-header">
              <div className="modal-title">Delete canvas</div>
              <div className="modal-subtitle">This only removes the canvas container.</div>
            </div>
            <div className="modal-body col" style={{ gap: 8 }}>
              <strong>{activeCanvas.name}</strong>
              <span className="muted" style={{ fontSize: 12, lineHeight: 1.4 }}>
                This removes the canvas layout and memberships. Sessions are not deleted.
              </span>
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setDeleteConfirming(false)}>Cancel</button>
              <button className="danger" type="button" onClick={submitDelete}>Delete</button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

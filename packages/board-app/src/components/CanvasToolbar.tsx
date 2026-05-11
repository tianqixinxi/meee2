import { useState } from 'react'
import { Check, ChevronDown, Layers, Pencil, Plus } from 'lucide-react'
import type { CanvasInfo, CanvasScope } from '../types'

interface Props {
  canvases: CanvasInfo[]
  activeCanvasId: string
  onActiveCanvasChange: (canvasId: string) => void
  onCreateCanvas: (name: string, scope: CanvasScope) => Promise<void> | void
  onRenameCanvas: (canvasId: string, name: string) => Promise<void> | void
}

export function CanvasToolbar({
  canvases,
  activeCanvasId,
  onActiveCanvasChange,
  onCreateCanvas,
  onRenameCanvas,
}: Props) {
  const [menuOpen, setMenuOpen] = useState(false)
  const [creating, setCreating] = useState(false)
  const [renaming, setRenaming] = useState(false)
  const [canvasNameDraft, setCanvasNameDraft] = useState('')
  const [canvasScopeDraft, setCanvasScopeDraft] = useState<CanvasScope>('personal')

  const activeCanvas = canvases.find((canvas) => canvas.id === activeCanvasId) ?? canvases[0]

  const closePanels = () => {
    setCreating(false)
    setRenaming(false)
  }

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

  if (!activeCanvas) return null

  return (
    <div className="canvas-toolbar">
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
                    <span>{canvas.scope === 'team' ? 'Team' : 'Personal'}</span>
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
                setCreating((value) => !value)
                setRenaming(false)
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
              }}
            >
              <Pencil size={13} aria-hidden /> Rename
            </button>
          </div>
          {creating && (
            <div className="canvas-toolbar__form">
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
              <select
                value={canvasScopeDraft}
                onChange={(event) => setCanvasScopeDraft(event.target.value as CanvasScope)}
                aria-label="Canvas scope"
              >
                <option value="personal">Personal</option>
                <option value="team">Team</option>
              </select>
              <button type="button" onClick={submitCreate} disabled={!canvasNameDraft.trim()}>
                Create
              </button>
            </div>
          )}
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
              <button type="button" onClick={submitRename} disabled={!canvasNameDraft.trim()}>
                Save
              </button>
            </div>
          )}
        </div>
      )}

    </div>
  )
}

import { useMemo, useState } from 'react'
import { Check, ChevronDown, Layers, Pencil, Plus, Search } from 'lucide-react'
import type { CanvasInfo, CanvasScope, Session } from '../types'
import { Tooltip } from './Tooltip'

interface Props {
  canvases: CanvasInfo[]
  activeCanvasId: string
  sessions: Session[]
  canvasSessionIds: Set<string>
  onActiveCanvasChange: (canvasId: string) => void
  onCreateCanvas: (name: string, scope: CanvasScope) => Promise<void> | void
  onRenameCanvas: (canvasId: string, name: string) => Promise<void> | void
  onAddSession: (sessionId: string) => void
}

export function CanvasToolbar({
  canvases,
  activeCanvasId,
  sessions,
  canvasSessionIds,
  onActiveCanvasChange,
  onCreateCanvas,
  onRenameCanvas,
  onAddSession,
}: Props) {
  const [menuOpen, setMenuOpen] = useState(false)
  const [addOpen, setAddOpen] = useState(false)
  const [creating, setCreating] = useState(false)
  const [renaming, setRenaming] = useState(false)
  const [canvasNameDraft, setCanvasNameDraft] = useState('')
  const [canvasScopeDraft, setCanvasScopeDraft] = useState<CanvasScope>('personal')
  const [sessionQuery, setSessionQuery] = useState('')

  const activeCanvas = canvases.find((canvas) => canvas.id === activeCanvasId) ?? canvases[0]
  const availableSessions = useMemo(() => {
    const query = sessionQuery.trim().toLowerCase()
    return sessions
      .filter((session) => !canvasSessionIds.has(session.id))
      .filter((session) => {
        if (!query) return true
        return (
          session.title.toLowerCase().includes(query) ||
          session.project.toLowerCase().includes(query) ||
          session.pluginDisplayName.toLowerCase().includes(query)
        )
      })
  }, [canvasSessionIds, sessionQuery, sessions])

  const closePanels = () => {
    setCreating(false)
    setRenaming(false)
    setAddOpen(false)
    setSessionQuery('')
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
        <Tooltip label="Add sessions to this canvas">
          <button
            type="button"
            className="canvas-toolbar__icon"
            aria-label="Add sessions to this canvas"
            onClick={() => {
              setMenuOpen(false)
              setCreating(false)
              setRenaming(false)
              setAddOpen((value) => !value)
            }}
          >
            <Plus size={15} aria-hidden />
          </button>
        </Tooltip>
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

      {addOpen && (
        <div className="canvas-toolbar__panel canvas-toolbar__panel--sessions">
          <div className="canvas-toolbar__search">
            <Search size={13} aria-hidden />
            <input
              value={sessionQuery}
              onChange={(event) => setSessionQuery(event.target.value)}
              placeholder="Find sessions to add"
              autoFocus
            />
          </div>
          <div className="canvas-toolbar__session-list">
            {availableSessions.length === 0 ? (
              <div className="canvas-toolbar__empty">No sessions to add</div>
            ) : (
              availableSessions.slice(0, 12).map((session) => (
                <button
                  type="button"
                  key={session.id}
                  className="canvas-toolbar__session"
                  onClick={() => onAddSession(session.id)}
                >
                  <span>
                    <span>{session.title}</span>
                    <span>{session.pluginDisplayName}</span>
                  </span>
                  <Plus size={13} aria-hidden />
                </button>
              ))
            )}
          </div>
        </div>
      )}
    </div>
  )
}

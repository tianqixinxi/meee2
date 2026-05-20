import { useEffect, useRef, useState } from 'react'
import { Check, ChevronDown, Eraser, Globe2, Info, Layers, LockKeyhole, Plus, Search, Trash2 } from 'lucide-react'
import type { CanvasInfo, CanvasScope } from '../types'

interface Props {
  canvases: CanvasInfo[]
  activeCanvasId: string
  onActiveCanvasChange: (canvasId: string) => void
  onCreateCanvas: (name: string, scope: CanvasScope) => Promise<void> | void
  onRenameCanvas: (canvasId: string, name: string) => Promise<void> | void
  onClearCanvas?: (canvasId: string) => Promise<void> | void
  onDeleteCanvas: (canvasId: string) => Promise<void> | void
}

export function CanvasToolbar({
  canvases,
  activeCanvasId,
  onActiveCanvasChange,
  onCreateCanvas,
  onRenameCanvas,
  onClearCanvas,
  onDeleteCanvas,
}: Props) {
  const rootRef = useRef<HTMLDivElement | null>(null)
  const [menuOpen, setMenuOpen] = useState(false)
  const [creating, setCreating] = useState(false)
  const [clearConfirming, setClearConfirming] = useState(false)
  const [deleteConfirming, setDeleteConfirming] = useState(false)
  const [infoOpen, setInfoOpen] = useState(false)
  const [infoTab, setInfoTab] = useState<'overview' | 'settings' | 'danger'>('overview')
  const [canvasQuery, setCanvasQuery] = useState('')
  const [canvasNameDraft, setCanvasNameDraft] = useState('')
  const [canvasScopeDraft, setCanvasScopeDraft] = useState<CanvasScope>('personal')

  const activeCanvas = canvases.find((canvas) => canvas.id === activeCanvasId) ?? canvases[0]
  const filteredCanvases = canvases.filter((canvas) => {
    const query = canvasQuery.trim().toLowerCase()
    if (!query) return true
    return [canvas.name, canvas.id, visibilityLabel(canvas)]
      .some((value) => value.toLowerCase().includes(query))
  })

  const closePanels = () => {
    setCreating(false)
    setClearConfirming(false)
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
      setCanvasQuery('')
      setCreating(false)
      setMenuOpen(false)
    })
  }

  const submitRename = () => {
    const name = canvasNameDraft.trim()
    if (!activeCanvas || !name) return
    Promise.resolve(onRenameCanvas(activeCanvas.id, name)).then(() => {
      setCanvasNameDraft(name)
    })
  }

  const submitDelete = () => {
    if (!activeCanvas || activeCanvas.isDefault) return
    Promise.resolve(onDeleteCanvas(activeCanvas.id)).then(() => {
      setDeleteConfirming(false)
      setMenuOpen(false)
      setInfoOpen(false)
    })
  }

  const submitClear = () => {
    if (!activeCanvas || !onClearCanvas) return
    Promise.resolve(onClearCanvas(activeCanvas.id)).then(() => {
      setClearConfirming(false)
      setInfoOpen(false)
      setMenuOpen(false)
    })
  }

  if (!activeCanvas) return null

  return (
    <div className="canvas-toolbar" ref={rootRef}>
      <div className="canvas-toolbar__switcher">
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
          <span className="canvas-toolbar__switcher-label">Canvas</span>
          <span className="canvas-toolbar__switcher-current">{displayCanvasName(activeCanvas)}</span>
          <ChevronDown size={14} aria-hidden />
        </button>
        <button
          type="button"
          className="canvas-toolbar__info"
          aria-label="Canvas info"
          onClick={() => {
            closePanels()
            setMenuOpen(false)
            setCanvasNameDraft(activeCanvas.name)
            setInfoTab('overview')
            setInfoOpen(true)
          }}
        >
          <Info size={14} aria-hidden />
        </button>

        {menuOpen && (
          <div className="canvas-toolbar__panel">
            <label className="canvas-toolbar__search">
              <Search size={13} aria-hidden />
              <input
                value={canvasQuery}
                onChange={(event) => setCanvasQuery(event.target.value)}
                placeholder="Find canvas"
                autoFocus
              />
            </label>
            <div className="canvas-toolbar__list">
              {filteredCanvases.map((canvas) => {
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
                      <span>{displayCanvasName(canvas)}</span>
                      <span className={`canvas-toolbar__visibility canvas-toolbar__visibility--${visibilityLabel(canvas).toLowerCase()}`}>
                        {visibilityLabel(canvas) === 'Public' ? <Globe2 size={10} aria-hidden /> : <LockKeyhole size={10} aria-hidden />}
                        {visibilityLabel(canvas)}
                      </span>
                    </span>
                  </button>
                )
              })}
              {filteredCanvases.length === 0 && (
                <div className="canvas-toolbar__empty">No matching canvas</div>
              )}
            </div>
            <div className="canvas-toolbar__actions">
              <button
                type="button"
                onClick={() => {
                  setCanvasNameDraft('')
                  setCanvasScopeDraft('personal')
                  setDeleteConfirming(false)
                  setCreating(true)
                  setMenuOpen(false)
                }}
              >
                <Plus size={13} aria-hidden /> New private
              </button>
              <button
                type="button"
                onClick={() => {
                  setCanvasNameDraft('')
                  setCanvasScopeDraft('team')
                  setDeleteConfirming(false)
                  setCreating(true)
                  setMenuOpen(false)
                }}
              >
                <Plus size={13} aria-hidden /> New public
              </button>
            </div>
          </div>
        )}
      </div>

      {infoOpen && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setInfoOpen(false)
          }}
        >
          <div className="modal canvas-info-modal" role="dialog" aria-modal="true" aria-label="Canvas info">
            <div className="modal-header">
              <div className="modal-title">{displayCanvasName(activeCanvas)}</div>
              <div className="modal-subtitle">{visibilityLabel(activeCanvas)} planning canvas</div>
            </div>
            <div className="canvas-info-modal__tabs" role="tablist" aria-label="Canvas sections">
              {(['overview', 'settings', 'danger'] as const).map((tab) => (
                <button
                  key={tab}
                  type="button"
                  className={infoTab === tab ? 'is-active' : ''}
                  aria-selected={infoTab === tab}
                  onClick={() => setInfoTab(tab)}
                >
                  {tab === 'overview' ? 'Overview' : tab === 'settings' ? 'Settings' : 'Danger'}
                </button>
              ))}
            </div>
            <div className="modal-body col canvas-info-modal__body">
              {infoTab === 'overview' && (
                <>
                  <div className="canvas-info-modal__row">
                    <span>Visibility</span>
                    <strong>{visibilityLabel(activeCanvas)}</strong>
                  </div>
                  <div className="canvas-info-modal__row">
                    <span>Canvas ID</span>
                    <strong className="is-mono">{activeCanvas.id}</strong>
                  </div>
                  <p>
                    meee2 AI changes are scoped to this canvas. Sessions only appear after explicit binding.
                  </p>
                </>
              )}
              {infoTab === 'settings' && (
                <div className="canvas-info-modal__settings">
                  <label>
                    <span>Name</span>
                    <input
                      value={canvasNameDraft}
                      onChange={(event) => setCanvasNameDraft(event.target.value)}
                      onKeyDown={(event) => {
                        if (event.key === 'Enter') submitRename()
                        if (event.key === 'Escape') setCanvasNameDraft(activeCanvas.name)
                      }}
                      placeholder="Canvas name"
                    />
                  </label>
                  <button
                    type="button"
                    className="primary"
                    onClick={submitRename}
                    disabled={!canvasNameDraft.trim() || canvasNameDraft.trim() === activeCanvas.name}
                  >
                    Save name
                  </button>
                </div>
              )}
              {infoTab === 'danger' && (
                <>
                  {onClearCanvas && (
                    <div className="canvas-info-modal__danger">
                      <Eraser size={15} aria-hidden />
                      <div>
                        <strong>Clear this canvas</strong>
                        <p>Removes meee2 AI nodes, proposals, outputs, and local chat history. The canvas remains.</p>
                      </div>
                      <button
                        type="button"
                        className="danger"
                        title="Clear canvas content"
                        onClick={() => {
                          setInfoOpen(false)
                          setClearConfirming(true)
                        }}
                      >
                        Clear
                      </button>
                    </div>
                  )}
                  <div className="canvas-info-modal__danger">
                    <Trash2 size={15} aria-hidden />
                    <div>
                      <strong>Delete this canvas</strong>
                      <p>Sessions and local AI history are not deleted.</p>
                    </div>
                    <button
                      type="button"
                      className="danger"
                      disabled={activeCanvas.isDefault}
                      title={activeCanvas.isDefault ? 'This canvas cannot be deleted.' : 'Delete canvas'}
                      onClick={() => {
                        setInfoOpen(false)
                        setDeleteConfirming(true)
                      }}
                    >
                      Delete
                    </button>
                  </div>
                </>
              )}
            </div>
            <div className="modal-footer">
              <button className="primary" type="button" onClick={() => setInfoOpen(false)}>Done</button>
            </div>
          </div>
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
              <div className="modal-title">New canvas</div>
              <div className="modal-subtitle">Choose who can view this planning space.</div>
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
              <div className="canvas-toolbar__scope-toggle" role="group" aria-label="Canvas visibility">
                {(['personal', 'team'] as CanvasScope[]).map((scope) => (
                  <button
                    key={scope}
                    type="button"
                    className={canvasScopeDraft === scope ? 'is-selected' : ''}
                    aria-pressed={canvasScopeDraft === scope}
                    onClick={() => setCanvasScopeDraft(scope)}
                  >
                    {scope === 'team' ? 'Public' : 'Private'}
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
      {clearConfirming && (
        <div
          className="modal-backdrop"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setClearConfirming(false)
          }}
        >
          <div className="modal canvas-confirm-modal" role="dialog" aria-modal="true" aria-label="Clear canvas">
            <div className="modal-header">
              <div className="modal-title">Clear canvas</div>
              <div className="modal-subtitle">This keeps the canvas but removes its meee2 AI graph.</div>
            </div>
            <div className="modal-body col" style={{ gap: 8 }}>
              <strong>{activeCanvas.name}</strong>
              <span className="muted" style={{ fontSize: 12, lineHeight: 1.4 }}>
                Nodes, pending proposals, outputs, runs, and local meee2 AI chat history for this canvas will be removed. Sessions are not deleted.
              </span>
            </div>
            <div className="modal-footer">
              <button className="ghost" type="button" onClick={() => setClearConfirming(false)}>Cancel</button>
              <button className="danger" type="button" onClick={submitClear}>Clear</button>
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

function visibilityLabel(canvas: CanvasInfo): 'Private' | 'Public' {
  return canvas.scope === 'team' ? 'Public' : 'Private'
}

function displayCanvasName(canvas: CanvasInfo): string {
  return canvas.name === 'Default canvas' ? 'My' : canvas.name
}

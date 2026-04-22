// Sidebar panel for editing a plugin's card template.
//
// Behavior:
//  - Loads the template for `pluginId` on mount (or when pluginId changes).
//    If the backend has no entry, we start with DEFAULT_TEMPLATE.
//  - Debounced 600ms auto-save (PUT /api/card-templates/:id) after edits,
//    PLUS explicit Apply button.
//  - The parent owns template cache; on save we call `onSaved(id, source)`
//    so cached state + live CardHost iframes update without waiting for the
//    WS roundtrip.
//  - Reset → DELETE on backend + bring back the built-in default.

import { useEffect, useMemo, useRef, useState } from 'react'
import { compileCardSource } from '../cardCompile'
import { DEFAULT_TEMPLATE } from '../defaultTemplate'
import { TEMPLATE_PRESETS } from '../templatePresets'
import {
  deleteTemplate,
  getTemplate,
  putTemplate,
  templateIdForPlugin,
} from '../cardTemplateStore'

interface Props {
  pluginId: string
  pluginDisplayName: string
  /** Called whenever the local source changes — parent broadcasts to CardHosts. */
  onSaved: (templateId: string, source: string) => void
}

type Status = 'idle' | 'loading' | 'saving' | 'saved' | 'error'

export default function TemplateEditor({
  pluginId,
  pluginDisplayName,
  onSaved,
}: Props) {
  const templateId = useMemo(() => templateIdForPlugin(pluginId), [pluginId])

  const [source, setSource] = useState<string>(DEFAULT_TEMPLATE)
  const [loaded, setLoaded] = useState<string>(DEFAULT_TEMPLATE) // last persisted value
  const [status, setStatus] = useState<Status>('loading')
  const [errorMsg, setErrorMsg] = useState<string | null>(null)

  // Compile locally so we can surface parse errors next to the textarea
  // before the iframe ever sees the code.
  const compileError = useMemo(() => {
    const r = compileCardSource(source)
    return r.error ?? null
  }, [source])

  // -- load on mount / id change ----------------------------------------
  useEffect(() => {
    let cancelled = false
    setStatus('loading')
    setErrorMsg(null)
    getTemplate(templateId)
      .then((entry) => {
        if (cancelled) return
        const text = entry?.source ?? DEFAULT_TEMPLATE
        setSource(text)
        setLoaded(text)
        setStatus('idle')
        // Let parent seed its cache too so any already-mounted CardHost picks
        // up the persisted (possibly customized) template immediately.
        onSaved(templateId, text)
      })
      .catch((e) => {
        if (cancelled) return
        setErrorMsg((e as Error).message)
        setStatus('error')
      })
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [templateId])

  // -- debounced auto-save ----------------------------------------------
  const saveTimerRef = useRef<number | null>(null)
  useEffect(() => {
    if (status === 'loading') return
    if (source === loaded) return

    if (saveTimerRef.current) window.clearTimeout(saveTimerRef.current)
    setStatus('saving')
    saveTimerRef.current = window.setTimeout(async () => {
      try {
        await putTemplate(templateId, source)
        setLoaded(source)
        setStatus('saved')
        setErrorMsg(null)
        onSaved(templateId, source)
        // Fade the "saved" indicator after a beat.
        window.setTimeout(() => {
          setStatus((cur) => (cur === 'saved' ? 'idle' : cur))
        }, 1200)
      } catch (e) {
        setErrorMsg((e as Error).message)
        setStatus('error')
      }
    }, 600)

    return () => {
      if (saveTimerRef.current) window.clearTimeout(saveTimerRef.current)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [source, templateId])

  const applyNow = async () => {
    if (saveTimerRef.current) window.clearTimeout(saveTimerRef.current)
    setStatus('saving')
    try {
      await putTemplate(templateId, source)
      setLoaded(source)
      onSaved(templateId, source)
      setStatus('saved')
      setErrorMsg(null)
    } catch (e) {
      setErrorMsg((e as Error).message)
      setStatus('error')
    }
  }

  const resetDefault = async () => {
    setStatus('saving')
    try {
      await deleteTemplate(templateId)
    } catch (e) {
      // Non-fatal — maybe it was never persisted. We still reset the local copy.
      console.warn('[TemplateEditor] delete failed (ignored):', (e as Error).message)
    }
    setSource(DEFAULT_TEMPLATE)
    setLoaded(DEFAULT_TEMPLATE)
    onSaved(templateId, DEFAULT_TEMPLATE)
    setStatus('idle')
    setErrorMsg(null)
  }

  const dirty = source !== loaded
  const statusText =
    status === 'loading'
      ? 'loading…'
      : status === 'saving'
      ? 'saving…'
      : status === 'saved'
      ? 'saved'
      : status === 'error'
      ? `error: ${errorMsg ?? 'unknown'}`
      : dirty
      ? 'unsaved'
      : 'synced'

  const statusColor =
    status === 'error'
      ? 'var(--danger)'
      : dirty || status === 'saving'
      ? 'var(--warning)'
      : 'var(--success)'

  return (
    <div className="col" style={{ gap: 8, minWidth: 0 }}>
      <div className="row space" style={{ alignItems: 'baseline' }}>
        <div>
          <div style={{ fontWeight: 600 }}>Template · {pluginDisplayName}</div>
          <div className="muted mono" style={{ fontSize: 10 }}>
            {templateId}
          </div>
        </div>
        <span
          className="mono"
          style={{ fontSize: 10, color: statusColor }}
          title={`Template status: ${statusText}`}
        >
          {dirty ? '● ' : ''}
          {statusText}
        </span>
      </div>

      <textarea
        value={source}
        spellCheck={false}
        onChange={(e) => setSource(e.target.value)}
        style={{
          width: '100%',
          height: 400,
          minHeight: 260,
          resize: 'vertical',
          fontFamily: 'var(--mono)',
          fontSize: 11,
          lineHeight: 1.45,
          padding: 8,
          whiteSpace: 'pre',
          overflow: 'auto',
          tabSize: 2,
        }}
      />

      {compileError && (
        <div
          style={{
            background: '#1e0e0e',
            color: 'var(--danger)',
            padding: 8,
            borderRadius: 4,
            fontFamily: 'var(--mono)',
            fontSize: 11,
            whiteSpace: 'pre-wrap',
            maxHeight: 180,
            overflow: 'auto',
            border: '1px solid #5a1f1f',
          }}
        >
          {compileError}
        </div>
      )}

      <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
        <button
          className="primary"
          onClick={applyNow}
          disabled={status === 'loading' || (!dirty && status !== 'error')}
          title="Save & broadcast now (bypasses the 600ms debounce)"
        >
          Apply
        </button>
        <button
          onClick={resetDefault}
          disabled={status === 'loading'}
          title="Delete any persisted override and restore the built-in template"
        >
          Reset to default
        </button>
      </div>

      {/* Preset picker — click to load preset source into the editor */}
      <div className="col" style={{ gap: 4 }}>
        <div className="muted" style={{ fontSize: 10, textTransform: 'uppercase', letterSpacing: 0.6 }}>
          Presets
        </div>
        <div className="row" style={{ gap: 4, flexWrap: 'wrap' }}>
          {TEMPLATE_PRESETS.map((preset) => (
            <button
              key={preset.id}
              onClick={() => {
                console.log(
                  '[TemplateEditor] preset click id=%s templateId=%s srcLen=%d firstLine=%s',
                  preset.id,
                  templateId,
                  preset.source.length,
                  preset.source.split('\n', 1)[0]?.slice(0, 60),
                )
                setSource(preset.source)
                setStatus('saving')
                setErrorMsg(null)
                // 立即推给 App.templateCache → Board → SessionOverlay → CardHost
                onSaved(templateId, preset.source)
                if (saveTimerRef.current) window.clearTimeout(saveTimerRef.current)
                void putTemplate(templateId, preset.source)
                  .then(() => {
                    console.log('[TemplateEditor] putTemplate OK', templateId)
                    setLoaded(preset.source)
                    setStatus('saved')
                    window.setTimeout(() => {
                      setStatus((cur) => (cur === 'saved' ? 'idle' : cur))
                    }, 1200)
                  })
                  .catch((e) => {
                    console.warn('[TemplateEditor] putTemplate FAIL', templateId, e)
                    setStatus('error')
                    setErrorMsg((e as Error).message)
                  })
              }}
              title={preset.description}
              style={{
                fontSize: 11,
                padding: '3px 8px',
                background: source === preset.source ? 'var(--accent)' : 'var(--bg-elevated-2)',
                color: source === preset.source ? '#000' : undefined,
                fontWeight: source === preset.source ? 600 : 400,
              }}
            >
              {preset.label}
            </button>
          ))}
        </div>
      </div>

      <div className="muted" style={{ fontSize: 11, lineHeight: 1.4 }}>
        Edit the React component, auto-saves after 600ms. The compiled code runs
        in a sandboxed iframe (no access to the parent DOM). Props:{' '}
        <code className="mono">{'{ session, board, helpers }'}</code>.
      </div>
    </div>
  )
}

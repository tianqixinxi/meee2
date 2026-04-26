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
  templateIdForSession,
} from '../cardTemplateStore'
import { TemplateGallery } from './TemplateGallery'
import { CustomCardModal } from './CustomCardModal'
import { loadUserPresets } from '../userPresets'

interface Props {
  sessionId: string
  pluginDisplayName: string
  /** Called whenever the local source changes — parent broadcasts to CardHosts. */
  onSaved: (templateId: string, source: string) => void
}

type Status = 'idle' | 'loading' | 'saving' | 'saved' | 'error'

export default function TemplateEditor({
  sessionId,
  pluginDisplayName,
  onSaved,
}: Props) {
  const templateId = useMemo(() => templateIdForSession(sessionId), [sessionId])

  const [source, setSource] = useState<string>(DEFAULT_TEMPLATE)
  const [loaded, setLoaded] = useState<string>(DEFAULT_TEMPLATE) // last persisted value
  const [status, setStatus] = useState<Status>('loading')
  const [errorMsg, setErrorMsg] = useState<string | null>(null)
  // Custom-card 模态框可见性 + 用户自建 preset 列表（localStorage）
  const [customModalOpen, setCustomModalOpen] = useState(false)
  const [userPresets, setUserPresets] = useState(() => loadUserPresets())

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

      {/* Preset 预览网格 —— 点任意 tile 把源码灌进 editor + 直接应用。
          以前是一排文字按钮，看不到每个 preset 长什么样；现在每个 tile 是
          活渲染的 mini card（同一份 fake session 喂数据，风格对比直观）。 */}
      <div className="col" style={{ gap: 6 }}>
        <div className="muted" style={{ fontSize: 10, textTransform: 'uppercase', letterSpacing: 0.6 }}>
          Presets
        </div>
        <TemplateGallery
          presets={[...TEMPLATE_PRESETS, ...userPresets]}
          selectedId={
            [...TEMPLATE_PRESETS, ...userPresets].find((p) => p.source === source)?.id ?? null
          }
          onRequestCustom={() => setCustomModalOpen(true)}
          onSelect={(preset) => {
            console.log(
              '[TemplateEditor] preset click id=%s templateId=%s srcLen=%d',
              preset.id,
              templateId,
              preset.source.length,
            )
            setSource(preset.source)
            setStatus('saving')
            setErrorMsg(null)
            onSaved(templateId, preset.source)
            if (saveTimerRef.current) window.clearTimeout(saveTimerRef.current)
            void putTemplate(templateId, preset.source)
              .then(() => {
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
        />
      </div>

      <div className="muted" style={{ fontSize: 11, lineHeight: 1.4 }}>
        Edit the React component, auto-saves after 600ms. The compiled code runs
        in a sandboxed iframe (no access to the parent DOM). Props:{' '}
        <code className="mono">{'{ session, board, helpers }'}</code>.
      </div>

      {customModalOpen && (
        <CustomCardModal
          onClose={() => setCustomModalOpen(false)}
          onSaved={(preset) => {
            // 刷新 user preset 列表（localStorage 已经更新过了）
            setUserPresets(loadUserPresets())
            // 立即 apply 新 preset 到当前 session —— 用户刚写完八成就想试
            setSource(preset.source)
            onSaved(templateId, preset.source)
            if (saveTimerRef.current) window.clearTimeout(saveTimerRef.current)
            setStatus('saving')
            void putTemplate(templateId, preset.source)
              .then(() => {
                setLoaded(preset.source)
                setStatus('saved')
                window.setTimeout(() => {
                  setStatus((cur) => (cur === 'saved' ? 'idle' : cur))
                }, 1200)
              })
              .catch((e) => {
                setStatus('error')
                setErrorMsg((e as Error).message)
              })
          }}
        />
      )}
    </div>
  )
}

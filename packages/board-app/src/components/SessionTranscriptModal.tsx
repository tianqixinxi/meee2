import { FileJson, Loader2, X } from 'lucide-react'
import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import {
  fetchTranscript,
  syncNativeSessionsWorkspace,
  type TranscriptBlock,
  type TranscriptEntryFull,
} from '../api'
import { useI18n } from '../lib/i18n'

interface SessionTranscriptModalProps {
  sessionId: string
  title: string
  onClose: () => void
}

export function SessionTranscriptModal({ sessionId, title, onClose }: SessionTranscriptModalProps) {
  const { t } = useI18n()
  const [entries, setEntries] = useState<TranscriptEntryFull[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(false)

  useEffect(() => {
    syncNativeSessionsWorkspace({
      phase: 'obscure',
      mode: 'terminal',
      webPhase: 'sessionTranscriptModal.obscureNativeTerminal',
    })
    return () => {
      window.dispatchEvent(new Event('meee2:restore-native-sessions-workspace'))
      window.dispatchEvent(new Event('meee2:layout-native-sessions-workspace'))
    }
  }, [])

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    setError(false)
    void fetchTranscript(sessionId, { limit: 100 })
      .then((result) => {
        if (!cancelled) setEntries(result.entries)
      })
      .catch(() => {
        if (!cancelled) setError(true)
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [sessionId])

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [onClose])

  return createPortal(
    <div className="session-transcript-modal-backdrop" role="presentation" onClick={onClose}>
      <section
        className="session-transcript-modal"
        role="dialog"
        aria-modal="true"
        aria-label={t('sessions.context.transcriptFor', { title })}
        onClick={(event) => event.stopPropagation()}
      >
        <header>
          <div>
            <FileJson size={15} aria-hidden />
            <strong>{t('sessions.context.transcript')}</strong>
            <span>{title}</span>
          </div>
          <button type="button" onClick={onClose} aria-label={t('common.close')}>
            <X size={15} aria-hidden />
          </button>
        </header>
        <div className="session-transcript-modal__body">
          {loading ? (
            <div className="session-transcript-modal__state" role="status">
              <Loader2 size={15} className="spin" aria-hidden />
              <span>{t('common.loading')}</span>
            </div>
          ) : error ? (
            <div className="session-transcript-modal__state is-error" role="alert">
              {t('sessions.context.transcriptLoadFailed')}
            </div>
          ) : entries.length === 0 ? (
            <div className="session-transcript-modal__state">{t('sessions.context.noTranscript')}</div>
          ) : (
            <div className="session-transcript-modal__entries">
              {entries.map((entry) => <TranscriptEntryView key={entry.id} entry={entry} />)}
            </div>
          )}
        </div>
      </section>
    </div>,
    document.body,
  )
}

function TranscriptEntryView({ entry }: { entry: TranscriptEntryFull }) {
  return (
    <article className={`session-transcript-entry is-${entry.type}`}>
      <header>
        <strong>{entry.type}</strong>
        {entry.timestamp ? <time>{formatTimestamp(entry.timestamp)}</time> : null}
      </header>
      <div>
        {entry.blocks.map((block, index) => (
          <TranscriptBlockView key={`${block.type}-${block.toolId ?? block.toolUseId ?? index}`} block={block} />
        ))}
      </div>
    </article>
  )
}

function TranscriptBlockView({ block }: { block: TranscriptBlock }) {
  const { t } = useI18n()
  if (block.type === 'text') return block.text ? <p>{block.text}</p> : null
  if (block.type === 'thinking') {
    return block.text ? (
      <details>
        <summary>{t('sessions.context.thinking')}</summary>
        <p>{block.text}</p>
      </details>
    ) : null
  }
  if (block.type === 'tool_use') {
    return (
      <details>
        <summary>{block.toolName || t('sessions.context.toolCall')}</summary>
        {block.toolInputJSON ? <pre>{block.toolInputJSON}</pre> : null}
      </details>
    )
  }
  return (
    <details>
      <summary>{t('sessions.context.toolResult')}</summary>
      {block.toolResultText ? <pre>{block.toolResultText}</pre> : null}
    </details>
  )
}

function formatTimestamp(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

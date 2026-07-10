import { useEffect, useRef } from 'react'
import type { TranslationKey } from '../lib/i18n'

interface LegacyMessageCleanupConfirmModalProps {
  t: (key: TranslationKey, params?: Record<string, string | number>) => string
  messageCount: number
  messageBytes: string
  acknowledged: boolean
  cleaning: boolean
  onToggleAcknowledged: (value: boolean) => void
  onCancel: () => void
  onConfirm: () => void
}

export function LegacyMessageCleanupConfirmModal({
  t,
  messageCount,
  messageBytes,
  acknowledged,
  cleaning,
  onToggleAcknowledged,
  onCancel,
  onConfirm,
}: LegacyMessageCleanupConfirmModalProps) {
  const dialogRef = useRef<HTMLDivElement | null>(null)
  const cancelButtonRef = useRef<HTMLButtonElement | null>(null)
  const onCancelRef = useRef(onCancel)
  const cleaningRef = useRef(cleaning)

  useEffect(() => {
    onCancelRef.current = onCancel
    cleaningRef.current = cleaning
  }, [cleaning, onCancel])

  useEffect(() => {
    const previouslyFocused = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null
    cancelButtonRef.current?.focus()

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !cleaningRef.current) {
        event.preventDefault()
        onCancelRef.current()
        return
      }
      if (event.key !== 'Tab') return
      const dialog = dialogRef.current
      if (!dialog) return
      const focusable = Array.from(dialog.querySelectorAll<HTMLElement>(
        'button:not([disabled]), input:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ))
      if (focusable.length === 0) {
        event.preventDefault()
        dialog.focus()
        return
      }
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }

    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
      previouslyFocused?.focus()
    }
  }, [])

  return (
    <div
      className="legacy-cleanup-modal__backdrop"
      role="presentation"
      onClick={(event) => {
        if (event.target === event.currentTarget && !cleaning) onCancel()
      }}
    >
      <div
        ref={dialogRef}
        className="settings-panel legacy-cleanup-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="legacy-cleanup-confirm-title"
        aria-describedby="legacy-cleanup-confirm-body"
        tabIndex={-1}
      >
        <h2 id="legacy-cleanup-confirm-title">
          {t('settings.privacyLegacyCleanupConfirmTitle')}
        </h2>
        <p id="legacy-cleanup-confirm-body">
          {t('settings.privacyLegacyCleanupConfirmBody', {
            count: messageCount,
            bytes: messageBytes,
          })}
        </p>
        <p className="muted legacy-cleanup-modal__backup-note">
          {t('settings.privacyLegacyCleanupBackupNote')}
        </p>
        <label className="settings-toggle-row legacy-cleanup-modal__acknowledgement">
          <span>
            <strong>{t('settings.privacyLegacyCleanupConfirmAck')}</strong>
          </span>
          <input
            type="checkbox"
            checked={acknowledged}
            onChange={(event) => onToggleAcknowledged(event.target.checked)}
          />
        </label>
        <div className="row legacy-cleanup-modal__actions">
          <button
            ref={cancelButtonRef}
            type="button"
            className="ghost"
            onClick={onCancel}
            disabled={cleaning}
          >
            {t('common.cancel')}
          </button>
          <button
            type="button"
            className="primary"
            onClick={onConfirm}
            disabled={!acknowledged || cleaning}
          >
            {cleaning
              ? t('settings.privacyLegacyCleanupRunning')
              : t('settings.privacyLegacyCleanupConfirmAction')}
          </button>
        </div>
      </div>
    </div>
  )
}

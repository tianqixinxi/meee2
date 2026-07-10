import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { TranslationKey } from '../lib/i18n'
import { LegacyMessageCleanupConfirmModal } from './LegacyMessageCleanupConfirmModal'

const labels: Partial<Record<TranslationKey, string>> = {
  'settings.privacyLegacyCleanupConfirmTitle': 'Back up and clean legacy messages?',
  'settings.privacyLegacyCleanupConfirmBody': '2 messages (4 KB) will be cleaned.',
  'settings.privacyLegacyCleanupBackupNote': 'A verified backup is created first.',
  'settings.privacyLegacyCleanupConfirmAck': 'I understand the exact scope.',
  'settings.privacyLegacyCleanupRunning': 'Backing up and cleaning…',
  'settings.privacyLegacyCleanupConfirmAction': 'Back up and clean',
  'common.cancel': 'Cancel',
}

const t = (key: TranslationKey) => labels[key] ?? key

describe('LegacyMessageCleanupConfirmModal', () => {
  it('requires acknowledgement before confirmation and restores focus on cancel', () => {
    const onCancel = vi.fn()
    const onConfirm = vi.fn()
    const trigger = document.createElement('button')
    document.body.appendChild(trigger)
    trigger.focus()

    const view = render(
      <LegacyMessageCleanupConfirmModal
        t={t}
        messageCount={2}
        messageBytes="4 KB"
        acknowledged={false}
        cleaning={false}
        onToggleAcknowledged={vi.fn()}
        onCancel={onCancel}
        onConfirm={onConfirm}
      />,
    )

    expect(screen.getByRole('button', { name: 'Back up and clean' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Cancel' })).toHaveFocus()
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(onCancel).toHaveBeenCalledTimes(1)
    view.unmount()
    expect(trigger).toHaveFocus()
    trigger.remove()
  })

  it('submits only after acknowledgement and cannot close while cleanup is running', () => {
    const onCancel = vi.fn()
    const onConfirm = vi.fn()
    const { rerender } = render(
      <LegacyMessageCleanupConfirmModal
        t={t}
        messageCount={2}
        messageBytes="4 KB"
        acknowledged
        cleaning={false}
        onToggleAcknowledged={vi.fn()}
        onCancel={onCancel}
        onConfirm={onConfirm}
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: 'Back up and clean' }))
    expect(onConfirm).toHaveBeenCalledTimes(1)

    rerender(
      <LegacyMessageCleanupConfirmModal
        t={t}
        messageCount={2}
        messageBytes="4 KB"
        acknowledged
        cleaning
        onToggleAcknowledged={vi.fn()}
        onCancel={onCancel}
        onConfirm={onConfirm}
      />,
    )
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(onCancel).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: 'Backing up and cleaning…' })).toBeDisabled()
  })
})

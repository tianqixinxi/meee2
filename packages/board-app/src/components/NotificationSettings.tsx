import { useEffect, useState } from 'react'
import {
  DEFAULT_NOTIFICATION_TOGGLES,
  NOTIFICATION_TRIGGER_KINDS,
  ensureNotificationPermission,
  loadNotificationToggles,
  notificationsSupported,
  saveNotificationToggles,
  type NotificationToggles,
  type NotificationTriggerKind,
} from '../notifications'

// Chunk D (release plan QC P1): user-facing toggles for the five OS
// notification kinds. Kept layout-agnostic so SettingsView can drop it into
// any <section>.

const LABELS: Record<NotificationTriggerKind, { title: string; help: string }> = {
  'permission-request': {
    title: 'Permission requests',
    help: 'Notify when a session needs you to approve a tool call.',
  },
  'session-blocked': {
    title: 'Session blocked',
    help: 'Notify when a session fails, dies, or times out.',
  },
  'session-done': {
    title: 'Session finished',
    help: 'Notify when a session reaches a terminal done state. Noisy — off by default.',
  },
  'approval-needed': {
    title: 'Planner approvals',
    help: 'Notify when a planner node enters gate-wait and has approvers assigned.',
  },
  'recap-updated': {
    title: 'Recap updated',
    help: 'Notify when a canvas recap is refreshed. Noisy — off by default.',
  },
}

export function NotificationSettings({
  onToast,
}: {
  onToast?: (kind: 'info' | 'error' | 'success', text: string) => void
}) {
  const [toggles, setToggles] = useState<NotificationToggles>(() => loadNotificationToggles())
  const [permission, setPermission] = useState<NotificationPermission | 'unsupported'>(() => {
    if (typeof window === 'undefined' || typeof window.Notification === 'undefined') return 'unsupported'
    return Notification.permission
  })
  const supported = notificationsSupported()

  useEffect(() => {
    saveNotificationToggles(toggles)
  }, [toggles])

  const update = (kind: NotificationTriggerKind, on: boolean) => {
    setToggles((t) => ({ ...t, [kind]: on }))
  }

  const requestPermission = async () => {
    const next = await ensureNotificationPermission()
    setPermission(next)
    if (next === 'granted') onToast?.('success', 'Notifications enabled.')
    else if (next === 'denied') onToast?.('error', 'Notifications denied. Enable them in System Settings.')
  }

  const resetDefaults = () => setToggles({ ...DEFAULT_NOTIFICATION_TOGGLES })

  return (
    <section className="settings-section" aria-label="Notifications">
      <div className="settings-section-header">
        <div>
          <div className="settings-section-title">Notifications</div>
          <div className="settings-section-caption">
            macOS system notifications for session and planner events.
          </div>
        </div>
        <button type="button" className="ghost" onClick={resetDefaults}>Reset</button>
      </div>

      <div className="settings-panel" style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
        <div className="row" style={{ justifyContent: 'space-between', alignItems: 'center' }}>
          <div className="col" style={{ gap: 2 }}>
            <strong>Permission status</strong>
            <small className="muted">
              {!supported && 'Notification API is unavailable in this WebView.'}
              {supported && permission === 'granted' && 'Notifications are allowed.'}
              {supported && permission === 'denied' && 'Blocked — enable in macOS System Settings → Notifications.'}
              {supported && permission === 'default' && 'Not yet asked. Click Allow to enable.'}
            </small>
          </div>
          {supported && permission !== 'granted' && (
            <button type="button" className="primary" onClick={() => void requestPermission()}>
              Allow
            </button>
          )}
        </div>
      </div>

      {NOTIFICATION_TRIGGER_KINDS.map((kind) => (
        <label key={kind} className="settings-toggle-row settings-panel">
          <span>
            <strong>{LABELS[kind].title}</strong>
            <small>{LABELS[kind].help}</small>
          </span>
          <input
            type="checkbox"
            checked={toggles[kind]}
            disabled={!supported}
            onChange={(e) => update(kind, e.target.checked)}
          />
        </label>
      ))}
    </section>
  )
}

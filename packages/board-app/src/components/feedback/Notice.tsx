import type { ReactNode } from 'react'
import { AlertCircle, CheckCircle2, Info, X } from 'lucide-react'

export type NoticeTone = 'info' | 'success' | 'warning' | 'danger'
export type NoticePlacement = 'inline' | 'panel' | 'canvas'

interface Props {
  tone?: NoticeTone
  placement?: NoticePlacement
  title?: ReactNode
  children: ReactNode
  icon?: ReactNode
  action?: ReactNode
  onDismiss?: () => void
  className?: string
}

export function Notice({
  tone = 'info',
  placement = 'inline',
  title,
  children,
  icon,
  action,
  onDismiss,
  className,
}: Props) {
  const classes = [
    'notice',
    `notice--${tone}`,
    `notice--${placement}`,
    className,
  ].filter(Boolean).join(' ')

  return (
    <div className={classes} role={tone === 'danger' ? 'alert' : 'status'}>
      <div className="notice__icon" aria-hidden>
        {icon ?? defaultIcon(tone)}
      </div>
      <div className="notice__copy">
        {title && <strong>{title}</strong>}
        <div>{children}</div>
      </div>
      {action && <div className="notice__action">{action}</div>}
      {onDismiss && (
        <button type="button" className="notice__dismiss" onClick={onDismiss} aria-label="Dismiss notice">
          <X size={12} aria-hidden />
        </button>
      )}
    </div>
  )
}

function defaultIcon(tone: NoticeTone) {
  switch (tone) {
    case 'success':
      return <CheckCircle2 size={15} />
    case 'warning':
    case 'danger':
      return <AlertCircle size={15} />
    case 'info':
      return <Info size={15} />
  }
}

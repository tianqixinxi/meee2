export interface ToastMessage {
  id: number
  kind: 'info' | 'error' | 'success'
  text: string
}

interface Props {
  toasts: ToastMessage[]
}

export function ToastViewport({ toasts }: Props) {
  if (toasts.length === 0) return null
  return (
    <div className="toast-viewport" aria-live="polite" aria-label="Notifications">
      {toasts.map((toast) => (
        <div key={toast.id} className={`toast toast--${toast.kind}`} role="status">
          {toast.text}
        </div>
      ))}
    </div>
  )
}

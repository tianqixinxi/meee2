import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { ToastViewport } from './ToastViewport'

describe('ToastViewport', () => {
  it('does not render an outlet when there are no toasts', () => {
    const { container } = render(<ToastViewport toasts={[]} />)

    expect(container.firstChild).toBeNull()
  })

  it('renders all ephemeral toast messages in one live region', () => {
    render(
      <ToastViewport
        toasts={[
          { id: 1, kind: 'success', text: 'Saved' },
          { id: 2, kind: 'error', text: 'Failed' },
        ]}
      />,
    )

    expect(screen.getByLabelText('Notifications')).toHaveClass('toast-viewport')
    expect(screen.getByText('Saved')).toHaveClass('toast', 'toast--success')
    expect(screen.getByText('Failed')).toHaveClass('toast', 'toast--error')
  })
})

import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { Notice } from './Notice'

describe('Notice', () => {
  it('renders persistent non-blocking feedback with tone and placement classes', () => {
    render(
      <Notice tone="warning" placement="canvas" title="Setup needed">
        Runtime is missing.
      </Notice>,
    )

    const notice = screen.getByRole('status')
    expect(notice).toHaveClass('notice', 'notice--warning', 'notice--canvas')
    expect(screen.getByText('Setup needed')).toBeInTheDocument()
    expect(screen.getByText('Runtime is missing.')).toBeInTheDocument()
  })

  it('uses alert semantics for danger notices', () => {
    render(
      <Notice tone="danger">
        Unable to write artifact.
      </Notice>,
    )

    expect(screen.getByRole('alert')).toHaveTextContent('Unable to write artifact.')
  })

  it('renders action and dismiss affordances without owning dialog behavior', () => {
    const onDismiss = vi.fn()
    render(
      <Notice
        action={<button type="button">Open Settings</button>}
        onDismiss={onDismiss}
      >
        Provider setup is incomplete.
      </Notice>,
    )

    expect(screen.getByRole('button', { name: 'Open Settings' })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Dismiss notice' }))
    expect(onDismiss).toHaveBeenCalledTimes(1)
  })
})

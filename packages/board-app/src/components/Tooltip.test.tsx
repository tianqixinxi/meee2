import { act, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Tooltip } from './Tooltip'

describe('Tooltip', () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it('shows a fast tooltip in a body portal', () => {
    vi.useFakeTimers()
    render(
      <Tooltip label="Permission required" placement="top" delay={120}>
        <div>Need attention</div>
      </Tooltip>,
    )

    fireEvent.mouseEnter(screen.getByText('Need attention'))
    act(() => vi.advanceTimersByTime(119))
    expect(screen.queryByRole('tooltip')).not.toBeInTheDocument()

    act(() => vi.advanceTimersByTime(1))
    const tooltip = screen.getByRole('tooltip')
    expect(tooltip).toHaveTextContent('Permission required')
    expect(tooltip.parentElement).toBe(document.body)
  })
})

import { act, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { requestBoardGuide } from '../lib/guide'
import { GuideOverlay } from './GuideOverlay'

describe('GuideOverlay', () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it('shows only a two-second spotlight without a tooltip', () => {
    vi.useFakeTimers()
    render(
      <>
        <div data-testid="guide-target" />
        <GuideOverlay />
      </>,
    )
    vi.spyOn(screen.getByTestId('guide-target'), 'getBoundingClientRect').mockReturnValue(
      new DOMRect(40, 60, 160, 90),
    )

    act(() => {
      requestBoardGuide({
        kind: 'selector',
        selector: '[data-testid="guide-target"]',
        title: 'Needs attention',
        body: 'This content should not render as a tooltip.',
        durationMs: 8000,
      })
    })

    expect(document.querySelector('.guide-overlay__ring')).toBeInTheDocument()
    expect(screen.queryByText('Needs attention')).not.toBeInTheDocument()
    expect(screen.queryByText('This content should not render as a tooltip.')).not.toBeInTheDocument()

    act(() => vi.advanceTimersByTime(1999))
    expect(document.querySelector('.guide-overlay__ring')).toBeInTheDocument()

    act(() => vi.advanceTimersByTime(1))
    expect(document.querySelector('.guide-overlay')).not.toBeInTheDocument()
  })
})

import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import { SessionTranscriptModal } from './SessionTranscriptModal'

const api = vi.hoisted(() => ({
  fetchTranscript: vi.fn(),
  syncNativeSessionsWorkspace: vi.fn(),
}))

vi.mock('../api', () => api)

describe('SessionTranscriptModal', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    localStorage.setItem('meee2.locale', 'zh-CN')
    api.fetchTranscript.mockResolvedValue({
      sessionId: 'session-a',
      entries: [
        {
          id: 'entry-user',
          type: 'user',
          timestamp: '2026-07-21T00:00:00Z',
          blocks: [{ type: 'text', text: '把右侧做得更有用' }],
        },
        {
          id: 'entry-assistant',
          type: 'assistant',
          timestamp: '2026-07-21T00:01:00Z',
          blocks: [
            { type: 'text', text: '正在实现 Session Context' },
            { type: 'tool_use', toolId: 'tool-1', toolName: 'Read', toolInputJSON: '{"path":"App.tsx"}' },
          ],
        },
      ],
    })
  })

  it('loads transcript lazily and restores the native terminal on close', async () => {
    const onClose = vi.fn()
    render(
      <I18nProvider>
        <SessionTranscriptModal sessionId="session-a" title="Session A" onClose={onClose} />
      </I18nProvider>,
    )

    await waitFor(() => expect(api.fetchTranscript).toHaveBeenCalledWith('session-a', { limit: 100 }))
    expect(await screen.findByText('把右侧做得更有用')).toBeInTheDocument()
    expect(screen.getByText('正在实现 Session Context')).toBeInTheDocument()
    expect(screen.getByText('Read')).toBeInTheDocument()
    expect(api.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({ phase: 'obscure' }))

    fireEvent.click(screen.getByRole('button', { name: '关闭' }))
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})

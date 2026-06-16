import { render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import { SessionArtifactsModal, type SessionArtifactsModalTarget } from './SessionArtifactsModal'

const apiMocks = vi.hoisted(() => ({
  discardArtifactCandidate: vi.fn(),
  fetchSessionArtifacts: vi.fn(),
  promoteArtifactCandidate: vi.fn(),
  syncNativeSessionsWorkspace: vi.fn(),
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    discardArtifactCandidate: apiMocks.discardArtifactCandidate,
    fetchSessionArtifacts: apiMocks.fetchSessionArtifacts,
    promoteArtifactCandidate: apiMocks.promoteArtifactCandidate,
    syncNativeSessionsWorkspace: apiMocks.syncNativeSessionsWorkspace,
  }
})

const target: SessionArtifactsModalTarget = {
  sessionId: 'session-a',
  title: 'Codex - meee2',
  providerResumeSessionId: 'provider-session-a',
  surfaceId: 'surface-a',
  project: '/Users/kai/Code/meee2-workspace/meee2',
  projectName: 'meee2',
}

function renderWithI18n(ui: React.ReactElement) {
  return render(<I18nProvider>{ui}</I18nProvider>)
}

describe('SessionArtifactsModal', () => {
  beforeEach(() => {
    apiMocks.fetchSessionArtifacts.mockResolvedValue({
      candidates: [],
      artifacts: [],
      totalCount: 0,
      attachTargets: [],
    })
    apiMocks.syncNativeSessionsWorkspace.mockReturnValue(true)
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it('obscures the native terminal layer while the modal is open and requests restore on close', async () => {
    const relayout = vi.fn()
    const restore = vi.fn()
    window.addEventListener('meee2:layout-native-sessions-workspace', relayout)
    window.addEventListener('meee2:restore-native-sessions-workspace', restore)

    const { unmount } = renderWithI18n(
      <SessionArtifactsModal target={target} onClose={() => {}} />,
    )

    await screen.findByRole('dialog', { name: /Artifacts for Codex - meee2/i })
    await waitFor(() => expect(apiMocks.fetchSessionArtifacts).toHaveBeenCalledWith('session-a'))
    expect(apiMocks.syncNativeSessionsWorkspace).toHaveBeenCalledWith(expect.objectContaining({
      phase: 'obscure',
      mode: 'terminal',
      webPhase: 'sessionArtifactsModal.obscureNativeTerminal',
    }))

    unmount()

    expect(restore).toHaveBeenCalledTimes(1)
    expect(relayout).toHaveBeenCalledTimes(1)
    window.removeEventListener('meee2:layout-native-sessions-workspace', relayout)
    window.removeEventListener('meee2:restore-native-sessions-workspace', restore)
  })
})

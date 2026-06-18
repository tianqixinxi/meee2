import { fireEvent, render, screen, waitFor } from '@testing-library/react'
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

  it('uses a simple Artifacts title and opens the detailed artifacts page', async () => {
    const onOpenDetails = vi.fn()
    renderWithI18n(
      <SessionArtifactsModal target={target} onClose={() => {}} onOpenDetails={onOpenDetails} />,
    )

    await screen.findByRole('heading', { name: 'Artifacts' })
    expect(screen.queryByText(/Artifacts\[/)).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Open details' }))
    expect(onOpenDetails).toHaveBeenCalledWith(target)
  })

  it('promotes a candidate into a formal artifact and removes it from candidates', async () => {
    apiMocks.fetchSessionArtifacts
      .mockResolvedValueOnce({
        sessionId: 'session-a',
        candidates: [
          makeCandidate({ id: 'candidate-1', title: 'Candidate output' }),
        ],
        artifacts: [],
        totalCount: 1,
        attachTargets: [makeAttachTarget()],
      })
      .mockResolvedValue({
        sessionId: 'session-a',
        candidates: [],
        artifacts: [makeArtifact({ id: 'session-artifact-candidate-1', title: 'Candidate output' })],
        totalCount: 1,
        attachTargets: [makeAttachTarget()],
      })
    apiMocks.promoteArtifactCandidate.mockResolvedValue({
      candidate: makeCandidate({ id: 'candidate-1', title: 'Candidate output', status: 'promoted' }),
      artifact: makeArtifact({ id: 'session-artifact-candidate-1', title: 'Candidate output' }),
      attachTargets: [makeAttachTarget()],
    })

    renderWithI18n(<SessionArtifactsModal target={target} onClose={() => {}} />)

    await screen.findByText('Candidate output')
    fireEvent.click(screen.getByRole('button', { name: 'Promote' }))

    await waitFor(() => expect(apiMocks.promoteArtifactCandidate).toHaveBeenCalledWith('candidate-1'))
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Promote' })).not.toBeInTheDocument())
    expect(await screen.findByRole('heading', { name: 'Formal Artifacts' })).toBeInTheDocument()
  })

  it('promotes a candidate without a canvas node target', async () => {
    apiMocks.fetchSessionArtifacts
      .mockResolvedValueOnce({
        sessionId: 'session-a',
        candidates: [makeCandidate({ id: 'candidate-no-target', title: 'Detached output' })],
        artifacts: [],
        totalCount: 1,
        attachTargets: [],
      })
      .mockResolvedValue({
        sessionId: 'session-a',
        candidates: [],
        artifacts: [makeArtifact({ id: 'session-artifact-candidate-no-target', title: 'Detached output' })],
        totalCount: 1,
        attachTargets: [],
      })
    apiMocks.promoteArtifactCandidate.mockResolvedValue({
      candidate: makeCandidate({ id: 'candidate-no-target', title: 'Detached output', status: 'promoted' }),
      artifact: makeArtifact({ id: 'session-artifact-candidate-no-target', title: 'Detached output' }),
      attachTargets: [],
    })

    renderWithI18n(<SessionArtifactsModal target={target} onClose={() => {}} />)

    await screen.findByText('Detached output')
    const promote = screen.getByRole('button', { name: 'Promote' })
    expect(promote).toBeEnabled()
    fireEvent.click(promote)

    await waitFor(() => expect(apiMocks.promoteArtifactCandidate).toHaveBeenCalledWith('candidate-no-target'))
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Promote' })).not.toBeInTheDocument())
    expect(await screen.findByRole('heading', { name: 'Formal Artifacts' })).toBeInTheDocument()
  })

  it('discards a candidate, removes it immediately, and broadcasts an artifact refresh', async () => {
    const changed = vi.fn()
    window.addEventListener('meee2:session-artifacts-changed', changed)
    apiMocks.fetchSessionArtifacts
      .mockResolvedValueOnce({
        sessionId: 'session-a',
        candidates: [makeCandidate({ id: 'candidate-2', title: 'Scratch output' })],
        artifacts: [],
        totalCount: 1,
        attachTargets: [],
      })
      .mockResolvedValue({
        sessionId: 'session-a',
        candidates: [],
        artifacts: [],
        totalCount: 0,
        attachTargets: [],
      })
    apiMocks.discardArtifactCandidate.mockResolvedValue({
      candidate: makeCandidate({ id: 'candidate-2', title: 'Scratch output', status: 'discarded' }),
      artifact: null,
      attachTargets: [],
    })

    renderWithI18n(<SessionArtifactsModal target={target} onClose={() => {}} />)

    await screen.findByText('Scratch output')
    fireEvent.click(screen.getByRole('button', { name: 'Discard' }))

    await waitFor(() => expect(apiMocks.discardArtifactCandidate).toHaveBeenCalledWith('candidate-2'))
    await waitFor(() => expect(screen.queryByText('Scratch output')).not.toBeInTheDocument())
    expect(changed).toHaveBeenCalledTimes(1)
    window.removeEventListener('meee2:session-artifacts-changed', changed)
  })
})

function makeAttachTarget() {
  return {
    canvasId: 'canvas-a',
    canvasName: 'Monitor',
    nodeId: 'node-a',
    nodeTitle: 'Build feature',
  }
}

function makeCandidate(overrides: Partial<{
  id: string
  title: string
  status: string
}> = {}) {
  return {
    id: overrides.id ?? 'candidate-1',
    sessionId: 'session-a',
    provider: 'codex',
    cwd: '/Users/kai/Code/meee2-workspace/meee2',
    title: overrides.title ?? 'Candidate output',
    kind: 'file',
    status: overrides.status ?? 'candidate',
    createdAt: '2026-06-18T00:00:00Z',
    updatedAt: '2026-06-18T00:00:00Z',
    sourceEvent: 'PostToolUse',
    toolName: 'apply_patch',
    toolUseId: 'tool-a',
    references: [],
    summary: 'Generated candidate artifact.',
    promotedCanvasId: null,
    promotedNodeId: null,
    promotedArtifactId: null,
  }
}

function makeArtifact(overrides: Partial<{ id: string; title: string }> = {}) {
  return {
    id: overrides.id ?? 'artifact-1',
    canvasId: 'canvas-a',
    nodeId: 'node-a',
    kind: 'file',
    title: overrides.title ?? 'Candidate output',
    reference: 'candidate-output.txt',
    status: 'attached',
    createdAt: '2026-06-18T00:00:01Z',
    payload: { type: 'text', text: 'Generated candidate artifact.' },
    typedPayload: { type: 'text', text: 'Generated candidate artifact.' },
    reviewStatus: 'approved',
  }
}

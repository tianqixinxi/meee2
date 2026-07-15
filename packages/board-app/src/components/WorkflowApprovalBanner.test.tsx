import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { I18nProvider } from '../lib/i18n'
import { WorkflowApprovalBanner } from './WorkflowApprovalBanner'

const api = vi.hoisted(() => ({
  fetchWorkflowApprovals: vi.fn(),
  resolveWorkflowApproval: vi.fn(),
}))

vi.mock('../api', () => api)

describe('WorkflowApprovalBanner', () => {
  beforeEach(() => {
    api.fetchWorkflowApprovals.mockReset()
    api.resolveWorkflowApproval.mockReset()
  })

  it('shows a pending agent request and resolves it only after a UI decision', async () => {
    api.fetchWorkflowApprovals
      .mockResolvedValueOnce([{
        id: 'approval-1',
        action: 'enable',
        proposalId: 'proposal-1',
        proposalVersion: 2,
        canvasId: 'canvas-1',
        actorId: 'owner',
        status: 'pending',
        requestedAt: '2026-07-16T00:00:00Z',
      }])
      .mockResolvedValue([])
    api.resolveWorkflowApproval.mockResolvedValue(undefined)

    render(<I18nProvider><WorkflowApprovalBanner /></I18nProvider>)

    expect(await screen.findByRole('alert')).toHaveTextContent('Enable recurring jobs')
    expect(api.resolveWorkflowApproval).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Approve' }))

    await waitFor(() => expect(api.resolveWorkflowApproval).toHaveBeenCalledWith('approval-1', true))
    await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument())
  })
})

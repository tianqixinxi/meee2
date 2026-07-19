import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { AttachDataSourcePopover } from './AttachDataSourcePopover'

const api = vi.hoisted(() => ({ fetchAgentScan: vi.fn() }))
vi.mock('../../api', () => api)

describe('AttachDataSourcePopover', () => {
  beforeEach(() => {
    api.fetchAgentScan.mockReset()
    api.fetchAgentScan.mockResolvedValue({ statuses: [] })
  })

  it('keeps the picker and selected file open when the server rejects the input', async () => {
    const onClose = vi.fn()
    const onSubmit = vi.fn().mockRejectedValue(new Error('服务端拒绝了这个文件'))
    render(
      <AttachDataSourcePopover
        nodeId="node-1"
        inputs={['PDF']}
        onClose={onClose}
        onSubmit={onSubmit}
      />,
    )
    const file = new File(['pdf'], 'brief.pdf', { type: 'application/pdf' })
    fireEvent.change(screen.getByLabelText(/文件（最大 10 MB）/), { target: { files: [file] } })
    fireEvent.click(screen.getByRole('button', { name: '添加输入' }))

    await waitFor(() => expect(onSubmit).toHaveBeenCalledWith({ kind: 'file', input: 'PDF', file }))
    expect(await screen.findByRole('alert')).toHaveTextContent('服务端拒绝了这个文件')
    expect(screen.getByRole('dialog')).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
  })
})

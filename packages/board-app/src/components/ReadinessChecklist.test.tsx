import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReadinessReport } from '../types'
import { ReadinessChecklist } from './ReadinessChecklist'

describe('ReadinessChecklist compact mode', () => {
  it('keeps degraded optional capabilities visible', () => {
    const report: ReadinessReport = {
      overall: 'ready',
      ready: true,
      requiredFailed: 0,
      checkedAt: '2026-07-10T00:00:00Z',
      checks: [
        {
          id: 'required-ok',
          title: 'Board server',
          status: 'pass',
          severity: 'required',
          detail: 'Ready',
          message: 'Ready',
          recoveryAction: null,
          settingsSection: 'runtime',
          metadata: {},
        },
        {
          id: 'artifact-hooks',
          title: 'Artifact hooks',
          status: 'warn',
          severity: 'recommended',
          detail: 'Artifacts will not be captured automatically.',
          message: 'Artifacts will not be captured automatically.',
          recoveryAction: null,
          settingsSection: 'runtime',
          metadata: {},
        },
        {
          id: 'optional-ok',
          title: 'Optional integration',
          status: 'pass',
          severity: 'recommended',
          detail: 'Ready',
          message: 'Ready',
          recoveryAction: null,
          settingsSection: 'runtime',
          metadata: {},
        },
      ],
    }

    render(<ReadinessChecklist report={report} repairingAction={null} onRepair={vi.fn()} compact />)

    expect(screen.getByText('Board server')).toBeInTheDocument()
    expect(screen.getByText('Artifact hooks')).toBeInTheDocument()
    expect(screen.queryByText('Optional integration')).not.toBeInTheDocument()
  })
})

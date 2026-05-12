import { forwardRef } from 'react'
import type { BoardState, Session } from '../types'
import { Dock, type DockHandle } from './Dock'

interface Props {
  state: BoardState
  session: Session
  initialSeed?: string
  onClose: () => void
}

export const SessionDetailModal = forwardRef<DockHandle, Props>(function SessionDetailModal(
  { state, session, initialSeed, onClose },
  ref,
) {
  return (
    <Dock
      ref={ref}
      mode={{
        kind: 'session',
        state,
        session,
      }}
      initialSeed={initialSeed}
      onClose={onClose}
    />
  )
})

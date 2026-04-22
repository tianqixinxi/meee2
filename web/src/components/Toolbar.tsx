interface Props {
  connected: boolean
  onFit: () => void
}

export default function Toolbar({ connected, onFit }: Props) {
  return (
    <div className="toolbar">
      <div className="title">meee2 · board</div>
      <button onClick={onFit} title="Fit canvas to content">
        Fit
      </button>
      <div className="spacer" />
      <span className="status-label">{connected ? 'live' : 'offline'}</span>
      <span
        className={'status-dot' + (connected ? ' on' : '')}
        title={connected ? 'Events connected' : 'Disconnected — reconnecting…'}
      />
    </div>
  )
}

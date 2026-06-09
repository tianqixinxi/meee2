import type { ArtifactPayload } from '../../types'

export function TypedPayloadPreview({ payload }: { payload: ArtifactPayload }) {
  switch (payload.type) {
    case 'prd':
      return (
        <div className="artifacts-typed-payload artifacts-typed-payload--prd">
          <div className="artifacts-typed-payload__tldr">{payload.tldr}</div>
          <ul className="artifacts-typed-payload__sections">
            {payload.sections.map((section) => (
              <li key={section.heading}>
                <strong>{section.heading}</strong>
                <em>{section.lines} lines</em>
              </li>
            ))}
          </ul>
        </div>
      )
    case 'kanban':
      return (
        <div className="artifacts-typed-payload artifacts-typed-payload--kanban">
          {payload.columns.map((column) => (
            <div key={column.name} className="artifacts-typed-payload__kanban-col">
              <header>
                <span>{column.name}</span>
                <em>{column.items.length}</em>
              </header>
              {column.items.slice(0, 5).map((item) => (
                <div key={item} className="artifacts-typed-payload__kanban-item">
                  {item}
                </div>
              ))}
              {column.items.length > 5 && (
                <div className="artifacts-typed-payload__kanban-more">
                  +{column.items.length - 5}
                </div>
              )}
            </div>
          ))}
        </div>
      )
    case 'impl-pr':
      return (
        <div className="artifacts-typed-payload artifacts-typed-payload--pr">
          <div className="artifacts-typed-payload__pr-line">
            <strong>#{payload.number}</strong>
            <code>{payload.branch}</code>
            <span>{payload.baseBranch}</span>
          </div>
          <div className="artifacts-typed-payload__pr-stats">
            <strong>{payload.filesChanged}</strong> files ·
            <span className="artifacts-typed-payload__pr-add"> +{payload.insertions}</span> ·
            <span className="artifacts-typed-payload__pr-del"> -{payload.deletions}</span>
          </div>
          <div className={`artifacts-typed-payload__ci is-${payload.ciStatus}`}>
            CI {payload.ciStatus}
          </div>
          <div className="artifacts-typed-payload__pr-reviewers">
            Reviewers · {payload.reviewers.join(', ') || '(none)'}
          </div>
        </div>
      )
    case 'check-result':
      return (
        <div className="artifacts-typed-payload artifacts-typed-payload--check">
          <div className="artifacts-typed-payload__check-pills">
            <span className="is-pass">{payload.pass} pass</span>
            <span className="is-fail">{payload.fail} fail</span>
            <span className="is-skip">{payload.skip} skip</span>
          </div>
          {payload.failing.length > 0 && (
            <ul className="artifacts-typed-payload__failing">
              {payload.failing.slice(0, 5).map((failure) => (
                <li key={failure}>{failure}</li>
              ))}
            </ul>
          )}
        </div>
      )
    case 'file':
      return (
        <dl className="artifacts-typed-payload artifacts-typed-payload--file">
          <div><dt>filename</dt><dd>{payload.filename}</dd></div>
          <div><dt>mime</dt><dd>{payload.mime}</dd></div>
          <div><dt>size</dt><dd>{formatBytesPlain(payload.sizeBytes)}</dd></div>
          {payload.lines != null && <div><dt>lines</dt><dd>{payload.lines}</dd></div>}
        </dl>
      )
    case 'json':
      return (
        <div className="artifacts-typed-payload artifacts-typed-payload--json">
          <div className="artifacts-typed-payload__json-summary">{payload.preview}</div>
          <dl className="artifacts-typed-payload__json-entries">
            {payload.entries.map((entry) => (
              <div key={entry.key}>
                <dt>{entry.key}</dt>
                <dd>{entry.value}</dd>
              </div>
            ))}
          </dl>
        </div>
      )
    case 'markdown':
      return <pre className="artifacts-typed-payload artifacts-typed-payload--markdown">{payload.preview}</pre>
    case 'integration':
      return (
        <div className="artifacts-typed-payload artifacts-typed-payload--integration">
          <div className="artifacts-typed-payload__integration-line">
            <strong>{payload.connector}</strong>
            <code>{payload.externalId}</code>
          </div>
          {payload.externalUrl && (
            <a href={payload.externalUrl} target="_blank" rel="noopener noreferrer">
              {payload.externalUrl}
            </a>
          )}
          {payload.summary && <div className="artifacts-typed-payload__integration-summary">{payload.summary}</div>}
          {payload.fields && Object.keys(payload.fields).length > 0 && (
            <dl className="artifacts-typed-payload__entries">
              {Object.entries(payload.fields).map(([key, value]) => (
                <div key={key}>
                  <dt>{key}</dt>
                  <dd>{String(value)}</dd>
                </div>
              ))}
            </dl>
          )}
        </div>
      )
  }
}

function formatBytesPlain(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / (1024 * 1024)).toFixed(1)} MB`
}

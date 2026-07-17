import { FileUp, Link2, Plug, X } from 'lucide-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import { fetchAgentScan } from '../../api'
import type { AgentIntegrationStatus } from '../../types'

export type NodeInputSubmission =
  | { kind: 'file'; input: string; file: File }
  | { kind: 'url'; input: string; url: string }
  | { kind: 'integration'; input: string; integrationId: string; entityRef: string }

export interface AttachDataSourcePopoverProps {
  nodeId: string
  inputs: string[]
  onClose: () => void
  onSubmit: (input: NodeInputSubmission) => Promise<void>
}

type SourceKind = NodeInputSubmission['kind']

export function AttachDataSourcePopover({
  nodeId,
  inputs,
  onClose,
  onSubmit,
}: AttachDataSourcePopoverProps) {
  const [sourceKind, setSourceKind] = useState<SourceKind>('file')
  const [inputSlot, setInputSlot] = useState(inputs[0] ?? '')
  const [file, setFile] = useState<File | null>(null)
  const [url, setURL] = useState('')
  const [entityRef, setEntityRef] = useState('')
  const [integrationId, setIntegrationId] = useState('')
  const [statuses, setStatuses] = useState<AgentIntegrationStatus[]>([])
  const [loadingIntegrations, setLoadingIntegrations] = useState(true)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const urlRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    let cancelled = false
    fetchAgentScan()
      .then((result) => {
        if (cancelled) return
        setStatuses(result.statuses)
      })
      .catch(() => {
        if (!cancelled) setStatuses([])
      })
      .finally(() => {
        if (!cancelled) setLoadingIntegrations(false)
      })
    return () => { cancelled = true }
  }, [])

  const integrations = useMemo(() => {
    const byId = new Map<string, AgentIntegrationStatus>()
    for (const status of statuses) {
      const current = byId.get(status.integrationId)
      if (!current || status.state === 'connected') byId.set(status.integrationId, status)
    }
    return Array.from(byId.values()).filter((status) => status.state === 'connected' || status.state === 'partial')
  }, [statuses])

  useEffect(() => {
    if (!integrationId && integrations[0]) setIntegrationId(integrations[0].integrationId)
  }, [integrationId, integrations])

  const submit = async () => {
    if (!inputSlot) {
      setError('这个节点没有可绑定的输入槽。')
      return
    }
    let value: NodeInputSubmission
    if (sourceKind === 'file') {
      if (!file) { setError('请选择一个文件。'); return }
      if (file.size > 10 * 1024 * 1024) { setError('单个文件不能超过 10 MB。'); return }
      value = { kind: 'file', input: inputSlot, file }
    } else if (sourceKind === 'url') {
      const trimmed = url.trim()
      if (!/^https?:\/\//i.test(trimmed)) { setError('请输入 http 或 https URL。'); return }
      value = { kind: 'url', input: inputSlot, url: trimmed }
    } else {
      if (!integrationId || !entityRef.trim()) { setError('请选择集成并填写资源引用。'); return }
      value = { kind: 'integration', input: inputSlot, integrationId, entityRef: entityRef.trim() }
    }
    setSubmitting(true)
    setError(null)
    try {
      await onSubmit(value)
      onClose()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : '添加输入失败')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="planner-attach-popover-backdrop" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <div className="planner-attach-popover" role="dialog" aria-modal="true" aria-label={`为节点 ${nodeId} 添加输入`}>
        <div className="planner-attach-popover__header">
          <strong>添加输入</strong>
          <button type="button" className="planner-attach-popover__close" onClick={onClose} aria-label="关闭">
            <X size={13} aria-hidden />
          </button>
        </div>

        <label className="planner-attach-popover__field">
          <span>输入槽</span>
          <select value={inputSlot} disabled={submitting || inputs.length === 0} onChange={(event) => setInputSlot(event.target.value)}>
            {inputs.map((input) => <option key={input} value={input}>{input}</option>)}
          </select>
        </label>

        <div className="planner-attach-popover__source-tabs" role="tablist" aria-label="输入来源">
          {([
            ['file', FileUp, '本地文件'],
            ['url', Link2, 'URL'],
            ['integration', Plug, '已连接集成'],
          ] as const).map(([kind, Icon, label]) => (
            <button key={kind} type="button" role="tab" aria-selected={sourceKind === kind} onClick={() => { setSourceKind(kind); setError(null) }}>
              <Icon size={12} aria-hidden /> {label}
            </button>
          ))}
        </div>

        {sourceKind === 'file' && (
          <label className="planner-attach-popover__field">
            <span>文件（最大 10 MB）</span>
            <input type="file" disabled={submitting} onChange={(event) => setFile(event.target.files?.[0] ?? null)} />
          </label>
        )}
        {sourceKind === 'url' && (
          <label className="planner-attach-popover__field">
            <span>网页地址</span>
            <input ref={urlRef} value={url} disabled={submitting} onChange={(event) => setURL(event.target.value)} placeholder="https://…" />
          </label>
        )}
        {sourceKind === 'integration' && (
          <>
            {loadingIntegrations ? <p className="planner-attach-popover__muted">正在读取 Agent 集成…</p> : integrations.length === 0 ? (
              <p className="planner-attach-popover__warn">当前没有可用的 Agent 集成。仍可使用文件或 URL。</p>
            ) : (
              <>
                <label className="planner-attach-popover__field">
                  <span>集成</span>
                  <select value={integrationId} disabled={submitting} onChange={(event) => setIntegrationId(event.target.value)}>
                    {integrations.map((status) => <option key={status.integrationId} value={status.integrationId}>{status.integrationName}</option>)}
                  </select>
                </label>
                <label className="planner-attach-popover__field">
                  <span>资源引用</span>
                  <input value={entityRef} disabled={submitting} onChange={(event) => setEntityRef(event.target.value)} placeholder="例如 owner/repo#123、doc-id" />
                </label>
              </>
            )}
          </>
        )}

        {error && <p className="planner-attach-popover__error" role="alert">{error}</p>}
        <div className="planner-attach-popover__actions">
          <button type="button" onClick={onClose} disabled={submitting}>取消</button>
          <button type="button" className="primary" onClick={() => void submit()} disabled={submitting || inputs.length === 0}>
            {submitting ? '添加中…' : '添加输入'}
          </button>
        </div>
      </div>
    </div>
  )
}

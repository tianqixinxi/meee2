/**
 * IntegrationArtifactView — integration artifact 的 view 投影体。
 *
 * ADR-0009 的 Artifact Views 体系里,integration 是一等 view kind:同一份
 * integration payload 的展示形态由这里统一负责 —— canvas 节点卡片
 * (ArtifactViewTabs 派生视图)、inspector、Artifacts rail 共用,不再各自
 * 复制 provider/summary 简版。
 *
 * 分发顺序:
 *   1. 能投影成已注册 IntegrationEntity 且是 google-sheets → sheet 样式格子
 *      (绿表头 + 列名 + 占位行;事实在 footer,不伪造行数据)。
 *   2. 其他已注册 integration → view-schema 渲染(badge + label 取值的
 *      detail 行 + 链接)。
 *   3. 投影不出来(未注册 connector / 裸 URL)→ provider/summary/url 简版。
 */

import { useState } from 'react'
import type {
  IntegrationEntity,
  IntegrationViewSchema,
  PlannerArtifact,
  PlannerArtifactContent,
} from '../types'
import { artifactToIntegrationEntity } from './artifactEntity'
import { getViewSchema } from './viewSchemas'
import { syncPlannerArtifact } from '../api'

/**
 * 手动同步按钮 — 写穿契约的一键触发:派发该 reference 的专属轻量同步会话
 * (不绑节点、不进节点工作账本),由它用 MCP(get_artifact → 核对外部对象 →
 * update_artifact)刷新快照;每 reference 至多一条,活着复用、死了重建。
 * 按钮自带内联状态反馈(不依赖外层 toast 管道,这个 view 在卡片/inspector/
 * rail 多处复用)。
 */
function SyncSnapshotButton({ artifact }: { artifact: PlannerArtifact }) {
  const [state, setState] = useState<'idle' | 'busy' | 'sent' | 'error'>('idle')
  const [detail, setDetail] = useState('')
  const run = (event: React.MouseEvent) => {
    event.stopPropagation()
    if (state === 'busy') return
    setState('busy')
    syncPlannerArtifact(artifact.canvasId, { reference: artifact.reference })
      .then((result) => {
        setState('sent')
        setDetail(result.detail)
      })
      .catch((err: Error) => {
        setState('error')
        setDetail(err.message || '同步会话派发失败')
      })
  }
  return (
    <span className="planner-node__integration-sync">
      <button
        type="button"
        className="planner-node__integration-sync-btn nodrag"
        onClick={run}
        onPointerDown={(event) => event.stopPropagation()}
        disabled={state === 'busy'}
        title="派发专属同步会话核对外部对象并刷新快照(get_artifact → update_artifact)"
      >
        {state === 'busy' ? '同步中…' : '同步快照'}
      </button>
      {detail && (
        <small className={state === 'error' ? 'planner-node__integration-sync-err' : undefined}>
          {detail}
        </small>
      )}
    </span>
  )
}

export function IntegrationArtifactView({
  artifact,
  content,
}: {
  artifact: PlannerArtifact
  content?: PlannerArtifactContent | null
}) {
  const payload = objectPayload(artifact.payload)
  const url = stringField(payload, 'url') ?? (artifact.reference.includes('://') ? artifact.reference : null)
  const entity = artifactToIntegrationEntity(artifact)
  const schema = entity ? viewSchemaOf(entity.schemaId) : undefined
  if (entity && schema && schema.integrationId === 'google-sheets') {
    return (
      <>
        <GoogleSheetsTabPreview entity={entity} schema={schema} reference={artifact.reference} />
        <SyncSnapshotButton artifact={artifact} />
      </>
    )
  }
  if (entity && schema) {
    const entityPayload = objectPayload(entity.payload)
    // 只认投影产出的 url(artifactToIntegrationEntity 已滤掉 gsheet:// 等内部
    // scheme)。这里不能再兜底上面的 raw `url` — 它会把内部引用变回死链接。
    const entityUrl = stringField(entityPayload, 'url')
    const secondary = stringField(entityPayload, 'secondary')
    const details = schema.preview.details
      .map((d) => ({ ...d, value: d.value || scalarField(entityPayload, d.label) }))
      .filter((d) => d.value && d.kind !== 'link')
      .slice(0, 4)
    return (
      <div className="planner-node__integration-preview">
        <strong>
          {schema.integrationId}:{schema.entityKind}
          {secondary ? ` · ${secondary}` : ''}
        </strong>
        {details.length > 0 && (
          <span>
            {details.map((d) => `${d.label} ${d.value}`).join(' · ')}
          </span>
        )}
        {entityUrl ? (
          <a href={entityUrl} target="_blank" rel="noreferrer" onClick={(event) => event.stopPropagation()}>
            {entityUrl}
          </a>
        ) : (
          <code>{artifact.reference}</code>
        )}
        <SyncSnapshotButton artifact={artifact} />
      </div>
    )
  }
  const provider = stringField(payload, 'provider') ?? artifact.kind
  const summary = stringField(payload, 'summary') ?? content?.content
  return (
    <div className="planner-node__integration-preview">
      <strong>{provider}</strong>
      {summary && <span>{summary}</span>}
      {url ? (
        <a href={url} target="_blank" rel="noreferrer" onClick={(event) => event.stopPropagation()}>
          {url}
        </a>
      ) : (
        <code>{artifact.reference}</code>
      )}
    </div>
  )
}

/**
 * Google Sheets tracker tab 的 sheet 样式 view:绿表头格子 + 列名 + 占位行。
 * integration 层只有 schema+view(无 fetch)— 格子是 tab 的「形状」,事实
 * (行数/更新时间)在 footer 文案里,行格子只是占位纹理,不伪造数据。
 */
function GoogleSheetsTabPreview({
  entity,
  schema,
  reference,
}: {
  entity: IntegrationEntity
  schema: IntegrationViewSchema
  reference: string
}) {
  const payload = objectPayload(entity.payload)
  const url = stringField(payload, 'url')
  const tab = scalarField(payload, 'tab') || scalarField(payload, 'secondary')
  const columns = scalarField(payload, 'header')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
  const rowCount = Number(scalarField(payload, 'rows') || '0')
  const updated = scalarField(payload, 'updated')
  // 列数:header 给了列名就数列名;老 payload 只有数值 fields.columns
  // (无列名,画不出表头格子)时也要保留列数事实,不能比旧通用渲染知道得更少。
  const columnCount = columns.length > 0 ? columns.length : Number(scalarField(payload, 'columns') || '0')
  const facts = [
    Number.isFinite(rowCount) ? `${rowCount} 行` : '',
    columnCount > 0 ? `${columnCount} 列` : '',
    updated ? `更新 ${updated}` : '',
    rowCount === 0 ? '待写入' : '',
  ].filter(Boolean)
  return (
    <div className="planner-node__integration-preview planner-node__sheet">
      <strong className="planner-node__sheet-head">
        Google Sheets{schema.entityKind === 'tab' && tab ? ` · ${tab}` : ''}
      </strong>
      {columns.length > 0 ? (
        <div className="planner-node__table-block planner-node__sheet-grid">
          <div className="planner-node__table-wrap">
            <table className="planner-node__table">
              <thead>
                <tr>
                  {columns.map((column) => (
                    <th key={column}>{column}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {Array.from({ length: 3 }, (_, rowIndex) => (
                  <tr key={rowIndex}>
                    {columns.map((column) => (
                      <td key={column}>&nbsp;</td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="planner-node__table-footer">{facts.join(' · ')}</div>
        </div>
      ) : (
        facts.length > 0 && <span>{facts.join(' · ')}</span>
      )}
      {url ? (
        <a href={url} target="_blank" rel="noreferrer" onClick={(event) => event.stopPropagation()}>
          在 Google Sheets 打开
        </a>
      ) : (
        <code>{reference}</code>
      )}
    </div>
  )
}

/** `<integrationId>:<entityKind>` → view schema(拆分一次,避免两处 slice)。 */
function viewSchemaOf(schemaId: string) {
  const sep = schemaId.indexOf(':')
  if (sep <= 0) return undefined
  return getViewSchema(schemaId.slice(0, sep), schemaId.slice(sep + 1))
}

/** detail 行取值:integration fields 是 string|number 混合(rows/columns 是数),
 *  stringField 只认 string 会把数值行整行丢掉。 */
function scalarField(object: Record<string, unknown> | null, field: string): string {
  const value = object?.[field]
  if (typeof value === 'string') return value
  if (typeof value === 'number' && Number.isFinite(value)) return String(value)
  return ''
}

function objectPayload(payload: unknown): Record<string, unknown> | null {
  return payload && typeof payload === 'object' && !Array.isArray(payload)
    ? payload as Record<string, unknown>
    : null
}

function stringField(object: Record<string, unknown> | null, field: string): string | null {
  const value = object?.[field]
  return typeof value === 'string' && value.trim().length > 0 ? value : null
}

/**
 * TabularArtifactPreview — generic JSON → table visualization for artifact
 * cards.
 *
 * Why: a node output like "50 sourced companies" arrives as a `file` / `json`
 * artifact whose card previously rendered as a metadata stub (文件 + filename
 * + size) or a raw `<pre>` dump — the structured content was invisible. The
 * canvas is a living ledger; the card should *show the data*, not describe
 * the container.
 *
 * Pure shape detection, no fetch: callers hand in the already-loaded artifact
 * content / payload. Array-of-objects → table (capped rows/columns), array of
 * scalars → single-column list. Objects / non-JSON stay on their existing
 * render paths.
 */

const MAX_ROWS = 30
const MAX_COLUMNS = 8
const MAX_CELL_CHARS = 120

export interface TabularData {
  columns: string[]
  /** Row-major cells, stringified + truncated; aligned with `columns`. */
  rows: string[][]
  totalRows: number
  /** Keys dropped by the MAX_COLUMNS cap (shown as a hint, not silently cut). */
  droppedColumns: number
  /** 对象根时被选中做表格的字段名(如 `candidates`),标在 footer 里。 */
  sourceKey?: string
}

/**
 * Project a parsed JSON value into table data, or null when the shape isn't
 * tabular (not an array / empty array). Exported for unit tests.
 *
 * 对象根:节点输出常见形状是 `{ thesis: {...}, candidates: [54 rows],
 * summary: {...} }` — 数据主体是包在元信息里的那个数组。取最大的非空数组
 * 字段做表格,字段名记进 `sourceKey` 提示来源,而不是因为根不是数组就放弃。
 */
export function parseTabular(value: unknown): TabularData | null {
  if (!Array.isArray(value)) {
    if (value && typeof value === 'object') {
      const arrays = Object.entries(value as Record<string, unknown>)
        .filter((entry): entry is [string, unknown[]] => Array.isArray(entry[1]) && entry[1].length > 0)
        .sort((a, b) => b[1].length - a[1].length)
      for (const [key, arr] of arrays) {
        const inner = parseTabular(arr)
        if (inner) return { ...inner, sourceKey: key }
      }
    }
    return null
  }
  if (value.length === 0) return null

  const objectRows = value.filter(
    (row): row is Record<string, unknown> =>
      Boolean(row) && typeof row === 'object' && !Array.isArray(row),
  )
  // 混合数组(对象+标量)按对象行为主;全标量数组退化成单列。
  if (objectRows.length === 0) {
    return {
      columns: ['value'],
      rows: value.slice(0, MAX_ROWS).map((item) => [cellText(item)]),
      totalRows: value.length,
      droppedColumns: 0,
    }
  }

  // 列发现必须覆盖每一条「会被渲染」的行:只扫一个比 MAX_ROWS 小的前缀的话,
  // 晚出现的键(行 21–30 才有的字段)会被静默吞掉且 droppedColumns 还是 0 —
  // 违背 footer 的「不静默截断」承诺。MAX_ROWS 之外的行本来就不渲染,
  // 它们的键不参与发现。
  const renderedRows = objectRows.slice(0, MAX_ROWS)
  const allColumns: string[] = []
  for (const row of renderedRows) {
    for (const key of Object.keys(row)) {
      if (!allColumns.includes(key)) allColumns.push(key)
    }
  }
  const columns = allColumns.slice(0, MAX_COLUMNS)
  return {
    columns,
    rows: renderedRows.map((row) => columns.map((c) => cellText(row[c]))),
    totalRows: objectRows.length,
    droppedColumns: allColumns.length - columns.length,
  }
}

function cellText(value: unknown): string {
  if (value == null) return ''
  let text: string
  if (typeof value === 'string') {
    text = value
  } else if (typeof value === 'number' || typeof value === 'boolean') {
    text = String(value)
  } else if (Array.isArray(value)) {
    // 嵌套数组多为 tag 列表(founders / keywords) — 拍平成可读串而非 Array(n)。
    text = value.map((v) => (typeof v === 'string' || typeof v === 'number' ? String(v) : '…')).join(', ')
  } else {
    try {
      text = JSON.stringify(value)
    } catch {
      text = String(value)
    }
  }
  return text.length > MAX_CELL_CHARS ? `${text.slice(0, MAX_CELL_CHARS)}…` : text
}

export function TabularArtifactPreview({ data, caption }: { data: TabularData; caption?: string }) {
  const hiddenRows = data.totalRows - data.rows.length
  const stats = [
    data.sourceKey ?? '',
    `共 ${data.totalRows} 行`,
    hiddenRows > 0 ? `还有 ${hiddenRows} 行未展示` : '',
    data.droppedColumns > 0 ? `${data.droppedColumns} 列收起` : '',
    caption ?? '',
  ].filter(Boolean)
  return (
    <div className="planner-node__table-wrap">
      <table className="planner-node__table">
        <thead>
          <tr>
            {data.columns.map((column) => (
              <th key={column}>{column}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {data.rows.map((row, rowIndex) => (
            <tr key={rowIndex}>
              {row.map((cell, cellIndex) => (
                <td key={cellIndex} title={cell}>{cell}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      <div className="planner-node__table-footer">{stats.join(' · ')}</div>
    </div>
  )
}

/** 安全 JSON parse:内容超限或非法时返回 null,绝不 throw。 */
export function parseArtifactJSON(raw: string | null | undefined, maxChars = 512_000): unknown {
  if (!raw || raw.length > maxChars) return null
  try {
    return JSON.parse(raw)
  } catch {
    return null
  }
}

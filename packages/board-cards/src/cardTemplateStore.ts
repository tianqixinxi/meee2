// Client for the Wave 17a /api/card-templates REST endpoints.
//
// Contract:
//   GET    /api/card-templates          → { templates: TemplateEntry[] }
//   GET    /api/card-templates/:id      → TemplateEntry  | 404 if not present
//   PUT    /api/card-templates/:id      { source } → TemplateEntry
//   DELETE /api/card-templates/:id      → { ok: true }
//
// A 404 on GET is not an error — it means "no custom template, use the bundled
// default". Callers handle that explicitly.

export interface TemplateEntry {
  id: string
  source: string
  /** ISO8601, optional — backend may or may not set it. */
  updatedAt?: string
}

async function jsonRequest<T>(
  input: string,
  init?: RequestInit,
): Promise<T | null> {
  const res = await fetch(input, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(init?.headers ?? {}),
    },
  })
  if (res.status === 404) return null
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} ${res.statusText}`)
  }
  const text = await res.text()
  if (!text) return null as unknown as T
  return JSON.parse(text) as T
}

export async function listTemplates(): Promise<TemplateEntry[]> {
  const r = await jsonRequest<{ templates: TemplateEntry[] }>(
    '/api/card-templates',
  )
  return r?.templates ?? []
}

/**
 * Fetch a single template. Returns null if the backend has no entry — the
 * caller should fall back to the bundled default template.
 *
 * 后端现在返回 `{"template": Entry | null}` envelope（之前 404 改造后）；
 * 所以这里要 **unwrap**。历史上的 bug：没 unwrap → 调用方的 `entry?.source`
 * 永远 undefined → 每次 WS tick 都把本地编辑冲回 DEFAULT（"闪一下"现象）。
 */
export async function getTemplate(id: string): Promise<TemplateEntry | null> {
  const r = await jsonRequest<{ template: TemplateEntry | null }>(
    `/api/card-templates/${encodeURIComponent(id)}`,
  )
  return r?.template ?? null
}

export async function putTemplate(
  id: string,
  source: string,
): Promise<TemplateEntry> {
  const r = await jsonRequest<{ template: TemplateEntry }>(
    `/api/card-templates/${encodeURIComponent(id)}`,
    {
      method: 'PUT',
      body: JSON.stringify({ source }),
    },
  )
  if (!r?.template) throw new Error('Empty response from PUT /api/card-templates/' + id)
  return r.template
}

export async function deleteTemplate(id: string): Promise<void> {
  await jsonRequest<{ ok: boolean }>(
    `/api/card-templates/${encodeURIComponent(id)}`,
    { method: 'DELETE' },
  )
}

/**
 * Compute the canonical template id for a plugin's cards.
 *
 *   "com.meee2.plugin.claude"   → "default-claude"
 *   "com.meee2.plugin.openclaw" → "default-openclaw"
 *   "unknown"                   → "default-unknown"
 */
export function templateIdForPlugin(pluginId: string): string {
  if (!pluginId) return 'default-unknown'
  const parts = pluginId.split('.')
  const suffix = parts[parts.length - 1] || 'unknown'
  return `default-${suffix}`
}

/**
 * Per-session template id：每张 card 自己存一份，编辑互不影响。
 *
 *   "c5467d44-569c-4e29-adf5-60130be83051" → "session-c5467d44"
 *
 * 只用 sid 的前 8 位做 key 是为了避免 id 太长撑爆文件系统/URL；
 * 碰撞概率极低（UUID v4 前 8 位的 4 billion 分之一）。
 */
export function templateIdForSession(sessionId: string): string {
  if (!sessionId) return 'default-unknown'
  // Keep only alphanumeric + dash; strip braces/pipes that would upset URL / FS
  const safe = sessionId.replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 8)
  return `session-${safe || 'unknown'}`
}

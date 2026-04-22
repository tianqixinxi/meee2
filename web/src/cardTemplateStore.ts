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
 */
export async function getTemplate(id: string): Promise<TemplateEntry | null> {
  return jsonRequest<TemplateEntry>(
    `/api/card-templates/${encodeURIComponent(id)}`,
  )
}

export async function putTemplate(
  id: string,
  source: string,
): Promise<TemplateEntry> {
  const r = await jsonRequest<TemplateEntry>(
    `/api/card-templates/${encodeURIComponent(id)}`,
    {
      method: 'PUT',
      body: JSON.stringify({ source }),
    },
  )
  if (!r) throw new Error('Empty response from PUT /api/card-templates/' + id)
  return r
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

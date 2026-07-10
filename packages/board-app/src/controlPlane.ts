const CONTROL_HEADER = 'X-Meee2-Control-Token'
const BOOTSTRAP_PATH = '/api/control/bootstrap'
const MUTATING_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE'])

let transportFetch: typeof fetch | null = null
let tokenPromise: Promise<string> | null = null
let installed = false

function metaToken(): string | null {
  if (typeof document === 'undefined') return null
  const value = document
    .querySelector<HTMLMetaElement>('meta[name="meee2-control-token"]')
    ?.content.trim()
  return value || null
}

function fetchTransport(): typeof fetch {
  if (transportFetch) return transportFetch
  return globalThis.fetch.bind(globalThis)
}

export async function getControlToken(forceRefresh = false): Promise<string> {
  if (forceRefresh) tokenPromise = null
  if (!tokenPromise) {
    const embedded = forceRefresh ? null : metaToken()
    tokenPromise = embedded
      ? Promise.resolve(embedded)
      : fetchTransport()(BOOTSTRAP_PATH, {
          method: 'GET',
          headers: { Accept: 'application/json' },
          cache: 'no-store',
          credentials: 'same-origin',
        }).then(async (response) => {
          if (!response.ok) {
            throw new Error(`Board control bootstrap failed: HTTP ${response.status}`)
          }
          const body = await response.json() as { controlToken?: unknown }
          if (typeof body.controlToken !== 'string' || !body.controlToken) {
            throw new Error('Board control bootstrap returned no token')
          }
          return body.controlToken
        })
  }
  return tokenPromise
}

function requestMethod(input: RequestInfo | URL, init?: RequestInit): string {
  return (init?.method ?? (input instanceof Request ? input.method : 'GET')).toUpperCase()
}

function isLocalBoardAPI(input: RequestInfo | URL): boolean {
  if (typeof location === 'undefined') return false
  const raw = input instanceof Request ? input.url : String(input)
  const url = new URL(raw, location.href)
  return url.origin === location.origin && url.pathname.startsWith('/api/')
}

async function authorizedFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const method = requestMethod(input, init)
  if (!MUTATING_METHODS.has(method) || !isLocalBoardAPI(input)) {
    return fetchTransport()(input, init)
  }

  const perform = async (forceRefresh: boolean): Promise<Response> => {
    const token = await getControlToken(forceRefresh)
    const headers = new Headers(input instanceof Request ? input.headers : undefined)
    new Headers(init?.headers).forEach((value, key) => headers.set(key, value))
    headers.set(CONTROL_HEADER, token)
    return fetchTransport()(input, { ...init, headers })
  }

  let response = await perform(false)
  // A BoardServer restart invalidates the old launch token while a Vite tab or
  // long-lived WebView may still be open. Bootstrap once and retry safely.
  if (response.status === 401) response = await perform(true)
  return response
}

/**
 * Install one authorization boundary for every current/future board caller,
 * including workspace packages that use fetch directly. External URLs and
 * read-only local requests pass through untouched.
 */
export function installControlPlaneFetch(baseFetch: typeof fetch = globalThis.fetch.bind(globalThis)): void {
  if (installed) return
  transportFetch = baseFetch
  globalThis.fetch = authorizedFetch as typeof fetch
  installed = true
}

export function controlPlaneWebSocketURL(): string {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws'
  return new URL(`${proto}://${location.host}/api/events`).toString()
}

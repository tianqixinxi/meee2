// Service worker — receives extracted conversation snapshots from content
// scripts and pushes them to local meee2.
//
// Why a worker (not direct fetch from content script): content scripts run
// inside the page's CSP. ChatGPT/Claude pages set strict CSP that may block
// localhost fetches. The service worker has its own context and is allowed
// to fetch localhost because we declared host_permissions.
//
// Retry strategy: if meee2 is unreachable, queue the payload in
// chrome.storage.local. On every successful push we also drain the queue.

const DEFAULT_PORT = 9876
const MAX_PORT = 9976
const API_URL_STORAGE_KEY = 'meee2ApiUrl'
let cachedMeee2URL = null

/** in-memory dedupe — { sid: lastSignature } so we don't repush identical
 *  state on every MutationObserver fire. */
const lastSig = new Map()

function sigOf(payload) {
  return payload.title + '|' + payload.recentMessages.length + '|' +
    (payload.recentMessages[payload.recentMessages.length - 1]?.text ?? '').slice(0, 80)
}

async function fetchWithTimeout(url, options = {}, timeoutMs = 1200) {
  return fetch(url, {
    ...options,
    signal: options.signal ?? AbortSignal.timeout(timeoutMs),
  })
}

async function isMeee2URL(baseURL) {
  try {
    const r = await fetchWithTimeout(`${baseURL}/api/health`)
    if (!r.ok) return false
    const json = await r.json().catch(() => null)
    return json?.name === 'meee2'
  } catch {
    return false
  }
}

async function discoverMeee2URL(force = false) {
  if (!force && cachedMeee2URL && await isMeee2URL(cachedMeee2URL)) {
    return cachedMeee2URL
  }

  const stored = await chrome.storage.local.get(API_URL_STORAGE_KEY)
  const storedURL = stored[API_URL_STORAGE_KEY]
  if (!force && storedURL && await isMeee2URL(storedURL)) {
    cachedMeee2URL = storedURL
    return storedURL
  }

  for (let port = DEFAULT_PORT; port <= MAX_PORT; port += 1) {
    const url = `http://127.0.0.1:${port}`
    if (await isMeee2URL(url)) {
      cachedMeee2URL = url
      await chrome.storage.local.set({ [API_URL_STORAGE_KEY]: url })
      return url
    }
  }

  throw new Error(`meee2 BoardServer unreachable on ${DEFAULT_PORT}-${MAX_PORT}`)
}

async function apiFetch(path, options) {
  let baseURL = await discoverMeee2URL()
  try {
    return await fetchWithTimeout(`${baseURL}${path}`, options, 2000)
  } catch (e) {
    baseURL = await discoverMeee2URL(true)
    return fetchWithTimeout(`${baseURL}${path}`, options, 2000)
  }
}

async function postJSON(path, body) {
  const r = await apiFetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  if (!r.ok) throw new Error(`HTTP ${r.status}`)
  return r.json()
}

async function deleteJSON(path) {
  const r = await apiFetch(path, { method: 'DELETE' })
  if (!r.ok && r.status !== 404) throw new Error(`HTTP ${r.status}`)
  return true
}

async function flushQueue() {
  const { meee2Queue = [] } = await chrome.storage.local.get('meee2Queue')
  if (meee2Queue.length === 0) return
  const remaining = []
  for (const item of meee2Queue) {
    try {
      if (item.kind === 'upsert') await postJSON('/api/external-sessions/upsert', item.body)
      else if (item.kind === 'delete') await deleteJSON(`/api/external-sessions/${encodeURIComponent(item.sid)}`)
    } catch {
      remaining.push(item)
      break  // stop draining if meee2 is back to unreachable
    }
  }
  await chrome.storage.local.set({ meee2Queue: remaining })
}

async function enqueue(item) {
  const { meee2Queue = [] } = await chrome.storage.local.get('meee2Queue')
  meee2Queue.push(item)
  // Cap to prevent runaway storage.
  if (meee2Queue.length > 200) meee2Queue.splice(0, meee2Queue.length - 200)
  await chrome.storage.local.set({ meee2Queue })
}

async function handleUpsert(payload) {
  // Dedupe: skip identical payload repeats from the same conversation.
  const key = `${payload.source}:${payload.externalId}`
  const sig = sigOf(payload)
  if (lastSig.get(key) === sig) return { ok: true, deduped: true }
  lastSig.set(key, sig)

  try {
    const result = await postJSON('/api/external-sessions/upsert', payload)
    void flushQueue()  // opportunistic drain
    return { ok: true, sid: result.sid, isNew: result.isNew }
  } catch (e) {
    await enqueue({ kind: 'upsert', body: payload })
    return { ok: false, queued: true, error: e.message }
  }
}

async function handleClose({ source, externalId }) {
  const sid = `${source}-${externalId}`
  lastSig.delete(`${source}:${externalId}`)
  try {
    await deleteJSON(`/api/external-sessions/${encodeURIComponent(sid)}`)
    return { ok: true }
  } catch (e) {
    await enqueue({ kind: 'delete', sid })
    return { ok: false, queued: true, error: e.message }
  }
}

async function checkConnection() {
  try {
    const url = await discoverMeee2URL()
    return { ok: true, url }
  } catch {
    return { ok: false }
  }
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type === 'meee2.upsert') {
    handleUpsert(msg.payload).then(sendResponse)
    return true  // async response
  }
  if (msg?.type === 'meee2.close') {
    handleClose(msg.payload).then(sendResponse)
    return true
  }
  if (msg?.type === 'meee2.ping') {
    checkConnection().then(sendResponse)
    return true
  }
  return false
})

// Drain queued items on worker startup, periodically, and whenever a
// chat-host tab gains focus (most likely moment to recheck connection).
flushQueue().catch(() => {})

// MV3 service workers can be evicted; setInterval doesn't survive eviction.
// Use chrome.alarms which wakes the worker reliably for the drain.
chrome.alarms.create('meee2.drain', { periodInMinutes: 0.5 })
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'meee2.drain') flushQueue().catch(() => {})
})

chrome.tabs.onActivated.addListener(({ tabId }) => {
  chrome.tabs.get(tabId, (tab) => {
    if (chrome.runtime.lastError) return
    const url = tab?.url ?? ''
    if (/^https:\/\/(chatgpt\.com|chat\.openai\.com|claude\.ai)\//.test(url)) {
      flushQueue().catch(() => {})
    }
  })
})

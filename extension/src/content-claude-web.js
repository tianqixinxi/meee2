// Claude.ai content script — same pattern as content-chatgpt.js but for
// claude.ai's React UI.
//
// Selectors (as of 2026-04):
//   - Conversation id is in URL: /chat/<uuid>
//   - Messages are in [data-testid="user-message"] and div under
//     [class*="prose"] for assistant. We use a few fallbacks because Claude.ai
//     reorganizes its tree more often than ChatGPT.

const SOURCE = 'claude-web'
const DEBOUNCE_MS = 600
const POLL_MS = 5000
const MAX_RECENT = 20

let currentConversationId = null
let debounceTimer = null
let observer = null
let pollTimer = null

function log(...args) {
  if (globalThis.MEEE2_BRIDGE_DEBUG === true) {
    console.log('[meee2-bridge]', ...args)
  }
}

function readConversationId() {
  const m = location.pathname.match(/\/chat\/([a-zA-Z0-9_-]+)/)
  return m ? m[1] : null
}

function readTitle() {
  // Claude.ai puts the conversation title in the page <title> as
  // "Title - Claude". Strip the suffix.
  return document.title.replace(/\s*[-–—]\s*Claude\s*$/, '').trim().slice(0, 200) || 'Claude'
}

/** Walk the DOM extracting user + assistant turns in order. */
function extractMessages() {
  const out = []

  // 1. Newer Claude.ai: each turn is a div with data-testid containing
  //    "user-message" or just bare assistant content under [class*="prose"].
  //    We iterate top-to-bottom to keep order.
  const candidates = document.querySelectorAll(
    '[data-testid="user-message"], [data-test-render-count], div.font-claude-message'
  )
  if (candidates.length > 0) {
    for (const node of candidates) {
      let role = null
      if (node.matches('[data-testid="user-message"]')) {
        role = 'user'
      } else if (node.matches('div.font-claude-message')) {
        role = 'assistant'
      } else {
        // [data-test-render-count] is also assistant in current UI
        role = 'assistant'
      }
      const text = (node.innerText || node.textContent || '').trim()
      if (!text) continue
      out.push({ role, text: text.slice(0, 8000) })
    }
    return out
  }

  // 2. Fallback — generic markers.
  const generic = document.querySelectorAll('[data-message-author-role], .message')
  for (const node of generic) {
    const role = node.getAttribute?.('data-message-author-role') ||
      (node.classList.contains('user') ? 'user' :
        node.classList.contains('assistant') ? 'assistant' : null)
    if (!role) continue
    const text = (node.innerText || node.textContent || '').trim()
    if (!text) continue
    out.push({ role, text: text.slice(0, 8000) })
  }
  return out
}

function buildPayload() {
  const id = readConversationId()
  if (!id) return null
  const messages = extractMessages()
  if (messages.length === 0) return null
  return {
    source: SOURCE,
    externalId: id,
    title: readTitle(),
    url: location.href,
    status: 'idle',
    recentMessages: messages.slice(-MAX_RECENT),
  }
}

async function push() {
  const payload = buildPayload()
  if (!payload) return
  const prevId = currentConversationId
  currentConversationId = payload.externalId
  if (prevId && prevId !== currentConversationId) {
    chrome.runtime.sendMessage({
      type: 'meee2.close',
      payload: { source: SOURCE, externalId: prevId },
    })
  }
  try {
    const result = await chrome.runtime.sendMessage({ type: 'meee2.upsert', payload })
    if (!result?.ok && !result?.queued) log('upsert failed:', result?.error)
  } catch (e) {
    log('sendMessage failed:', e.message)
  }
}

function schedulePush() {
  if (debounceTimer) clearTimeout(debounceTimer)
  debounceTimer = setTimeout(push, DEBOUNCE_MS)
}

function startObserving() {
  observer?.disconnect()
  observer = new MutationObserver(() => schedulePush())
  observer.observe(document.body, { childList: true, subtree: true, characterData: true })
}

function startPolling() {
  if (pollTimer) clearInterval(pollTimer)
  pollTimer = setInterval(() => schedulePush(), POLL_MS)
}

function init() {
  log('content script loaded for', location.href)
  startObserving()
  startPolling()
  setTimeout(push, 1500)

  // SPA route hooks (Claude.ai also uses pushState).
  const origPush = history.pushState
  const origReplace = history.replaceState
  history.pushState = function (...args) { origPush.apply(this, args); schedulePush() }
  history.replaceState = function (...args) { origReplace.apply(this, args); schedulePush() }
  window.addEventListener('popstate', schedulePush)

  window.addEventListener('beforeunload', () => {
    if (currentConversationId) {
      try {
        chrome.runtime.sendMessage({
          type: 'meee2.close',
          payload: { source: SOURCE, externalId: currentConversationId },
        })
      } catch {}
    }
    observer?.disconnect()
    if (pollTimer) clearInterval(pollTimer)
  })
}

init()

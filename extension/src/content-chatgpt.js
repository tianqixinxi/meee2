// ChatGPT content script — observes the conversation DOM and pushes
// snapshots to the service worker (which forwards to local meee2).
//
// Selectors as of 2026-04: messages live under
//   article[data-testid^="conversation-turn-"]
// with author tagged via
//   [data-message-author-role="user"|"assistant"]
//
// If OpenAI changes the DOM these break — we use multiple fallback
// selectors. Logs go to console with [meee2] prefix so you can debug
// in DevTools without the page noise.

const SOURCE = 'chatgpt-web'
const DEBOUNCE_MS = 600
const POLL_MS = 5000              // safety-net poll in case observer misses
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

/** Pull conversation id from URL: /c/<uuid> or /chat/<uuid> */
function readConversationId() {
  const m = location.pathname.match(/\/(?:c|chat)\/([a-zA-Z0-9_-]+)/)
  return m ? m[1] : null
}

function readTitle() {
  // Try sidebar's active conversation title first (richer).
  const active = document.querySelector('a[aria-current="page"]')
  if (active?.textContent) return active.textContent.trim().slice(0, 200)
  // Fallback: document title minus "ChatGPT - " prefix.
  return document.title.replace(/^ChatGPT\s*[-–—]\s*/, '').trim().slice(0, 200) || 'ChatGPT'
}

/** Extract array of {role, text} for the visible conversation. */
function extractMessages() {
  const out = []

  // Primary selector — newer ChatGPT UI.
  const turns = document.querySelectorAll('article[data-testid^="conversation-turn-"]')
  if (turns.length > 0) {
    for (const turn of turns) {
      const node = turn.querySelector('[data-message-author-role]')
      if (!node) continue
      const role = node.getAttribute('data-message-author-role')
      if (role !== 'user' && role !== 'assistant') continue
      const text = (node.innerText || node.textContent || '').trim()
      if (!text) continue
      out.push({ role, text: text.slice(0, 8000) })
    }
    return out
  }

  // Fallback for older UI.
  const fallback = document.querySelectorAll('[data-message-author-role]')
  for (const node of fallback) {
    const role = node.getAttribute('data-message-author-role')
    if (role !== 'user' && role !== 'assistant') continue
    const text = (node.innerText || node.textContent || '').trim()
    if (!text) continue
    out.push({ role, text: text.slice(0, 8000) })
  }
  return out
}

function buildPayload() {
  const id = readConversationId()
  if (!id) return null  // not on a conversation page (could be on /, /new, etc)
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
  // If the user navigated from one conversation to another, close the old one
  // so its card isn't stuck on the meee2 board pretending to be active.
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
  // Observe the whole document — ChatGPT's React tree shuffles often, and
  // narrowing to a stable container hasn't been reliable across UI changes.
  observer?.disconnect()
  observer = new MutationObserver(() => schedulePush())
  observer.observe(document.body, { childList: true, subtree: true, characterData: true })
}

function stopObserving() {
  observer?.disconnect()
  observer = null
}

function startPolling() {
  if (pollTimer) clearInterval(pollTimer)
  pollTimer = setInterval(() => schedulePush(), POLL_MS)
}

function init() {
  log('content script loaded for', location.href)
  startObserving()
  startPolling()
  // First push after the page settles.
  setTimeout(push, 1500)

  // Listen for SPA route changes — ChatGPT uses pushState, no full reload.
  const origPush = history.pushState
  const origReplace = history.replaceState
  history.pushState = function (...args) { origPush.apply(this, args); schedulePush() }
  history.replaceState = function (...args) { origReplace.apply(this, args); schedulePush() }
  window.addEventListener('popstate', schedulePush)

  // Cleanup on unload.
  window.addEventListener('beforeunload', () => {
    if (currentConversationId) {
      // sendMessage in beforeunload is best-effort; service worker may handle it
      // if the message reaches before the page tears down.
      try {
        chrome.runtime.sendMessage({
          type: 'meee2.close',
          payload: { source: SOURCE, externalId: currentConversationId },
        })
      } catch {}
    }
    stopObserving()
    if (pollTimer) clearInterval(pollTimer)
  })
}

init()

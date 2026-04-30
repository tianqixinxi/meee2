// Popup — show meee2 connectivity + queue size.

async function refresh() {
  const conn = document.getElementById('conn')
  const queue = document.getElementById('queue')
  const boardLink = document.getElementById('board-link')

  const result = await chrome.runtime.sendMessage({ type: 'meee2.ping' }).catch(() => ({ ok: false }))
  conn.textContent = result?.ok ? 'connected' : 'unreachable'
  conn.className = 'value ' + (result?.ok ? 'ok' : 'bad')
  if (result?.url && boardLink) {
    boardLink.href = result.url
  }

  const { meee2Queue = [] } = await chrome.storage.local.get('meee2Queue')
  queue.textContent = meee2Queue.length === 0 ? '0' : `${meee2Queue.length} pending`
  queue.className = 'value ' + (meee2Queue.length === 0 ? 'ok' : 'bad')
}

refresh()
setInterval(refresh, 3000)

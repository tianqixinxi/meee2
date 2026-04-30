# meee2 web chat bridge

Chrome / Edge extension that mirrors your ChatGPT (and soon Claude.ai)
web conversations into the **local meee2 board**, which then propagates
them to **meee360** through the existing push pipeline.

## How it works

```
chatgpt.com tab
  └─ content-chatgpt.js (MutationObserver on conversation DOM)
       │
       │ chrome.runtime.sendMessage
       ▼
  service-worker.js
       │
       │ POST /api/external-sessions/upsert
       ▼
  meee2 BoardServer (localhost:9876)
       │
       ├─ ExternalChatPlugin keeps in-memory store
       ├─ broadcastStateChanged → meee2 webui card appears
       └─ Meee360Pusher → meee360 supabase row
```

The extension **never** talks to OpenAI / Anthropic / Supabase directly.
It only reads visible DOM from the user's already-loaded chat tab and
forwards a JSON snapshot to localhost.

## Install (developer / sideload)

1. Open Chrome → `chrome://extensions`
2. Enable **Developer mode** (top-right toggle)
3. Click **Load unpacked**, pick `extension/` directory
4. Pin the icon in the toolbar (optional)

After install, open https://chatgpt.com and start any conversation —
within a few seconds a card titled "ChatGPT" should appear on
http://localhost:9876.

## Files

- `manifest.json` — MV3 manifest
- `src/content-chatgpt.js` — chatgpt.com DOM observer
- `src/content-claude-web.js` — claude.ai DOM observer
- `src/service-worker.js` — push to meee2, retry queue, chrome.alarms drain
- `src/popup.{html,js}` — connection status + queue size

## Offline behaviour

If meee2 isn't running when a snapshot is captured, the payload is queued
in `chrome.storage.local`. Drain triggers:

- service worker startup
- `chrome.alarms` every 30 s
- focusing a chatgpt.com / claude.ai tab
- next successful upsert

Queue capped at 200 items (oldest dropped).

## Selector fragility

ChatGPT and Claude.ai redesign their conversation UI every few months.
If cards stop appearing, open DevTools on the chat tab and check
`[meee2-bridge]` console output. Update the selectors in the relevant
`content-*.js` and reload the extension.

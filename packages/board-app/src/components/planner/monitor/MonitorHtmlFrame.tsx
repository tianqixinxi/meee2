/**
 * MonitorHtmlFrame (canvas-spec §7.2 + §14) — renders a planner-authored HTML
 * Monitor SAFELY in a sandboxed iframe and feeds it the read-only
 * CanvasRuntimeView snapshot.
 *
 * A Monitor is an Artifact{source:canvas-runtime, widget:{kind:'html', html}}.
 * The `html` string is authored by the planner/AI, so it is UNTRUSTED. This
 * component renders it under a hard sandbox so it can visualize the runtime
 * data but can NOT escape to the parent page, localhost APIs, or the network.
 *
 * ── Why it is safe (defense in depth) ───────────────────────────────────────
 * 1. iframe sandbox = "allow-scripts" ONLY — crucially WITHOUT
 *    "allow-same-origin". An `allow-scripts` srcdoc iframe without
 *    `allow-same-origin` runs in an *opaque, unique origin*: it cannot read
 *    `window.parent`/`window.top` cross-origin, cannot read parent cookies /
 *    localStorage, cannot use `fetch`/`XHR` against same-origin (or anywhere —
 *    see CSP). No `allow-forms`, `allow-popups`, `allow-top-navigation`, etc.
 * 2. We deliberately DO NOT inline the snapshot into the HTML. The HTML loads
 *    in the opaque origin, then we hand it data ONLY via `postMessage`. So the
 *    AI HTML never runs in a context that shares our origin.
 * 3. A strict CSP <meta> inside the srcdoc: `default-src 'none'` (so no
 *    network: no connect-src/img-src/script-src remote, no `fetch`, no
 *    WebSocket, no beacon), allowing only inline `style`/`script` so the
 *    authored HTML can actually render + run its postMessage listener.
 *    `connect-src` is omitted → falls back to default-src 'none' → all network
 *    egress is blocked.
 * 4. We validate `event.source === iframe.contentWindow` before posting nothing
 *    back, and we never read anything FROM the iframe — the data flow is strictly
 *    parent → iframe.
 *
 * ── Live updates ────────────────────────────────────────────────────────────
 * We post the snapshot once the iframe signals ready (or on a short fallback
 * timer) and re-post on every `runtime` prop change, so the monitor stays live
 * as the canvas runtime evolves.
 */

import { useEffect, useMemo, useRef } from 'react'
import type { CanvasRuntimeView } from '../../../types'

export interface MonitorHtmlFrameProps {
  /** Planner-authored HTML (untrusted). */
  html: string
  /** Read-only runtime snapshot injected via postMessage. */
  runtime: CanvasRuntimeView | null | undefined
  /** Optional title for the frame chrome / a11y label. */
  title?: string
}

// Strict CSP: no network at all (default-src 'none' covers connect/img/font/
// frame/etc.), only inline style + script so the authored HTML can render and
// run its message listener. No 'unsafe-eval'. No remote anything.
const MONITOR_CSP =
  "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'"

/** The message type the parent posts into the iframe. */
const RUNTIME_MESSAGE_TYPE = 'meee2:canvas-runtime'

/**
 * Wrap the planner HTML in a minimal document that carries the CSP meta and a
 * tiny bootstrap which (a) signals readiness and (b) re-exposes the latest
 * snapshot on `window.__canvasRuntime` + dispatches a `canvasruntime` event
 * for convenience. The authored HTML can either listen for the raw
 * `message` event or the convenience `canvasruntime` CustomEvent.
 */
function buildSrcdoc(html: string): string {
  // NOTE: html is untrusted but it executes ONLY inside the opaque-origin
  // sandbox under the CSP above — it cannot reach our origin or the network.
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<meta http-equiv="Content-Security-Policy" content="${MONITOR_CSP}" />
<style>html,body{margin:0;padding:0;font:13px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;color:#e6e6e6;background:transparent}</style>
</head>
<body>
<script>
  // Bootstrap: receive the read-only snapshot from the parent and re-expose it.
  window.__canvasRuntime = null;
  window.addEventListener('message', function (ev) {
    var data = ev && ev.data;
    if (!data || data.type !== ${JSON.stringify(RUNTIME_MESSAGE_TYPE)}) return;
    window.__canvasRuntime = data.runtime || null;
    try {
      window.dispatchEvent(new CustomEvent('canvasruntime', { detail: window.__canvasRuntime }));
    } catch (e) {}
  });
  // Tell the parent we are ready to receive the first snapshot.
  try { if (window.parent) window.parent.postMessage({ type: 'meee2:monitor-ready' }, '*'); } catch (e) {}
</script>
${html}
</body>
</html>`
}

export function MonitorHtmlFrame({ html, runtime, title }: MonitorHtmlFrameProps) {
  const iframeRef = useRef<HTMLIFrameElement | null>(null)
  const readyRef = useRef(false)
  const srcdoc = useMemo(() => buildSrcdoc(html), [html])

  // Re-key the iframe when the HTML changes so srcdoc fully reloads (and the
  // ready handshake re-runs). Stable across pure runtime updates.
  const post = (rt: CanvasRuntimeView | null | undefined) => {
    const win = iframeRef.current?.contentWindow
    if (!win) return
    // targetOrigin '*' is required: an opaque-origin srcdoc iframe has no
    // resolvable origin to target. This is safe because the payload is the
    // already-public read-only runtime snapshot (no secrets) and the iframe
    // cannot send anything back into our origin.
    win.postMessage({ type: RUNTIME_MESSAGE_TYPE, runtime: rt ?? null }, '*')
  }

  // Listen for the iframe's ready handshake; post the current snapshot then.
  useEffect(() => {
    readyRef.current = false
    function onMessage(ev: MessageEvent) {
      if (ev.source !== iframeRef.current?.contentWindow) return
      if (ev.data?.type === 'meee2:monitor-ready') {
        readyRef.current = true
        post(runtime)
      }
    }
    window.addEventListener('message', onMessage)
    // Fallback: if the ready signal is missed (e.g. HTML stripped our script),
    // post on a short timer too. Harmless if the iframe ignores it.
    const t = window.setTimeout(() => post(runtime), 300)
    return () => {
      window.removeEventListener('message', onMessage)
      window.clearTimeout(t)
    }
    // Re-run when the document reloads (srcdoc changed).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [srcdoc])

  // Re-post whenever the snapshot changes so the monitor stays live.
  useEffect(() => {
    if (readyRef.current) post(runtime)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [runtime])

  return (
    <iframe
      ref={iframeRef}
      className="planner-monitor-html-frame"
      title={title ?? 'Monitor'}
      // SECURITY: allow-scripts WITHOUT allow-same-origin → opaque unique
      // origin. Do NOT add allow-same-origin / allow-forms / allow-popups /
      // allow-top-navigation here.
      sandbox="allow-scripts"
      srcDoc={srcdoc}
      // No referrer leakage from the opaque doc.
      referrerPolicy="no-referrer"
    />
  )
}

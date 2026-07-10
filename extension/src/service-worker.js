// The web-chat ingestion bridge is retired.
//
// BoardServer no longer accepts external-session mutations, and launch-scoped
// control credentials intentionally are not exposed to browser extensions.
// Keep this compatibility response while older sideloaded manifests wind down;
// it performs no localhost discovery, network request, or payload persistence.

const RETIRED_MESSAGE =
  'Web chat ingestion is retired. Meee2 now displays only sessions it creates.'

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (['meee2.upsert', 'meee2.close', 'meee2.ping'].includes(message?.type)) {
    sendResponse({ ok: false, retired: true, error: RETIRED_MESSAGE })
  }
  return false
})

# Updates

meee2 uses a layered update model. The native macOS app remains the trust
anchor; everything that can change outside the signed app bundle is versioned,
hashable, and selected through an explicit manifest.

## Native App

The signed `.app` should be updated with Sparkle.

Sparkle owns:

- checking the appcast
- downloading signed/notarized app archives
- replacing the installed app
- relaunching after the user chooses to install

This is the path for Swift code, the BoardServer, entitlements, bundled
plugins, and the fallback WebDist.

The current client uses `SPUUpdater` with `SilentInstallUserDriver`:

- Sparkle automatic checks are enabled with `SUScheduledCheckInterval=3600`.
- `AppDelegate` also kicks one background check shortly after launch.
- Background checks download, verify, and stage the DMG, then halt before
  install.
- The Board Update pill polls `/api/version` locally; no push channel is
  required for update discovery.
- When the user clicks the pill, the already staged update is applied and the
  app relaunches immediately. If the staged version is stale or missing, the app
  runs a user-initiated Sparkle check and installs the current latest version.

## Board Shell

The menu bar item opens a native `WKWebView` shell instead of the system
browser. The shell always loads BoardServer:

- `http://127.0.0.1:9876` when the preferred port is available
- the next free local port in `9876...9976` when `9876` is occupied
- bundled WebDist by default
- OTA WebDist when `current.json` selects a valid downloaded WebDist

The chosen port is stable for the lifetime of the app process and is written to
`~/Library/Application Support/meee2/board-server.json` for local integrations.
`MEEE2_BOARD_PORT` changes the preferred starting port.

The Vite dev server is a separate developer-only debugging surface:

```bash
pnpm dev:web
# or
pnpm dev:shell
```

The BoardServer still prefers `9876`, so Vite proxies `/api` and `/api/events`
back to that port by default. Set `MEEE2_BOARD_PORT` or `MEEE2_BOARD_API_URL`
when running against a different local BoardServer port.
`Open Board` never uses the Vite port; debug builds expose `Open Board Dev
(Vite)` from the menu for local WebUI debugging. `pnpm dev:shell` opens the
Vite page directly, and its URL can be overridden with `MEEE2_BOARD_VITE_URL`.

## WebDist OTA

BoardServer resolves WebDist in this order:

1. active OTA WebDist selected by
   `~/Library/Application Support/meee2/WebDist/current.json`
2. bundled `Sources/Board/WebDist` resource

`current.json` format:

```json
{
  "version": "1.2.3",
  "path": "versions/1.2.3"
}
```

The path must point inside `~/Library/Application Support/meee2/WebDist/` and
the selected directory must contain `index.html`. Invalid manifests are ignored
and the bundled WebDist is used.

The downloader/notifier layer should only switch `current.json` after it has:

- fetched a manifest over HTTPS
- verified the payload hash
- verified a publisher signature
- unpacked into a versioned directory
- left the previous version available for rollback

## Plugins And Agent Runtime

Native plugins and agent helpers should be installed into versioned directories
and activated for new sessions. Already-loaded dylibs should not be unloaded and
replaced in-process; restart the app or host plugins out-of-process if live
plugin replacement becomes necessary.

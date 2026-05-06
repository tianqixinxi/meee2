#!/bin/bash
# scripts/notarize.sh — submit a signed DMG to Apple's notary service,
# wait for the verdict, staple the ticket onto the DMG (and the .app inside).
#
# Prerequisites:
#   1. The DMG (and its .app contents) must already be signed with a real
#      Developer ID Application identity, hardened runtime, secure timestamp.
#      (build.sh / create-dmg.sh handle that when IDENTITY is set.)
#   2. Notary credentials stored in your keychain under a profile alias.
#      Create the alias once with:
#          xcrun notarytool store-credentials <PROFILE> \
#              --apple-id  you@example.com \
#              --team-id   ABCDE12345 \
#              --password  <app-specific-password>
#      Generate the app-specific password at https://appleid.apple.com/
#      (Sign-In and Security → App-Specific Passwords).
#
# Usage:
#   NOTARY_PROFILE=meee2-notary ./scripts/notarize.sh dist/meee2-v1.2.3.dmg
#
# Inputs:
#   $1                — path to the DMG.
#   NOTARY_PROFILE    — keychain profile alias (required).
#   STAPLE_APP=1      — also staple the .app inside the DMG (optional, default off).
#                       Useful if you ship the .app outside the DMG (e.g. a zip
#                       embedded in your CI artifact). Mounts the DMG read-only,
#                       copies the app, staples, repacks. Slow.

set -euo pipefail

DMG="${1:-}"
if [ -z "$DMG" ]; then
    echo "Usage: NOTARY_PROFILE=<alias> $0 <dmg-path>" >&2
    exit 1
fi
if [ ! -f "$DMG" ]; then
    echo "DMG not found: $DMG" >&2
    exit 1
fi
if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "NOTARY_PROFILE env not set. Create one with:" >&2
    echo "    xcrun notarytool store-credentials <PROFILE> --apple-id ... --team-id ... --password ..." >&2
    exit 1
fi

echo "==> Submitting $DMG to Apple notary service (profile=$NOTARY_PROFILE)…"
echo "    This typically takes 1-5 minutes."

# `--wait` blocks until the verdict is in. Without it we'd just get a
# submission UUID and have to poll separately.
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format plist > /tmp/notarytool-output.plist

STATUS=$(/usr/libexec/PlistBuddy -c 'Print :status' /tmp/notarytool-output.plist 2>/dev/null || echo unknown)
SUBMISSION_ID=$(/usr/libexec/PlistBuddy -c 'Print :id' /tmp/notarytool-output.plist 2>/dev/null || echo unknown)

echo "==> Notary verdict: $STATUS  (submission=$SUBMISSION_ID)"

if [ "$STATUS" != "Accepted" ]; then
    echo
    echo "Notarization did NOT succeed. Pulling the developer log:"
    xcrun notarytool log "$SUBMISSION_ID" \
        --keychain-profile "$NOTARY_PROFILE" \
        /tmp/notarytool-log.json || true
    cat /tmp/notarytool-log.json 2>/dev/null || true
    exit 1
fi

echo "==> Stapling ticket to ${DMG}…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

if [ "${STAPLE_APP:-0}" = "1" ]; then
    echo "==> STAPLE_APP=1 — also stapling the .app inside the DMG"
    MOUNT_POINT=$(mktemp -d /tmp/meee2-staple.XXXXXX)
    hdiutil attach "$DMG" -readonly -mountpoint "$MOUNT_POINT" >/dev/null
    APP_INSIDE="$MOUNT_POINT/meee2.app"
    if [ -d "$APP_INSIDE" ]; then
        WORKDIR=$(mktemp -d /tmp/meee2-staple-work.XXXXXX)
        cp -R "$APP_INSIDE" "$WORKDIR/"
        hdiutil detach "$MOUNT_POINT" >/dev/null
        xcrun stapler staple "$WORKDIR/meee2.app"
        echo "    Stapled .app at: $WORKDIR/meee2.app"
        echo "    (re-bundling the DMG with stapled .app is left to caller)"
    else
        hdiutil detach "$MOUNT_POINT" >/dev/null
        echo "    .app not found inside DMG; skipping"
    fi
fi

echo "==> Notarization complete. Distribute $DMG."

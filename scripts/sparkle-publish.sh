#!/bin/bash
# scripts/sparkle-publish.sh — append (or replace) one <item> in
# repo-root appcast.xml for a notarized GitHub Release that's already
# uploaded.
#
# Usage:
#   VERSION=0.3.0-rc2 ./scripts/sparkle-publish.sh
#
# Inputs:
#   $VERSION                  — release tag suffix (without leading "v"). Required.
#   $SPARKLE_ED_PRIVATE_KEY   — path to raw EdDSA private key file (44-byte
#                               base64). Defaults to ~/.meee2/sparkle/ed25519-priv.key.
#                               In CI, the workflow first decodes the
#                               SPARKLE_ED_PRIVATE_KEY_BASE64 secret to a
#                               tmp file and points this at it.
#   $SPARKLE_BIN              — path to sign_update binary. If unset, the
#                               script downloads sparkle-project/Sparkle
#                               2.9.1 to /tmp on demand.
#   $REPO                     — owner/repo for `gh api` calls. Defaults to
#                               the current git remote (gh resolves it).
#
# Output:
#   - Updates ./appcast.xml (creates skeleton if absent).
#   - Prints a one-line summary.
#
# Idempotent: re-running with the same VERSION replaces the existing
# <item> for that version (so re-publishing a re-built DMG works without
# duplicate entries).

set -euo pipefail

VERSION="${VERSION:-}"
if [ -z "$VERSION" ]; then
    echo "ERROR: VERSION env required (e.g. VERSION=0.3.0-rc2)" >&2
    exit 1
fi
TAG="v${VERSION}"

PRIV_KEY="${SPARKLE_ED_PRIVATE_KEY:-$HOME/.meee2/sparkle/ed25519-priv.key}"
if [ ! -f "$PRIV_KEY" ]; then
    echo "ERROR: private key not found at $PRIV_KEY" >&2
    echo "       set SPARKLE_ED_PRIVATE_KEY=<path> or run generate_keys -x" >&2
    exit 1
fi

# ── locate or fetch sign_update ────────────────────────────────────────
SIGN_UPDATE="${SPARKLE_BIN:-}"
if [ -z "$SIGN_UPDATE" ]; then
    SPARKLE_DIR=/tmp/sparkle-2.9.1
    if [ ! -x "$SPARKLE_DIR/bin/sign_update" ]; then
        echo "==> fetching Sparkle 2.9.1 for sign_update..."
        rm -rf "$SPARKLE_DIR" && mkdir -p "$SPARKLE_DIR" && cd "$SPARKLE_DIR"
        curl -sL --fail \
            "https://github.com/sparkle-project/Sparkle/releases/download/2.9.1/Sparkle-2.9.1.tar.xz" \
            -o sparkle.tar.xz
        tar xf sparkle.tar.xz
        cd - >/dev/null
    fi
    SIGN_UPDATE="$SPARKLE_DIR/bin/sign_update"
fi

# ── pull release info ──────────────────────────────────────────────────
REPO_FLAG=()
if [ -n "${REPO:-}" ]; then REPO_FLAG=(--repo "$REPO"); fi

REL_JSON=$(gh release view "$TAG" "${REPO_FLAG[@]}" --json url,publishedAt,assets,body 2>/dev/null) || {
    echo "ERROR: GitHub Release $TAG not found (publish DMG to Releases first)" >&2
    exit 1
}
DMG_NAME="meee2-${TAG}.dmg"
DMG_URL=$(echo "$REL_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for a in d['assets']:
    if a['name']=='${DMG_NAME}':
        print(a['url']); break
")
if [ -z "$DMG_URL" ]; then
    echo "ERROR: $DMG_NAME not found in release $TAG assets" >&2
    exit 1
fi
PUB_DATE=$(echo "$REL_JSON" | python3 -c "
import json,sys
from email.utils import format_datetime
from datetime import datetime, timezone
ts=json.load(sys.stdin)['publishedAt']
# GH gives ISO 8601 with 'Z'; Python's fromisoformat needs +00:00 in <3.11
ts=ts.replace('Z','+00:00')
print(format_datetime(datetime.fromisoformat(ts).astimezone(timezone.utc)))
")
RELEASE_BODY=$(echo "$REL_JSON" | python3 -c "
import json,sys
print(json.load(sys.stdin)['body'] or '')
")

# ── download DMG (CI runner doesn't already have it; locally we may) ──
TMP_DMG=$(mktemp -t "meee2-sparkle.XXXXXX")
trap 'rm -f "$TMP_DMG"' EXIT
echo "==> downloading $DMG_NAME from release $TAG..."
gh release download "$TAG" "${REPO_FLAG[@]}" -p "$DMG_NAME" -O "$TMP_DMG" --clobber
DMG_BYTES=$(wc -c < "$TMP_DMG" | tr -d ' ')

# ── sign with EdDSA ───────────────────────────────────────────────────
echo "==> signing with EdDSA..."
SIGN_OUT=$("$SIGN_UPDATE" -f "$PRIV_KEY" "$TMP_DMG")
# sign_update prints `sparkle:edSignature="..." length="..."`
EDSIG=$(echo "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
SIGLEN=$(echo "$SIGN_OUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
if [ -z "$EDSIG" ] || [ -z "$SIGLEN" ]; then
    echo "ERROR: failed to parse sign_update output: $SIGN_OUT" >&2
    exit 1
fi
if [ "$SIGLEN" != "$DMG_BYTES" ]; then
    echo "WARN: sign_update length=$SIGLEN != actual=$DMG_BYTES (continuing with sign_update value)" >&2
fi

# ── render the new <item> + merge into ./appcast.xml ──────────────────
APPCAST=appcast.xml
mkdir -p "$(dirname "$APPCAST")"

ITEM_FILE=$(mktemp -t "meee2-item.XXXXXX")
# Description goes inside CDATA — escape the closing sequence ]]> if it
# happens to appear in the release body (rare, but cheap insurance).
ESCAPED_BODY=$(printf '%s' "$RELEASE_BODY" | sed 's|\]\]>|]]\&gt;|g')
cat > "$ITEM_FILE" <<EOF
        <item>
            <title>meee2 ${TAG}</title>
            <description><![CDATA[${ESCAPED_BODY}]]></description>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <enclosure
                url="https://github.com/tianqixinxi/meee2/releases/download/${TAG}/${DMG_NAME}"
                sparkle:version="${VERSION}"
                sparkle:shortVersionString="${VERSION}"
                type="application/octet-stream"
                sparkle:edSignature="${EDSIG}"
                length="${SIGLEN}" />
        </item>
EOF

python3 - "$APPCAST" "$ITEM_FILE" "$VERSION" <<'PY'
import sys, os, re, pathlib
appcast_path = pathlib.Path(sys.argv[1])
item = open(sys.argv[2]).read()
version = sys.argv[3]

if not appcast_path.exists():
    skeleton = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>meee2</title>
        <link>https://raw.githubusercontent.com/tianqixinxi/meee2/main/appcast.xml</link>
        <description>meee2 release feed</description>
        <language>en</language>
__INSERT_HERE__
    </channel>
</rss>
'''
    appcast_path.write_text(skeleton.replace('__INSERT_HERE__', item))
    print(f'created {appcast_path} with first item {version}')
    sys.exit(0)

xml = appcast_path.read_text()

# 1) drop any existing item whose <sparkle:version> matches (idempotent)
existing = re.search(
    r'\s*<item>(?:(?!</item>).)*<sparkle:version>%s</sparkle:version>(?:(?!</item>).)*</item>' % re.escape(version),
    xml, re.DOTALL,
)
if existing:
    xml = xml[:existing.start()] + xml[existing.end():]

# 2) insert new item right before the </channel> close tag
m = re.search(r'(\s*)</channel>', xml)
if not m:
    print('ERROR: appcast.xml missing </channel> close tag', file=sys.stderr)
    sys.exit(1)
xml = xml[:m.start()] + '\n' + item + m.group(0) + xml[m.end():]
appcast_path.write_text(xml)
print(f'updated {appcast_path} with item {version} ({"replaced" if existing else "added"})')
PY

rm -f "$ITEM_FILE"
echo "==> done. appcast entry for ${TAG}: ${EDSIG:0:24}... (length=${SIGLEN})"

#!/bin/bash
# scripts/lib-codesign.sh — shared signing helper. Source from build.sh /
# deploy.sh / create-dmg.sh, then call:
#
#   meee2_sign <path> [--entitlements <file>]
#
# Behaviour:
#  - If env IDENTITY is set (e.g. "Developer ID Application: Foo (TEAMID)"),
#    use it AND add hardened-runtime + secure-timestamp (required by Apple
#    notarization).
#  - Otherwise fall back to ad-hoc (`-`) and print a one-time warning.
#    Ad-hoc bundles can be opened locally but Gatekeeper blocks downloaded
#    DMGs unless the user right-click → Open. Ad-hoc cannot be notarized.
#
# Why a helper: build.sh / deploy.sh / create-dmg.sh all signed differently
# before — some had `--deep`, some didn't have entitlements on dylibs, none
# had hardened runtime. One function, one truth.
#
# Note: --options=runtime can only be set together with a real identity. With
# `--sign -` Apple's `codesign` rejects it.

# Guard double-sourcing
if [ -n "${MEEE2_CODESIGN_LIB_SOURCED:-}" ]; then
    return 0
fi
MEEE2_CODESIGN_LIB_SOURCED=1

# Print the warning at most once per process.
__meee2_warned_adhoc=0

meee2_sign() {
    local target="$1"; shift
    local entitlements=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --entitlements)
                entitlements="$2"
                shift 2
                ;;
            *)
                echo "meee2_sign: unknown arg $1" >&2
                return 2
                ;;
        esac
    done

    if [ ! -e "$target" ]; then
        echo "meee2_sign: target does not exist: $target" >&2
        return 1
    fi

    local args=(--force)

    if [ -n "${IDENTITY:-}" ]; then
        # Real identity → hardened runtime + secure timestamp + identity.
        # `--options=runtime` enables hardened runtime; required for
        # notarization. Without `--timestamp` notary submission rejects
        # the bundle ("must contain a secure timestamp").
        args+=(--sign "$IDENTITY" --options runtime --timestamp)
    else
        # Ad-hoc fallback. Warn once, since this is fine for local dev but
        # disastrous if it slips into a release build.
        if [ "$__meee2_warned_adhoc" = "0" ]; then
            echo "[codesign] WARNING: IDENTITY env not set — using ad-hoc signature."
            echo "[codesign]          Builds signed this way cannot be notarized."
            echo "[codesign]          For releases set:"
            echo "[codesign]            export IDENTITY='Developer ID Application: <Name> (<TEAMID>)'"
            __meee2_warned_adhoc=1
        fi
        args+=(--sign -)
    fi

    if [ -n "$entitlements" ]; then
        args+=(--entitlements "$entitlements")
    fi

    codesign "${args[@]}" "$target"
}

# Convenience: is the current run going to produce a notarization-capable
# bundle? Used by create-dmg.sh / release.yml to gate the notarize step.
meee2_signing_real() {
    [ -n "${IDENTITY:-}" ]
}

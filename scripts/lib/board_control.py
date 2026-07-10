#!/usr/bin/env python3
"""Read the current BoardServer control token without leaking it to logs.

Local scripts should import ``control_token`` or execute this file with
``--header``. The 0600 runtime-info file is authoritative; the same-origin
bootstrap endpoint is a fallback for development servers that do not publish a
runtime file in the caller's HOME.
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse


HEADER_NAME = "X-Meee2-Control-Token"
DEFAULT_BASE_URL = "http://127.0.0.1:9876"


class BoardControlTokenError(RuntimeError):
    """Raised when no safe current control token can be discovered."""


def runtime_info_path() -> Path:
    override = os.environ.get("MEEE2_BOARD_RUNTIME_INFO", "").strip()
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "meee2" / "board-server.json"


def _loopback_port(raw_url: str) -> int | None:
    parsed = urlparse(raw_url)
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost"}:
        return None
    return parsed.port or 80


def _token_from_runtime_info(base_url: str, path: Path) -> str | None:
    try:
        metadata = path.stat()
    except FileNotFoundError:
        return None
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600:
        raise BoardControlTokenError(f"refusing insecure runtime info permissions: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BoardControlTokenError(f"unreadable runtime info: {error}") from error

    runtime_url = payload.get("url")
    token = payload.get("controlToken")
    if not isinstance(runtime_url, str) or _loopback_port(runtime_url) != _loopback_port(base_url):
        return None
    if not isinstance(token, str) or not token:
        return None
    return token


def _token_from_bootstrap(base_url: str, timeout: float) -> str:
    url = base_url.rstrip("/") + "/api/control/bootstrap"
    request = urllib.request.Request(
        url,
        method="GET",
        headers={"Accept": "application/json", "Cache-Control": "no-store"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
        raise BoardControlTokenError(f"control bootstrap failed at {url}: {error}") from error
    token = payload.get("controlToken")
    if not isinstance(token, str) or not token:
        raise BoardControlTokenError("control bootstrap returned no token")
    return token


def control_token(
    base_url: str = DEFAULT_BASE_URL,
    *,
    info_path: Path | None = None,
    timeout: float = 2.0,
) -> str:
    if _loopback_port(base_url) is None:
        raise BoardControlTokenError(f"BoardServer URL must be loopback HTTP: {base_url}")
    token = _token_from_runtime_info(base_url, info_path or runtime_info_path())
    return token or _token_from_bootstrap(base_url, timeout)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=os.environ.get("MEEE2_BOARD_API_URL", DEFAULT_BASE_URL))
    parser.add_argument("--runtime-info", type=Path)
    parser.add_argument("--header", action="store_true", help="print a curl-compatible header")
    args = parser.parse_args(argv)
    try:
        token = control_token(args.base_url, info_path=args.runtime_info)
    except BoardControlTokenError as error:
        print(f"board-control-token: {error}", file=sys.stderr)
        return 1
    print(f"{HEADER_NAME}: {token}" if args.header else token)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Emit a deterministic, content-sensitive manifest for a filesystem tree.

The manifest intentionally contains hashes and metadata only, never file
contents.  It is used by the isolated-test gate to prove that a test command
did not mutate the developer/runner's real ~/.meee2 tree.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
import time
from pathlib import Path
from typing import Any


class TreeChangedDuringScan(RuntimeError):
    """Raised when a stable manifest cannot be captured."""


def file_digest(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb", buffering=1024 * 1024) as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def entry(path: str, relative_path: str) -> dict[str, Any]:
    before = os.lstat(path)
    mode = before.st_mode
    record: dict[str, Any] = {
        "path": relative_path,
        "mode": stat.S_IMODE(mode),
        "uid": before.st_uid,
        "gid": before.st_gid,
        "size": before.st_size,
        "mtime_ns": before.st_mtime_ns,
    }

    if stat.S_ISREG(mode):
        record["type"] = "file"
        record["sha256"] = file_digest(path)
    elif stat.S_ISDIR(mode):
        record["type"] = "directory"
    elif stat.S_ISLNK(mode):
        record["type"] = "symlink"
        record["target"] = os.readlink(path)
    elif stat.S_ISSOCK(mode):
        record["type"] = "socket"
    elif stat.S_ISFIFO(mode):
        record["type"] = "fifo"
    elif stat.S_ISCHR(mode):
        record["type"] = "character-device"
    elif stat.S_ISBLK(mode):
        record["type"] = "block-device"
    else:
        record["type"] = "unknown"

    after = os.lstat(path)
    stable_fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns")
    if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
        raise TreeChangedDuringScan(f"entry changed while hashing: {path}")
    return record


def build_manifest(root_argument: str) -> list[dict[str, Any]]:
    requested_root = Path(root_argument).expanduser()
    if not requested_root.exists() and not requested_root.is_symlink():
        return [{"path": ".", "type": "absent"}]

    # Follow a symlink used as ~/.meee2 so writes through it are guarded too.
    root = requested_root.resolve(strict=True)
    if not root.is_dir():
        return [entry(os.fspath(root), ".")]

    records = [entry(os.fspath(root), ".")]
    for directory, directory_names, file_names in os.walk(root, topdown=True, followlinks=False):
        directory_names.sort()
        file_names.sort()
        names = sorted(directory_names + file_names)
        for name in names:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root)
            records.append(entry(path, relative))
    return records


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} ROOT", file=sys.stderr)
        return 64

    last_error: Exception | None = None
    for attempt in range(3):
        try:
            manifest = build_manifest(sys.argv[1])
            for record in manifest:
                print(json.dumps(record, sort_keys=True, ensure_ascii=True, separators=(",", ":")))
            return 0
        except (FileNotFoundError, TreeChangedDuringScan) as error:
            last_error = error
            if attempt < 2:
                time.sleep(0.05 * (attempt + 1))

    print(
        "storage tree changed while it was being inspected; "
        f"stop the running meee2 process and retry ({last_error})",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

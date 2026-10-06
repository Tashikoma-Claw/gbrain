#!/usr/bin/env python3
"""List oversized notion-wiki markdown and print split guidance.

Writes nothing to the pages. Splitting is a manual edit: see
ops/yh-brain-box/page-split.md.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


def log(message: str) -> None:
    print(message, file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description="Plan splits for oversized markdown")
    parser.add_argument("--dir", default=os.environ.get("NOTION_WIKI_PATH", ""))
    parser.add_argument("--bytes", type=int, default=int(os.environ.get("PAGE_SPLIT_BYTES", "120000")))
    args = parser.parse_args()
    root = Path(args.dir) if args.dir else None
    if root is None or not root.is_dir():
        shown = args.dir or "(unset)"
        log(f"PAGE_SPLIT_SKIP directory missing ({shown})")
        return 0
    found = 0
    for path in sorted(root.rglob("*.md")):
        if any(part in {".git", "node_modules"} for part in path.parts):
            continue
        size = path.stat().st_size
        if size < args.bytes:
            continue
        found += 1
        rel = path.relative_to(root).as_posix()
        print(f"oversize {rel} bytes={size}")
        print(f"  split on level-2 headings; keep the original slug on part 1")
        print(f"  give each later part its own slug and a link back to part 1")
        print(f"  do not run gbrain embed as part of the split; sync with --no-embed")
    log(f"PAGE_SPLIT count={found} threshold={args.bytes}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

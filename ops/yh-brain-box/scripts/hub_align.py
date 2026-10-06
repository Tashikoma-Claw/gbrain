#!/usr/bin/env python3
"""Diff hub markdown and optionally mirror checkout -> vault.

Primary path: one-way copy from the wiki checkout onto the vault.
Dry-run unless --apply. Never deletes vault files. Never copies a
writer_manifest. Symlinks are refused.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import sys
from pathlib import Path


def log(message: str) -> None:
    print(message, file=sys.stderr)


def patterns() -> list[str]:
    raw = os.environ.get(
        "HUB_GLOBS",
        "crm/client-*.md,crm/project-*.md,projects/*.md,clients/*.md",
    )
    return [item.strip() for item in raw.split(",") if item.strip()]


def match_glob(rel: str, pattern: str) -> bool:
    parts = rel.split("/")
    pat_parts = pattern.split("/")
    if len(parts) < len(pat_parts):
        return False
    tail = parts[-len(pat_parts) :]
    if tail[0] != pat_parts[0]:
        return False
    name = tail[-1]
    star = pat_parts[-1]
    if "*" not in star:
        return name == star
    prefix, suffix = star.split("*", 1)
    return name.startswith(prefix) and name.endswith(suffix)


def is_manifest(rel: str) -> bool:
    name = rel.split("/")[-1]
    return name == "writer_manifest" or name.startswith("writer_manifest.")


def hubs(root: Path) -> dict[str, Path]:
    found: dict[str, Path] = {}
    if not root.is_dir():
        return found
    globs = patterns()
    for path in root.rglob("*"):
        if not path.is_file() and not path.is_symlink():
            continue
        rel = path.relative_to(root).as_posix()
        if any(part in {".git", "node_modules"} for part in Path(rel).parts):
            continue
        if any(match_glob(rel, pattern) for pattern in globs) or is_manifest(rel):
            found[rel] = path
    return found


def digest(path: Path) -> str:
    if path.is_symlink():
        return "symlink"
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def diff(checkout: Path, vault: Path) -> list[str]:
    left = hubs(checkout)
    right = hubs(vault)
    lines: list[str] = []
    for rel in sorted(set(left) | set(right)):
        if rel not in right:
            lines.append(f"only-checkout {rel}")
        elif rel not in left:
            lines.append(f"only-vault {rel}")
        elif digest(left[rel]) != digest(right[rel]):
            lines.append(f"differ {rel}")
    return lines


def mirror(checkout: Path, vault: Path, apply: bool) -> int:
    left = hubs(checkout)
    right = hubs(vault)
    rc = 0
    for rel in sorted(left):
        src = left[rel]
        if is_manifest(rel):
            log(f"REFUSED writer_manifest copy {rel}")
            rc = 1
            continue
        if src.is_symlink():
            log(f"REFUSED symlink {rel}")
            rc = 1
            continue
        dest = vault / rel
        same = rel in right and digest(src) == digest(dest)
        if same:
            continue
        if not apply:
            log(f"would-copy {rel}")
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(src.read_bytes())
        log(f"copied {rel}")
    return rc


def main() -> int:
    parser = argparse.ArgumentParser(description="Diff or mirror hub markdown")
    parser.add_argument("command", choices=("diff", "mirror"))
    parser.add_argument("--checkout", required=True)
    parser.add_argument("--vault", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()
    checkout = Path(args.checkout)
    vault = Path(args.vault)
    if not checkout.is_dir() or not vault.is_dir():
        log("HUB_DIFF_SKIP checkout or vault missing")
        return 0
    if args.command == "diff":
        lines = diff(checkout, vault)
        sys.stdout.write("".join(f"{line}\n" for line in lines))
        log(f"HUB_DIFF count={len(lines)}")
        if args.strict and lines:
            return 1
        return 0
    return mirror(checkout, vault, args.apply)


if __name__ == "__main__":
    raise SystemExit(main())

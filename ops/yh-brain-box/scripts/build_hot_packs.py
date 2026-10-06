#!/usr/bin/env python3
"""Rebuild slim hot packs from client and project hub markdown.

Paths come from argv or the environment (VAULT_PATH, HOT_PACK_OUT,
WIKI_CHECKOUT). A missing vault is a successful no-op so a cloud
checkout can run this file without the live brain.

The shell wrapper decides whether a wiki-delta approval is on file.
This module only reads markdown and writes JSON.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


CLIENT_GLOBS = ("crm/client-*.md",)
PROJECT_GLOBS = ("crm/project-*.md", "projects/*.md", "clients/*.md")


def log(message: str) -> None:
    print(message, file=sys.stderr)


def split_frontmatter(text: str) -> tuple[str, str]:
    if not text.startswith("---"):
        return "", text
    parts = text.split("---", 2)
    if len(parts) < 3:
        return "", text
    return parts[1], parts[2]


def parse_yaml_lite(block: str) -> dict[str, str]:
    data: dict[str, str] = {}
    for line in block.splitlines():
        if not line or line[0] in " \t#" or ":" not in line:
            continue
        key, value = line.split(":", 1)
        data[key.strip()] = value.strip().strip("\"'")
    return data


def first_paragraph(body: str) -> str:
    lines: list[str] = []
    for raw in body.splitlines():
        line = raw.strip()
        if not line:
            if lines:
                break
            continue
        if line.startswith("#"):
            if lines:
                break
            continue
        lines.append(line)
    text = " ".join(lines)
    if len(text) > 240:
        return text[:237] + "..."
    return text


def match_glob(rel: str, pattern: str) -> bool:
    """True when rel ends with a crm/ or projects/ or clients/ hub name."""
    parts = rel.split("/")
    pat_parts = pattern.split("/")
    if len(parts) < len(pat_parts):
        return False
    tail = parts[-len(pat_parts) :]
    if tail[0] != pat_parts[0]:
        return False
    name = tail[-1]
    star = pat_parts[-1]
    if not star.endswith(".md") or "*" not in star:
        return name == star
    prefix, suffix = star.split("*", 1)
    return name.startswith(prefix) and name.endswith(suffix)


def collect(root: Path, globs: tuple[str, ...]) -> list[Path]:
    if not root.is_dir():
        return []
    found: list[Path] = []
    for path in root.rglob("*.md"):
        if any(part in {".git", "node_modules"} for part in path.parts):
            continue
        rel = path.relative_to(root).as_posix()
        if any(match_glob(rel, pattern) for pattern in globs):
            found.append(path)
    return sorted(found)


def record(path: Path, root: Path, kind: str) -> dict[str, str]:
    text = path.read_text(encoding="utf-8", errors="replace")[:8000]
    front, body = split_frontmatter(text)
    meta = parse_yaml_lite(front)
    rel = path.relative_to(root).as_posix()
    slug = meta.get("slug") or path.stem
    title = meta.get("title") or slug
    summary = meta.get("summary") or first_paragraph(body)
    return {
        "slug": slug,
        "title": title,
        "path": rel,
        "kind": kind,
        "status": meta.get("status", ""),
        "summary": summary,
        "root": str(root),
    }


def merge(vault: Path | None, checkout: Path | None) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    accounts: dict[str, dict[str, str]] = {}
    projects: dict[str, dict[str, str]] = {}
    # Checkout first, vault overwrites, so the vault copy wins on the same slug.
    roots: list[Path] = []
    if checkout is not None and checkout.is_dir():
        roots.append(checkout)
    if vault is not None and vault.is_dir():
        roots.append(vault)
    for root in roots:
        for path in collect(root, CLIENT_GLOBS):
            item = record(path, root, "account")
            accounts[item["slug"]] = item
        for path in collect(root, PROJECT_GLOBS):
            item = record(path, root, "project")
            projects[item["slug"]] = item
    return list(accounts.values()), list(projects.values())


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a slim hot pack from hub markdown")
    parser.add_argument("--vault", default=os.environ.get("VAULT_PATH", ""))
    parser.add_argument("--checkout", default=os.environ.get("WIKI_CHECKOUT", ""))
    parser.add_argument("--out", default=os.environ.get("HOT_PACK_OUT", ""))
    args = parser.parse_args()
    vault = Path(args.vault) if args.vault else None
    if vault is None or not vault.is_dir():
        shown = args.vault or "(unset)"
        log(f"HOT_PACK_SKIP vault missing ({shown})")
        return 0
    if not args.out:
        log("HOT_PACK_SKIP output path unset")
        return 0
    checkout = Path(args.checkout) if args.checkout else None
    accounts, projects = merge(vault, checkout)
    payload = {
        "schema": "hot-pack-slim/1",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "vault": str(vault),
        "accounts": accounts,
        "projects": projects,
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    os.chmod(out, 0o644)
    log(f"HOT_PACK_WROTE accounts={len(accounts)} projects={len(projects)} out={out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

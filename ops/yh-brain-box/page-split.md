# Splitting oversized notion-wiki pages

Some Notion exports land as one markdown file large enough to dominate a
chunk budget and a stale-embed pass. The planner lists those files. It does
not edit them.

```bash
NOTION_WIKI_PATH=/home/box/brain-os/vault/notion-wiki \
  /home/box/brain-os/bin/notion-page-split-plan.sh
```

Default threshold is 120000 bytes (`PAGE_SPLIT_BYTES`). A missing directory
prints `PAGE_SPLIT_SKIP` and exits 0.

## When you split

1. Cut on level-2 headings. Leave the original slug on part 1.
2. Give each later part its own slug and a link back to part 1.
3. Keep a short frontmatter block on every part (`title`, `slug`).
4. Commit the vault (or write through `put_page` / `capture`). Do not point
   the wiki `default` source at the vault.
5. Sync the ingest brain with `--no-embed --no-pull`. Do not run
   `gbrain embed --all`. The hourly stale embed picks up new chunks at
   `EMBED_CAP` (200) per run.

The 2026-10-04 ingest tail is a separate problem (the sync stopped early).
Use `ingest-finish-tail.sh` for that. Splitting a page is not how you finish
a stuck tail.

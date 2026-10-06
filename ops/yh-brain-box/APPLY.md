# Apply Phase 0 on the box

Copy these scripts onto the Grok Bot box. Run them there. A cloud agent, CI job, or checkout of this repo does not run dream, doctor, or backup against the live brain.

Upstream shape this apply restores, on the dual local PGLite install:

| Original design | Box |
|---|---|
| Many named sources, scheduled sync | Ingest brain gets one source per git root (`vault`, plus Notion or AgentMail only when that tree is its own checkout). Cron runs `gbrain sync --source <id> --no-embed --no-pull`. |
| Preview, then approve, then import | `gbrain sources inspect` writes a plan. A ready company-brain plan is `gbrain sources connect` (preview, then `--yes` only if `state/multi-source-approve.json` allows that source). A general markdown repo (`profile_ambiguous`) uses `gbrain sources add --no-federated`. |
| Compact search surface | Wiki brain stays source `default` at `~/.gbrain/wiki-default-checkout`. Raw sources are `--no-federated`, then `gbrain sources unfederate` and `gbrain sources mirror-readonly`. They are not registered on the wiki brain. |
| Nightly dream on the live host | `gbrain dream --source default` after serve stops, then the existing restart script. Source `yh-brain` is refused. |
| Doctor and update hygiene | `gbrain doctor --json` and `gbrain check-update --json`. This does not run `gbrain upgrade`. |
| Git plus a real DB backup | Fast-forward `git push` of YH-Brain and YH-Brain-wiki, then `gbrain backup create`. Never `--force`. |
| Local PGLite, one serve | Preflight requires `engine: pglite` and the on-disk directory. `GBRAIN_DATABASE_URL` and `DATABASE_URL` are cleared so they cannot switch the process to Postgres. No Mumbai, no Supabase. |

Search mode stays whatever the box already has (`conservative`). These scripts do not change it.

## Loop J / serve

Serve on `:18792` is box runtime. `gbrain-restart-serves.sh` remains the owner. Do not replace that script and do not start a second serve. Dream, backup, doctor, and embed stop a process only when its command line is `gbrain serve` on that port, run one exclusive command, then call the restart script. Phase 2 splits the locks; see [Phase 2](#phase-2).

## 1. Copy

```bash
install -d /home/box/brain-os/bin /home/box/brain-os/scripts /home/box/brain-os/state /home/box/brain-os/logs /home/box/brain-os/backups/wiki
# Repo path is scripts/ because this repo gitignores bin/. Destination is the box bin/.
install -m 0755 ops/yh-brain-box/scripts/gbrain-dream-nightly.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/backup-push.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/gbrain-multi-source-delta.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/notion-delta.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/pipeline-digest.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/gbrain-daily-hygiene.sh /home/box/brain-os/bin/
install -m 0644 ops/yh-brain-box/lib/box-ops-common.sh /home/box/brain-os/scripts/box-ops-common.sh
```

Leave `/home/box/brain-os/bin/gbrain-restart-serves.sh` in place. The scripts need `bash`, `python3`, `flock`, and `git` on the box.

## 2. Keys and paths

```bash
install -m 0600 ops/yh-brain-box/env/sg.env.example /home/box/.gbrain/sg.env
# Edit sg.env on the box. Set ZHIPUAI_API_KEY. Do not set a database URL.
chmod 600 /home/box/.gbrain/sg.env
install -m 0600 ops/yh-brain-box/env/box.env.example /home/box/brain-os/state/box.env
# Point NOTION_* and AGENTMAIL_PATH at the real checkouts if they differ.
```

`box.env` is paths only. Do not commit the filled `sg.env`.

## 3. Preview approval

```bash
install -m 0600 ops/yh-brain-box/state/multi-source-approve.example.json \
  /home/box/brain-os/state/multi-source-approve.json
```

`ingest_raw: true` with a source id lets the delta cron import that git root into the **ingest** brain after inspect. `wiki_import: true` is refused. Without this file the cron only writes plans under `/home/box/brain-os/state/previews/`.

Overlapping trees cannot be two sources (`sources add` rejects an overlapping `local_path`). A Notion snapshot or AgentMail directory inside the vault repo is previewed with `gbrain sources inspect <vault> --include <slice>/**` and is synced as part of source `vault`. Give it its own source id only when it is its own git root.

Dirty eligible markdown or an oversized inspect holds the import. Commit the vault, or narrow a future inspect, then let the next cron run. Do not point the wiki `default` source at the vault.

## 4. Remotes

Vault origin stays the private `Tashikoma-Claw/YH-Brain` repo. For the wiki checkout:

```bash
git -C /home/box/.gbrain/wiki-default-checkout remote add origin git@github.com:Tashikoma-Claw/YH-Brain-wiki.git
```

The GitHub repo must be private. `backup-push.sh` pushes the current branch only when `origin/<branch>` is an ancestor of HEAD. It does not commit the dirty tree, does not force-push, and refuses a `supabase`, `mumbai`, or `garrytan/gbrain` URL. Review the checkout, commit what belongs in YH-Brain-wiki, then let the 03:17 cron push.

`gbrain backup create` writes `/home/box/brain-os/backups/wiki/wiki-<stamp>.gbrain-backup` (mode 0700 directory, seven archives kept). That file is a full database snapshot. It does not go inside either git checkout. Serve is stopped for the snapshot because PGLite has one writer, then `gbrain-restart-serves.sh` runs.

A restore drill, on the box, into an empty directory:

```bash
gbrain backup restore /home/box/brain-os/backups/wiki/wiki-<stamp>.gbrain-backup --into /home/box/brain-os/backups/restore-drill
```

## 5. Crontab

Box local time is HKT. Replace the dream line that still targets `yh-brain` or `GBRAIN_DATABASE_URL`. Keep a single backup line at 03:17. Do not add a second copy.

```bash
crontab -l
# merge ops/yh-brain-box/cron/crontab.snippet
```

Order:

1. `02:28` dream (`gbrain dream --source default`)
2. `03:17` backup (waits on the long lock if dream is still running; the snapshot uses the short lock)
3. `04:17` `gbrain doctor --json` and `gbrain check-update --json`
4. `:47` outside 02:00–03:59, multi-source delta
5. Notion export at 01:10, 07:10, 13:10, 19:10, then the delta syncs the markdown
6. `07:25` pipeline digest (state files only; log line `OK pipeline digest -> ingest.pglite`)

`gbrain-daily-hygiene.sh` exits with doctor's status. Warnings stay visible. An available upstream release is reported by `check-update` and is not installed by this cron.

Notion: `notion-delta.sh` runs the exporter already on the box (`NOTION_DELTA_CMD`, or `brain-os/bin/notion-delta-backup.sh`). It does not call the Notion API. `notion-delta.sh --check` exits 1 when `notion-backup/state/last_sync.json` is older than 36 hours.

The weekly sweep from the original design is not scheduled. Read `gbrain sweep --help` on the box before anyone runs it.

## 6. Checks on the box

```bash
# next morning
grep NIGHTLY_EXIT /home/box/brain-os/logs/dream-nightly.log
gbrain status
gbrain backup status
GBRAIN_HOME=/home/box/.gbrain-homes/ingest gbrain sources list
gbrain sources list
```

Expect `NIGHTLY_EXIT=0`, dream on source `default`, backup status showing the wiki remote, ingest sources with last-sync times, and the wiki list still `default` as the federated search surface. `curl 127.0.0.1:18792/health` is the serve check after Loop J; this package only stops and starts that process around dream, backup, doctor, and the hourly stale embed.

## Phase 2

Phase 2 is the same package. It does not replace Phase 0. Apply it on the box after the Phase 0 copy. A cloud checkout does not run dream, doctor, embed, or backup against the live brain.

### Locks

| Lock | File | Who holds it | Serve |
|---|---|---|---|
| Long | `/home/box/brain-os/state/brain-ops.lock` | Dream, and `loop-entry.sh` for Loop | Dream may keep serve down for the whole dream. Loop does not stop serve. |
| Short | `/home/box/brain-os/state/brain-ops-db.lock` | Doctor, embed, the backup snapshot | Stopped only while this lock is held. Outside dream the window is at most 20 minutes (`SERVE_GAP_MAX_SECONDS`, default 1200). `timeout` kills that `gbrain` process when the window expires, then the trap starts serve again. |

Every serve-stop path installs an EXIT/INT/TERM trap that calls `gbrain-restart-serves.sh` if serve was stopped or if `state/serve-stopped-pid` is still there. Loop should be started as `loop-entry.sh <command>` so that trap still runs when a child leaves the stamp behind.

Dream takes the long lock first, then the short lock, and passes `unlimited`. Doctor, embed, and the snapshot pass `limited`. Backup still waits on the long lock so 03:17 does not snapshot through a running dream; the snapshot itself uses the short lock.

### Copy

```bash
install -m 0755 ops/yh-brain-box/scripts/gbrain-embed-stale.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/gbrain-hot-pack-rebuild.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/build_hot_packs.py /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/hub-diff.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/hub-mirror-checkout-to-vault.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/hub_align.py /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/writer-manifest-transfer.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/ingest-finish-tail.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/notion-page-split-plan.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/notion_page_split_plan.py /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/gbrain-version-check.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/legacy-marker-scan.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/scripts/loop-entry.sh /home/box/brain-os/bin/
install -m 0644 ops/yh-brain-box/lib/box-ops-common.sh /home/box/brain-os/scripts/box-ops-common.sh
install -m 0644 ops/yh-brain-box/TARGET_VERSION /home/box/brain-os/state/TARGET_VERSION
```

Re-copy the Phase 0 scripts in the same pass. They now take the short lock. Leave `gbrain-restart-serves.sh` in place.

Refresh `box.env` from `env/box.env.example` (paths only). Add `VOYAGE_API_KEY` to the existing `sg.env` if embed does not already see it. Embeddings stay on Voyage. Zhipu stays the facts/chat key. Do not commit either file.

`EMBED_CONSENT=yes` in `box.env` is required before the hourly embed will call Voyage. Until then the script exits 3 and does not stop serve.

### Cron

Merge the new lines from `cron/crontab.snippet`. Do not add `gbrain upgrade`. Do not add a second dream or backup line.

| When | What |
|---|---|
| `:12` outside 02:00–03:59 | `gbrain embed --stale --batch-size 200`. Never `--all`, never `--catch-up`. |
| `:55` outside that window | Hot-pack rebuild, no-op until approved. |
| Sunday 05:17 | Version check against 0.60.82. Writes the manual upgrade command. Does not run it. |
| Sunday 05:40 | Hub diff (read-only). |

Doctor stays at 04:17. It archives JSON to `state/logs/YYYY-MM-DD/doctor.json` and writes one line to `state/health.status`: `ok`, `warn`, or `fail`, then a timestamp. `gbrain doctor` still decides the process exit (`unhealthy` is non-zero). Warnings show up in that file.

### Hot packs

Today the box rebuilds packs with `brain-os/scripts/build_hot_packs.py` from vault `crm/client-*.md` into `/home/box/codex-harness/g2-sync/hot-packs/accounts.slim.json`. The packaged script is that job, with the vault and the output path taken from the environment.

It runs only when both are true:

- `state/hot-pack-approve.json` has `"rebuild": true` (see `state/hot-pack-approve.example.json`)
- `state/multi-source-preview-latest.json` has `"ok": true`

That approval does not import the vault into the wiki. New client and project slugs show up on the next successful delta plus this cron. A missing vault prints `HOT_PACK_SKIP` and exits 0.

### Hubs

Primary path: checkout to vault, dry-run unless `--apply`.

```bash
/home/box/brain-os/bin/hub-diff.sh
/home/box/brain-os/bin/hub-mirror-checkout-to-vault.sh
/home/box/brain-os/bin/hub-mirror-checkout-to-vault.sh --apply
```

The mirror copies hub files that differ and does not delete vault-only files. It refuses `writer_manifest` and symlinks.

Optional other path: `gbrain sources inspect` from the Phase 0 delta cron previews a brain import. It does not copy hubs.

`writer-manifest-transfer.sh` is not on the cron. It exits 3 unless `--apply`, `WRITER_MANIFEST_TRANSFER=yes`, `--src`, and `--dest` are all set. A destination inside the vault also needs `--allow-vault`. Do not point that helper at the vault as part of a routine sync.

### Ingest tail and page splits

On 2026-10-04 the ingest sync walked the vault and Notion markdown and stopped before the last batch and the link extract. Pages sat on the ingest brain without mention links. Wiki serve was not the writer.

```bash
# report only
/home/box/brain-os/bin/ingest-finish-tail.sh --check
# after you agree; never embeds
/home/box/brain-os/bin/ingest-finish-tail.sh --apply --links
```

Install `state/ingest-tail.example.json` as `state/ingest-tail.json` only while that tail is still stuck. Remove it when the sync has finished. Without the file the helper exits 0.

Oversized notion-wiki pages: [page-split.md](page-split.md). The planner does not edit files.

### Retired marker and 0.60.82

Packaged scripts do not name the retired source. On the live box:

```bash
/home/box/brain-os/bin/legacy-marker-scan.sh /home/box/brain-os/bin /home/box/brain-os/scripts
```

Replace any flagged copy with the matching script from this package. Do not delete `gbrain-restart-serves.sh`.

Check the installed CLI and upgrade only by hand:

```bash
gbrain --version
gbrain check-update --json
# when you mean it, and not from cron:
gbrain upgrade
```

`gbrain-version-check.sh` writes `state/version-check.txt`. `VERSION_BEHIND` means the box is older than 0.60.82. The file names `gbrain upgrade`. The cron line does not run it.

### Rollback

```bash
crontab -l > /home/box/brain-os/state/crontab.pre-phase2.bak
cp -a /home/box/brain-os/bin /home/box/brain-os/bin.pre-phase2.bak
# restore
cp -a /home/box/brain-os/bin.pre-phase2.bak/. /home/box/brain-os/bin/
crontab /home/box/brain-os/state/crontab.pre-phase2.bak
```

Take those copies before the Phase 2 install. Restoring the crontab removes the embed, hot-pack, version, and hub-diff lines. Serve returns to whatever `gbrain-restart-serves.sh` already does.

### Checks

```bash
bash ops/yh-brain-box/test/smoke.sh
bash ops/yh-brain-box/test/smoke-phase2.sh
# on the box, after a doctor run
cat /home/box/brain-os/state/health.status
curl -fsS 127.0.0.1:18792/health
```

`health.status` is one line, `ok`, `warn`, or `fail`, then a timestamp. Embed logs `EMBED_EXIT=` and must not contain `--all`.

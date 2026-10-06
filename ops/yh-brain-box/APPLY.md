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

Serve on `:18792` is box runtime. `gbrain-restart-serves.sh` remains the owner. Do not replace that script and do not start a second serve. Dream, backup, and hygiene stop a process only when its command line is `gbrain serve` on that port, run one exclusive command, then call the restart script. The hourly watchdog lock is a separate problem; this package does not change it.

## 1. Copy

```bash
install -d /home/box/brain-os/bin /home/box/brain-os/scripts /home/box/brain-os/state /home/box/brain-os/logs /home/box/brain-os/backups/wiki
install -m 0755 ops/yh-brain-box/bin/gbrain-dream-nightly.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/bin/backup-push.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/bin/gbrain-multi-source-delta.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/bin/notion-delta.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/bin/pipeline-digest.sh /home/box/brain-os/bin/
install -m 0755 ops/yh-brain-box/bin/gbrain-daily-hygiene.sh /home/box/brain-os/bin/
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
2. `03:17` backup (same lock, waits if dream is still running)
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

Expect `NIGHTLY_EXIT=0`, dream on source `default`, backup status showing the wiki remote, ingest sources with last-sync times, and the wiki list still `default` as the federated search surface. `curl 127.0.0.1:18792/health` is the serve check after Loop J; this package only stops and starts that process around dream, backup, and doctor.

# YH brain-box ops

Scripts for the Grok Bot box. They call the upstream `gbrain` CLI. They do not change gbrain core.

The live wiki is local PGLite at `/home/box/.gbrain/wiki.pglite`, source `default`. Raw vault, Notion, and AgentMail markdown stay on the ingest brain (`GBRAIN_HOME=/home/box/.gbrain-homes/ingest`) as named sources that are not federated into wiki search. Dream, doctor, and `gbrain backup create` run on that host, with serve stopped for the single PGLite writer, then started again by the existing `gbrain-restart-serves.sh`.

Nothing in this repo runs dream. Copy the scripts onto the box using [APPLY.md](APPLY.md).

Phase 2 adds a short serve-stop lock, hot-pack rebuild, capped stale embed, hub diff, ingest-tail and page-split helpers, a version check aimed at gbrain 0.60.82, and a 20-ask retrieval stub. The apply steps and rollback are in APPLY.md.

```bash
bash ops/yh-brain-box/test/smoke.sh
bash ops/yh-brain-box/test/smoke-phase2.sh
```

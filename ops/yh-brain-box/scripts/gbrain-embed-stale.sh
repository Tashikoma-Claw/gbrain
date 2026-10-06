#!/usr/bin/env bash
# Hourly stale embed for the live wiki brain.
#
# Voyage remains the embedding provider already configured on the box.
# This script does not select a second provider. It sources sg.env so a
# cron shell sees VOYAGE_API_KEY (embeddings) and ZHIPUAI_API_KEY (facts
# and chat, unused by this command).
#
# Cap: EMBED_CAP chunks per run (default 200) via `gbrain embed --stale
# --batch-size`. Never `--all` and never `--catch-up`. gbrain's
# --batch-size is the keyset page size; a fast provider can still walk
# more than one page. The serve-stop window is still capped at 20 minutes
# (SERVE_GAP_MAX_SECONDS, default 1200) and GBRAIN_EMBED_TIME_BUDGET_MS is
# set inside that window so the CLI's 30-minute default cannot hold serve
# down. If the JSON result embedded more than EMBED_CAP, the script exits
# 4 (EMBED_OVER_CAP). Partial vectors stay; the next hour continues.
#
# Lock: short DB lock only. Dream keeps the long lock.
set -euo pipefail
umask 077

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMMON=""
for candidate in \
  "$HERE/../lib/box-ops-common.sh" \
  "$HERE/../scripts/box-ops-common.sh" \
  "/home/box/brain-os/scripts/box-ops-common.sh"
do
  if [[ -f "$candidate" ]]; then
    COMMON=$candidate
    break
  fi
done
if [[ -z "$COMMON" ]]; then
  echo "box-ops-common.sh not found next to this script" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$COMMON"

if [[ "${CI:-}" == "true" && "${BOX_OPS_SMOKE:-}" != "1" ]]; then
  box_ops_log "EMBED_HOST_ONLY: refusing embed under CI"
  exit 2
fi

for flag in "$@"; do
  if [[ "$flag" == "--all" || "$flag" == "--catch-up" ]]; then
    box_ops_log "REFUSED embed flag $flag"
    exit 3
  fi
done

box_ops_load_sg_env
box_ops_clear_hosted_db_env

if [[ "${BOX_OPS_SMOKE:-}" != "1" ]]; then
  hour=$(date +%H)
  if [[ "$hour" == "02" || "$hour" == "03" ]]; then
    box_ops_log "skip embed during the dream window (02:00-03:59 box local)"
    exit 0
  fi
fi

if [[ "${EMBED_CONSENT:-}" != "yes" ]]; then
  box_ops_log "EMBED_CONSENT_REQUIRED: set EMBED_CONSENT=yes in box.env after agreeing to Voyage spend for at most EMBED_CAP stale chunks per run"
  exit 3
fi

if ! box_ops_embed_stale_args; then
  exit 3
fi

export GBRAIN_HOME="$WIKI_HOME"
unset GBRAIN_SOURCE
export GBRAIN_SOURCE="default"

if [[ ! -d "$WIKI_PGLITE" ]]; then
  box_ops_log "EMBED_HOST_ONLY: $WIKI_PGLITE is not on this machine"
  exit 2
fi
if ! box_ops_preflight_pglite "$WIKI_HOME" "$WIKI_PGLITE"; then
  exit 2
fi

gap=$(box_ops_serve_gap_max)
reserve=60
if [[ "$gap" -le "$reserve" ]]; then
  reserve=0
fi
export GBRAIN_EMBED_TIME_BUDGET_MS=$(( (gap - reserve) * 1000 ))
box_ops_log "embed budget_ms=$GBRAIN_EMBED_TIME_BUDGET_MS cap=${EMBED_CAP}"

box_ops_serve_guard_on
if ! box_ops_serve_stop_begin limited "${EMBED_DB_LOCK_WAIT_SECONDS:-1200}"; then
  exit 1
fi

dry="$STATE_DIR/embed-dry-run.json"
set +e
box_ops_gbrain_bounded embed --stale --source default --batch-size "$EMBED_CAP" --dry-run --json > "$dry"
dry_rc=$?
set -e
would=0
if [[ -s "$dry" ]]; then
  would=$(python3 - "$dry" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    doc = {}
print(int(doc.get("would_embed") or 0))
PY
)
fi
box_ops_log "embed dry-run exit=$dry_rc would_embed=$would"

rc=0
result="$STATE_DIR/embed-last.json"
if [[ "$would" == "0" && "$dry_rc" == "0" ]]; then
  box_ops_log "EMBED_IDLE no stale chunks"
  printf '%s\n' '{"embedded":0,"would_embed":0,"idle":true}' > "$result"
else
  box_ops_log "gbrain ${EMBED_ARGS[*]}"
  set +e
  box_ops_gbrain_bounded "${EMBED_ARGS[@]}" > "$result"
  rc=$?
  set -e
fi
chmod 600 "$dry" "$result" || true

embedded=$(python3 - "$result" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    doc = {}
print(int(doc.get("embedded") or 0))
PY
)
if [[ "$embedded" -gt "$EMBED_CAP" ]]; then
  box_ops_log "EMBED_OVER_CAP embedded=$embedded cap=$EMBED_CAP"
  rc=4
fi

box_ops_serve_stop_end || rc=1
box_ops_log "EMBED_EXIT=$rc embedded=$embedded"
exit "$rc"

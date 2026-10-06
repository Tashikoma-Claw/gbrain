#!/usr/bin/env bash
# Finish a stuck ingest tail. Motivating case: 2026-10-04.
#
# The ingest sync walked the vault and Notion markdown, then stopped
# before the last batch and the link extract finished. Pages sat on the
# ingest brain (GBRAIN_HOME=~/.gbrain-homes/ingest) without mention links.
# The wiki serve on :18792 is a different database and is not stopped.
#
#   --check          exit 1 when state/ingest-tail.json says stuck, else 0
#   (no flag)        exit 3 and print the apply command; write nothing
#   --apply          gbrain sync --source <id> --no-embed --no-pull
#   --apply --links  also `gbrain extract links --source db` (no embeddings)
#
# Remove state/ingest-tail.json after the tail is finished so the next
# check is clear. This script never calls `gbrain embed`.
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
box_ops_load
box_ops_clear_hosted_db_env

mode="ask"
links=0
for flag in "$@"; do
  case "$flag" in
    --check) mode="check" ;;
    --apply) mode="apply" ;;
    --links) links=1 ;;
    *)
      box_ops_log "REFUSED unknown argument $flag"
      exit 2
      ;;
  esac
done

marker="$STATE_DIR/ingest-tail.json"
if [[ ! -f "$marker" ]]; then
  box_ops_log "INGEST_TAIL_CLEAR no $marker"
  exit 0
fi

read -r stuck source_id since < <(python3 - "$marker" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
stuck = "1" if doc.get("stuck") is True else "0"
source = str(doc.get("source_id") or "vault")
since = str(doc.get("since") or "")
print(stuck, source, since)
PY
)

if [[ "$stuck" != "1" ]]; then
  box_ops_log "INGEST_TAIL_CLEAR marker is not stuck"
  exit 0
fi

box_ops_log "INGEST_TAIL_STUCK source=$source_id since=$since case=2026-10-04"
box_ops_log "finish with: $0 --apply${links:+ --links}   (sync --no-embed, optional extract links, never embed)"

if [[ "$mode" == "check" ]]; then
  exit 1
fi
if [[ "$mode" != "apply" ]]; then
  exit 3
fi

if [[ ! -d "$INGEST_PGLITE" ]]; then
  box_ops_log "INGEST_TAIL_HOST_ONLY: $INGEST_PGLITE is not on this machine"
  exit 2
fi
export GBRAIN_HOME="$INGEST_HOME"
if ! box_ops_preflight_pglite "$INGEST_HOME" "$INGEST_PGLITE"; then
  exit 2
fi
if [[ "$GBRAIN_HOME" == "$WIKI_HOME" ]]; then
  box_ops_log "REFUSED ingest tail against the wiki home"
  exit 2
fi

box_ops_log "gbrain sync --brain $BRAIN_ID --source $source_id --no-embed --no-pull"
box_ops_gbrain sync --brain "$BRAIN_ID" --source "$source_id" --no-embed --no-pull
if [[ "$links" == "1" ]]; then
  box_ops_log "gbrain extract links --source db --json"
  box_ops_gbrain extract links --source db --json
fi
box_ops_log "INGEST_TAIL_APPLIED source=$source_id (remove $marker when the tail is done)"

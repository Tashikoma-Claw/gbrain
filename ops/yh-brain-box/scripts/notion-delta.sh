#!/usr/bin/env bash
# Unstick the Notion markdown export. The original path is
# export → markdown in git → gbrain sync. This helper runs the exporter
# that already lives on the box. It does not call the Notion API and it
# does not store a token. The multi-source delta cron syncs the markdown
# on the ingest brain after sources inspect.
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

last_sync_file() {
  local candidate
  for candidate in \
    "${NOTION_LAST_SYNC:-}" \
    "$BRAIN_OS/notion-backup/state/last_sync.json" \
    "$STATE_DIR/notion-last-sync.json"
  do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

check_freshness() {
  local file age_hours limit
  file=$(last_sync_file || true)
  if [[ -z "$file" ]]; then
    box_ops_log "NOTION_STALE: no last_sync.json"
    return 1
  fi
  age_hours=$(python3 - "$file" <<'PY'
import json, os, sys, time
path = sys.argv[1]
raw = json.load(open(path))
text = ""
if isinstance(raw, dict):
    for key in ("synced_at", "finished_at", "completed_at", "timestamp", "last_sync"):
        value = raw.get(key)
        if isinstance(value, str) and value:
            text = value
            break
if text:
    from datetime import datetime
    normalized = text.replace("Z", "+00:00")
    try:
        moment = datetime.fromisoformat(normalized).timestamp()
    except ValueError:
        moment = os.path.getmtime(path)
else:
    moment = os.path.getmtime(path)
print(int(max(0, time.time() - moment) // 3600))
PY
)
  limit="${NOTION_STALE_HOURS:-36}"
  python3 - "$STATE_DIR/notion-delta-status.json" "$file" "$age_hours" "$limit" <<'PY'
import json, sys
path, src, age, limit = sys.argv[1:]
json.dump({"last_sync_file": src, "age_hours": int(age), "stale_after_hours": int(limit)}, open(path, "w"))
open(path, "a").write("\n")
PY
  if [[ "$age_hours" -gt "$limit" ]]; then
    box_ops_log "NOTION_STALE: last sync is ${age_hours}h old (limit ${limit}h)"
    return 1
  fi
  box_ops_log "notion last sync is ${age_hours}h old"
  return 0
}

if [[ "${1:-}" == "--check" ]]; then
  check_freshness
  exit $?
fi

exporter=""
if [[ -n "${NOTION_DELTA_CMD:-}" && -x "${NOTION_DELTA_CMD}" ]]; then
  exporter="$NOTION_DELTA_CMD"
else
  for candidate in \
    "$BRAIN_OS/bin/notion-delta-backup.sh" \
    "$BRAIN_OS/bin/notion-backup.sh" \
    "$BRAIN_OS/notion-backup/notion-delta-backup.sh"
  do
    if [[ -x "$candidate" ]]; then
      exporter=$candidate
      break
    fi
  done
fi

if [[ -z "$exporter" ]]; then
  box_ops_log "NOTION_EXPORTER_MISSING: set NOTION_DELTA_CMD to the box exporter. This script does not call Notion."
  check_freshness || true
  exit 2
fi

box_ops_log "running $exporter"
"$exporter"
check_freshness || box_ops_log "export finished; last_sync.json is still stale or absent"
exit 0

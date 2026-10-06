#!/usr/bin/env bash
# One status line for the box pipeline. Reads local state files only.
# Does not import raw vault pages and does not open the wiki database
# (the serve process owns that file).
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

if ! box_ops_preflight_pglite "$INGEST_HOME" "$INGEST_PGLITE"; then
  box_ops_log "pipeline digest: ingest PGLite preflight failed"
  exit 1
fi
if [[ ! -f "$STATE_DIR/multi-source-preview-latest.json" ]]; then
  box_ops_log "pipeline digest: no multi-source preview yet"
  exit 1
fi

python3 - "$STATE_DIR" "$STATE_DIR/pipeline-digest-latest.json" <<'PY'
import json, os, sys
state, out = sys.argv[1:]
def read(name):
    path = os.path.join(state, name)
    if not os.path.isfile(path):
        return None
    text = open(path).read().strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text
doc = {
    "dream_exit": read("dream-last-exit"),
    "backup": read("backup-last.json"),
    "preview": read("multi-source-preview-latest.json"),
    "notion": read("notion-delta-status.json"),
    "ingest": "pglite",
}
json.dump(doc, open(out, "w"))
open(out, "a").write("\n")
PY
chmod 600 "$STATE_DIR/pipeline-digest-latest.json" || true
echo "OK pipeline digest -> ingest.pglite"

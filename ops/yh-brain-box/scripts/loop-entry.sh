#!/usr/bin/env bash
# Hold the long dream/Loop lock and restart serve if a child left it down.
#
# Does not take the short DB lock and does not stop serve. A child that
# needs the wiki PGLite calls box_ops_serve_stop_begin (limited, ≤20 min)
# and writes state/serve-stopped-pid. This process's EXIT trap restarts
# serve when that stamp is still present.
#
# Usage: loop-entry.sh <command> [args...]
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
export STATE_DIR RESTART_SERVES GBRAIN_SERVE_PORT BRAIN_OS

if [[ $# -lt 1 ]]; then
  box_ops_log "usage: loop-entry.sh <command> [args...]"
  exit 2
fi

if ! box_ops_lock_wait "${LOOP_LOCK_WAIT_SECONDS:-5400}"; then
  exit 1
fi
box_ops_log "loop long-lock only: $LOCK_FILE (serve-stop uses $DB_LOCK_FILE)"
box_ops_serve_guard_on
set +e
"$@"
rc=$?
set -e
exit "$rc"

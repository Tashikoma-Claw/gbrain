#!/usr/bin/env bash
# Daily doctor + update check on the live wiki host.
# PGLite has one writer, so this holds the dream/backup lock, stops
# :18792, runs the two read commands, and starts serve again.
# It does not run `gbrain upgrade`.
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
  box_ops_log "HYGIENE_HOST_ONLY: refusing to run doctor under CI"
  exit 2
fi

box_ops_load
box_ops_clear_hosted_db_env
export GBRAIN_HOME="$WIKI_HOME"
unset GBRAIN_SOURCE
export GBRAIN_SOURCE="default"

if ! box_ops_preflight_pglite "$WIKI_HOME" "$WIKI_PGLITE"; then
  exit 2
fi
if ! box_ops_lock_wait "${HYGIENE_LOCK_WAIT_SECONDS:-5400}"; then
  exit 1
fi

serve_stopped=0
serve_restarted=0
cleanup() {
  local rc=$?
  if [[ "$serve_stopped" == "1" && "$serve_restarted" == "0" ]]; then
    serve_restarted=1
    box_ops_start_wiki_serve || rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

box_ops_stop_wiki_serve
serve_stopped=1

day=$(date +%Y%m%d)
doctor_out="$STATE_DIR/doctor-${day}.json"
set +e
box_ops_gbrain doctor --json > "$doctor_out"
doctor_rc=$?
set -e
chmod 600 "$doctor_out" || true
box_ops_log "doctor exit=$doctor_rc archived=$doctor_out"

box_ops_gbrain check-update --json > "$STATE_DIR/check-update-${day}.json" || true
chmod 600 "$STATE_DIR/check-update-${day}.json" || true

box_ops_start_wiki_serve || doctor_rc=1
serve_restarted=1
# doctor exits 1 on warnings. Keep that signal.
exit "$doctor_rc"

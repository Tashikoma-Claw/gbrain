#!/usr/bin/env bash
# Daily doctor + update check on the live wiki host.
# Holds the short DB lock only (not the dream/Loop lock), stops :18792
# for at most 20 minutes, archives doctor JSON, writes health.status,
# and restarts serve on the EXIT trap. It does not run `gbrain upgrade`.
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

box_ops_serve_guard_on
if ! box_ops_serve_stop_begin limited "${HYGIENE_DB_LOCK_WAIT_SECONDS:-1200}"; then
  exit 1
fi

day=$(date +%F)
stamp=$(date -Is)
archive_dir="$STATE_DIR/logs/$day"
mkdir -p "$archive_dir"
doctor_out="$archive_dir/doctor.json"
legacy_out="$STATE_DIR/doctor-$(date +%Y%m%d).json"
set +e
box_ops_gbrain_bounded doctor --json > "$doctor_out"
doctor_rc=$?
set -e
cp -f "$doctor_out" "$legacy_out"
chmod 600 "$doctor_out" "$legacy_out" || true
box_ops_log "doctor exit=$doctor_rc archived=$doctor_out"

python3 - "$doctor_out" "$STATE_DIR/health.status" "$doctor_rc" "$stamp" <<'PY'
import json, sys
src, dest, rc, stamp = sys.argv[1:]
rc = int(rc)
word = "fail"
try:
    doc = json.load(open(src))
except Exception:
    doc = {}
status = doc.get("status")
if status == "healthy":
    word = "ok"
elif status == "warnings":
    word = "warn"
elif status == "unhealthy":
    word = "fail"
elif rc == 0:
    word = "ok"
else:
    word = "fail"
with open(dest, "w") as handle:
    handle.write(f"{word} {stamp}\n")
PY
chmod 600 "$STATE_DIR/health.status" || true
box_ops_log "health status $(tr -d '\n' < "$STATE_DIR/health.status")"

box_ops_gbrain_bounded check-update --json > "$archive_dir/check-update.json" || true
cp -f "$archive_dir/check-update.json" "$STATE_DIR/check-update-$(date +%Y%m%d).json" || true
chmod 600 "$archive_dir/check-update.json" "$STATE_DIR/check-update-$(date +%Y%m%d).json" || true

box_ops_serve_stop_end || doctor_rc=1
# Pass through gbrain doctor's exit. health.status carries ok/warn/fail.
exit "$doctor_rc"

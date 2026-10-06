#!/usr/bin/env bash
# Nightly dream for the live wiki brain on the Grok Bot box.
#
# RUNTIME: this file is only the script. CI, a cloud agent, and a checkout
# of this repo do not run dream. On the box the sequence is:
#   stop the single :18792 serve → gbrain dream --source default → start serve
# via the existing gbrain-restart-serves.sh. Do not start a second serve.
#
# Locks: the long lock (brain-ops.lock) for the whole dream, and the short
# DB lock (brain-ops-db.lock) while serve is down. Dream is the one job
# allowed to keep serve down longer than 20 minutes. The EXIT trap still
# restarts serve.
#
# Retired: any source other than default, Supabase GBRAIN_DATABASE_URL, Mumbai.
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
  box_ops_log "DREAM_HOST_ONLY: refusing to run dream under CI. Dream runs on the live brain host."
  exit 2
fi

box_ops_load_sg_env
box_ops_clear_hosted_db_env

if [[ ! -d "$WIKI_PGLITE" ]]; then
  box_ops_log "DREAM_HOST_ONLY: $WIKI_PGLITE is not on this machine. Dream runs on the live brain host, not in CI or a cloud checkout."
  exit 2
fi

source_id="${DREAM_SOURCE:-default}"
if [[ "$source_id" != "default" ]]; then
  box_ops_log "DREAM_BLOCKED source ${source_id} is not the live wiki source (expected default)"
  printf '%s\n' "3" > "$STATE_DIR/dream-last-exit"
  exit 3
fi
unset GBRAIN_SOURCE
export GBRAIN_HOME="$WIKI_HOME"
export GBRAIN_SOURCE="default"

if ! box_ops_preflight_pglite "$WIKI_HOME" "$WIKI_PGLITE"; then
  printf '%s\n' "2" > "$STATE_DIR/dream-last-exit"
  exit 2
fi

if ! box_ops_lock_nowait; then
  printf '%s\n' "1" > "$STATE_DIR/dream-last-exit"
  exit 1
fi

on_dream_exit() {
  local rc="${1:-1}"
  printf '%s\n' "$rc" > "$STATE_DIR/dream-last-exit"
  box_ops_log "NIGHTLY_EXIT=$rc"
}
BOX_OPS_EXIT_HOOK=on_dream_exit
box_ops_serve_guard_on

if ! box_ops_serve_stop_begin unlimited "${DREAM_DB_LOCK_WAIT_SECONDS:-1200}"; then
  printf '%s\n' "1" > "$STATE_DIR/dream-last-exit"
  exit 1
fi

args=(dream --source default)
if [[ -n "${DREAM_PHASES:-}" ]]; then
  IFS=',' read -r -a phases <<< "$DREAM_PHASES"
  declare -A seen=()
  for phase in "${phases[@]}"; do
    phase="${phase//[[:space:]]/}"
    [[ -n "$phase" ]] || continue
    if [[ "$phase" == "extract_stale" ]]; then
      box_ops_log "extract_stale is not a gbrain phase; using extract"
      phase="extract"
    fi
    if [[ -z "${seen[$phase]:-}" ]]; then
      seen[$phase]=1
      args+=(--phase "$phase")
    fi
  done
fi

box_ops_log "gbrain ${args[*]} (wiki PGLite, source default)"
set +e
box_ops_gbrain "${args[@]}" --json > "$STATE_DIR/dream-last.json"
rc=$?
set -e
box_ops_serve_stop_end || rc=1
exit "$rc"

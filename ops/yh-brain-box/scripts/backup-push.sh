#!/usr/bin/env bash
# Fast-forward push of the vault and the wiki checkout, then an optional
# local PGLite snapshot. Never force-pushes. Holds the same lock as dream
# so a 03:17 run waits out a 02:28 dream.
#
# Git remotes: private Tashikoma-Claw/YH-Brain and YH-Brain-wiki only.
# The database archive is gbrain backup create, kept outside both checkouts.
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
export GIT_TERMINAL_PROMPT=0

if ! box_ops_lock_wait "${BACKUP_LOCK_WAIT_SECONDS:-5400}"; then
  exit 1
fi

fail=0
box_ops_ff_push "$VAULT_PATH" "vault" || fail=1
box_ops_ff_push "$WIKI_CHECKOUT" "wiki-checkout" || fail=1

archive=""
if [[ "${BACKUP_CREATE:-1}" == "1" ]]; then
  case "$BACKUP_DIR" in
    "$WIKI_CHECKOUT"|"$WIKI_CHECKOUT"/*|"$VAULT_PATH"|"$VAULT_PATH"/*)
      box_ops_log "REFUSED backup dir inside the wiki checkout or the vault: $BACKUP_DIR"
      fail=1
      ;;
    /*)
      mkdir -p "$BACKUP_DIR"
      chmod 700 "$BACKUP_DIR" || true
      archive="$BACKUP_DIR/wiki-$(date +%Y%m%d-%H%M%S).gbrain-backup"
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
      if ! box_ops_preflight_pglite "$WIKI_HOME" "$WIKI_PGLITE"; then
        fail=1
      else
        box_ops_stop_wiki_serve
        serve_stopped=1
        export GBRAIN_HOME="$WIKI_HOME"
        box_ops_log "gbrain backup create --output $archive"
        if ! box_ops_gbrain backup create --output "$archive"; then
          fail=1
        fi
        box_ops_start_wiki_serve || fail=1
        serve_restarted=1
        # Keep the newest BACKUP_KEEP archives in this directory only.
        mapfile -t old < <(ls -1t "$BACKUP_DIR"/wiki-*.gbrain-backup 2>/dev/null || true)
        keep="${BACKUP_KEEP:-7}"
        if [[ "${#old[@]}" -gt "$keep" ]]; then
          for path in "${old[@]:$keep}"; do
            rm -f "$path"
            box_ops_log "rotated $path"
          done
        fi
      fi
      ;;
    *)
      box_ops_log "REFUSED relative backup dir: $BACKUP_DIR"
      fail=1
      ;;
  esac
else
  box_ops_log "BACKUP_CREATE=0; git push only (gbrain backup create skipped)"
fi

python3 - "$STATE_DIR/backup-last.json" "$fail" "$archive" <<'PY'
import json, sys
path, fail, archive = sys.argv[1:]
json.dump({"ok": fail == "0", "archive": archive or None}, open(path, "w"))
open(path, "a").write("\n")
PY
if [[ "$fail" != "0" ]]; then
  box_ops_log "BACKUP_EXIT=1"
  exit 1
fi
box_ops_log "BACKUP_EXIT=0"

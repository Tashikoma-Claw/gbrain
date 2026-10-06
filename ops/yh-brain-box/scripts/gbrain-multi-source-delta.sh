#!/usr/bin/env bash
# Scheduled multi-source delta for the ingest brain.
#
# Original model: many named sources, preview, then import, raw isolated
# from the compact wiki search surface.
#
#   gbrain sources inspect <repo> --json --out <plan>
#   gbrain sources connect --plan <plan> --brain host --source <id>     # preview
#   gbrain sources connect --plan <plan> --brain host --source <id> --yes
#   gbrain sources mirror-readonly <id>
#   gbrain sources unfederate <id>
#   gbrain sync --brain host --source <id> --no-embed --no-pull
#
# When the plan is not a ready company-brain (the usual profile_ambiguous
# result on a general vault), registration uses the multi-source idiom
# `sources add <id> --path <repo> --no-federated` instead of connect.
# Raw sources are registered only under GBRAIN_HOME=ingest. The wiki brain
# stays source `default` at wiki-default-checkout. No full-vault copy.
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

if [[ "${BOX_OPS_SMOKE:-}" != "1" ]]; then
  hour=$(date +%H)
  if [[ "$hour" == "02" || "$hour" == "03" ]]; then
    box_ops_log "skip delta during the dream/backup window (02:00-03:59 box local)"
    exit 0
  fi
fi

stamp=$(date +%Y%m%dT%H%M%S)
preview_dir="$STATE_DIR/previews"
mkdir -p "$preview_dir"

declare -a SLICE_NOTES=()
declare -A CLAIMED_ROOT=()

inspect_repo() {
  local name="$1" repo="$2" include="${3:-}"
  local out="$preview_dir/${name}-${stamp}.json"
  local -a args=(sources inspect "$repo" --json --out "$out")
  if [[ -n "$include" ]]; then
    args+=(--include "$include")
  fi
  box_ops_log "gbrain ${args[*]}"
  set +e
  box_ops_gbrain "${args[@]}" > "$preview_dir/${name}-${stamp}.stdout.json"
  local rc=$?
  set -e
  if [[ -f "$out" ]]; then
    cp -f "$out" "$preview_dir/${name}-latest.json"
    chmod 600 "$out" "$preview_dir/${name}-latest.json" || true
  fi
  return "$rc"
}

apply_root() {
  local source_id="$1" repo="$2" plan="$3"
  if [[ ! -f "$plan" ]]; then
    box_ops_log "HOLD $source_id: inspect wrote no plan"
    return 1
  fi
  local mode
  mode=$(box_ops_plan_mode "$plan" 2>"$preview_dir/${source_id}-${stamp}.mode.txt" || true)
  mode=$(printf '%s' "$mode" | head -n 1)
  local approval=0
  if box_ops_approval_allows "$source_id"; then
    approval=1
  else
    local arc=$?
    if [[ "$arc" == "2" ]]; then
      box_ops_log "HOLD apply: approval file asks to import raw trees into the wiki"
      return 1
    fi
  fi
  if [[ "$approval" != "1" ]]; then
    box_ops_log "PREVIEW_ONLY $source_id mode=$mode (no matching ingest approval)"
    return 0
  fi
  if [[ "$mode" != "connect" && "$mode" != "add" ]]; then
    box_ops_log "HOLD $source_id: $(tr '\n' ' ' < "$preview_dir/${source_id}-${stamp}.mode.txt")"
    return 1
  fi

  export GBRAIN_HOME="$INGEST_HOME"
  if ! box_ops_preflight_pglite "$INGEST_HOME" "$INGEST_PGLITE"; then
    return 1
  fi
  if [[ "$GBRAIN_HOME" == "$WIKI_HOME" ]]; then
    box_ops_log "REFUSED $source_id against the wiki home"
    return 1
  fi

  local registered=0 reg_rc=0
  set +e
  box_ops_source_registered "$source_id"
  reg_rc=$?
  set -e
  if [[ "$reg_rc" == "2" ]]; then
    box_ops_log "HOLD $source_id: sources list failed"
    return 1
  fi
  if [[ "$reg_rc" == "0" ]]; then
    registered=1
  fi

  if [[ "$registered" == "0" && "$mode" == "connect" ]]; then
    local receipt="$preview_dir/${source_id}-${stamp}.connect-preview.json"
    set +e
    box_ops_gbrain sources connect --plan "$plan" --brain "$BRAIN_ID" --source "$source_id" --json >"$receipt"
    local crc=$?
    set -e
    box_ops_log "connect preview $source_id exit=$crc (3 means confirmation_required)"
    if ! box_ops_gbrain sources connect --plan "$plan" --brain "$BRAIN_ID" --source "$source_id" --yes --json \
      >"$preview_dir/${source_id}-${stamp}.connect.json"; then
      box_ops_log "connect --yes failed for $source_id; not falling through to a second import"
      return 1
    fi
    registered=1
  elif [[ "$registered" == "0" && "$mode" == "add" ]]; then
    box_ops_log "plan is not company-brain ready; gbrain sources add $source_id --no-federated"
    box_ops_gbrain sources add "$source_id" --path "$repo" --no-federated
    registered=1
  fi

  box_ops_gbrain sources mirror-readonly "$source_id"
  box_ops_gbrain sources unfederate "$source_id"
  box_ops_log "gbrain sync --brain $BRAIN_ID --source $source_id --no-embed --no-pull"
  box_ops_gbrain sync --brain "$BRAIN_ID" --source "$source_id" --no-embed --no-pull
}

consider() {
  local source_id="$1" path="$2" required="${3:-}"
  if [[ ! -d "$path" ]]; then
    SLICE_NOTES+=("$source_id missing")
    box_ops_log "SKIP $source_id: path missing ($path)"
    if [[ "$required" == "required" ]]; then
      return 1
    fi
    return 0
  fi
  local root
  root=$(box_ops_git_root "$path" || true)
  if [[ -z "$root" ]]; then
    SLICE_NOTES+=("$source_id not a git checkout")
    box_ops_log "SKIP $source_id: not a git checkout ($path)"
    if [[ "$required" == "required" ]]; then
      return 1
    fi
    return 0
  fi
  root=$(cd "$root" && pwd -P)
  local real
  real=$(cd "$path" && pwd -P)
  if [[ -n "${CLAIMED_ROOT[$root]:-}" ]]; then
    local rel include
    rel=${real#"$root"/}
    include="${rel}/**"
    SLICE_NOTES+=("$source_id covered by ${CLAIMED_ROOT[$root]} include=$include")
    inspect_repo "$source_id" "$root" "$include" || box_ops_log "slice inspect $source_id exited $?"
    return 0
  fi
  if [[ "$real" != "$root" ]]; then
    box_ops_log "SKIP $source_id: $path is inside $root and that root is not a claimed source"
    return 0
  fi
  CLAIMED_ROOT[$root]=$source_id
  local plan="$preview_dir/${source_id}-${stamp}.json"
  if ! inspect_repo "$source_id" "$root"; then
    box_ops_log "inspect $source_id exited non-zero; apply still requires the plan file"
  fi
  apply_root "$source_id" "$root" "$plan"
}

fail=0
consider vault "$VAULT_PATH" required || fail=1
consider notion-snapshot "$NOTION_SNAPSHOT_PATH" || fail=1
consider notion-meetings "$NOTION_MEETINGS_PATH" || fail=1
consider agentmail "$AGENTMAIL_PATH" || fail=1

notes_file="$preview_dir/notes-${stamp}.txt"
if [[ ${#SLICE_NOTES[@]} -gt 0 ]]; then
  printf '%s\n' "${SLICE_NOTES[@]}" > "$notes_file"
else
  : > "$notes_file"
fi
python3 - "$STATE_DIR/multi-source-preview-latest.json" "$stamp" "$fail" "$notes_file" <<'PY'
import json, sys
path, stamp, fail, notes_path = sys.argv[1:]
notes = [line for line in open(notes_path) if line.strip()]
json.dump({
  "stamp": stamp,
  "ok": fail == "0",
  "wiki_source": "default",
  "raw_brain": "ingest",
  "notes": [line.strip() for line in notes],
}, open(path, "w"))
open(path, "a").write("\n")
PY
chmod 600 "$STATE_DIR/multi-source-preview-latest.json" || true

if [[ "$fail" != "0" ]]; then
  box_ops_log "DELTA_EXIT=1"
  exit 1
fi
box_ops_log "DELTA_EXIT=0"

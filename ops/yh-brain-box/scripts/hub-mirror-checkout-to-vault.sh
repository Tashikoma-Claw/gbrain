#!/usr/bin/env bash
# One-way mirror of hub markdown from the wiki checkout onto the vault.
# Dry-run unless --apply. Does not delete vault-only files.
# Refuses writer_manifest and symlinks. Does not stop serve.
#
# The other direction (vault -> checkout) is not this script. Preview a
# brain import with `gbrain sources inspect` from the Phase 0 delta path.
# Do not point the wiki default source at the vault.
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

apply=()
if [[ "${1:-}" == "--apply" ]]; then
  apply=(--apply)
else
  box_ops_log "hub mirror dry-run (pass --apply to copy checkout hubs onto the vault)"
fi

if [[ ! -d "$WIKI_CHECKOUT" || ! -d "$VAULT_PATH" ]]; then
  box_ops_log "HUB_MIRROR_SKIP checkout or vault missing"
  exit 0
fi

python3 "$HERE/hub_align.py" mirror \
  --checkout "$WIKI_CHECKOUT" \
  --vault "$VAULT_PATH" \
  "${apply[@]}"

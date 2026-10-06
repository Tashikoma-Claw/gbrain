#!/usr/bin/env bash
# Show hub files that differ between the wiki checkout and the vault.
# Read-only. Exit 0 when --strict is absent, even if hubs differ.
# Optional other path: `gbrain sources inspect` (Phase 0 delta) previews
# a brain import. This script does not import and does not stop serve.
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

strict=()
if [[ "${1:-}" == "--strict" ]]; then
  strict=(--strict)
fi

if [[ ! -d "$WIKI_CHECKOUT" || ! -d "$VAULT_PATH" ]]; then
  box_ops_log "HUB_DIFF_SKIP checkout or vault missing"
  exit 0
fi

mkdir -p "$STATE_DIR"
python3 "$HERE/hub_align.py" diff \
  --checkout "$WIKI_CHECKOUT" \
  --vault "$VAULT_PATH" \
  "${strict[@]}" | tee "$STATE_DIR/hub-diff-latest.txt"

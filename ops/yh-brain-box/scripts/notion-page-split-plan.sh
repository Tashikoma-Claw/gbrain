#!/usr/bin/env bash
# Print a split plan for oversized notion-wiki pages. Does not edit them.
# Guidance: ops/yh-brain-box/page-split.md
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
: "${NOTION_WIKI_PATH:=$VAULT_PATH/notion-wiki}"

python3 "$HERE/notion_page_split_plan.py" --dir "$NOTION_WIKI_PATH"

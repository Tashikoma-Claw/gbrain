#!/usr/bin/env bash
# Rebuild hot packs after an approved wiki delta.
#
# Reads vault crm/client-*.md and project hubs (and the wiki checkout when
# it is present) into accounts.slim.json. Does not import the vault into
# the wiki brain and does not stop serve.
#
# No-op when the vault directory is missing (cloud smoke) or when
# state/hot-pack-approve.json has not set "rebuild": true, or when the
# latest multi-source preview is not ok.
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

if [[ ! -d "$VAULT_PATH" ]]; then
  box_ops_log "HOT_PACK_SKIP vault missing ($VAULT_PATH)"
  exit 0
fi

if [[ ! -f "$HOT_PACK_APPROVAL" ]]; then
  box_ops_log "HOT_PACK_HOLD no $HOT_PACK_APPROVAL (wiki-delta hot-pack approval)"
  exit 0
fi
if ! python3 - "$HOT_PACK_APPROVAL" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
ok = doc.get("rebuild") is True or doc.get("approved") is True
sys.exit(0 if ok else 1)
PY
then
  box_ops_log "HOT_PACK_HOLD approval file does not set rebuild=true"
  exit 0
fi

preview="$STATE_DIR/multi-source-preview-latest.json"
if [[ ! -f "$preview" ]]; then
  box_ops_log "HOT_PACK_HOLD no multi-source preview yet"
  exit 0
fi
if ! python3 - "$preview" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
sys.exit(0 if doc.get("ok") is True else 1)
PY
then
  box_ops_log "HOT_PACK_HOLD latest multi-source preview is not ok"
  exit 0
fi

python3 "$HERE/build_hot_packs.py" \
  --vault "$VAULT_PATH" \
  --checkout "$WIKI_CHECKOUT" \
  --out "$HOT_PACK_OUT"

#!/usr/bin/env bash
# Report the retired source marker in packaged or live shell/python files.
# Exit 1 when a scanned file contains it. Skips this scanner.
# Does not delete live scripts. See APPLY.md for the box cleanup.
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

token='yh-brain'
roots=("$@")
if [[ ${#roots[@]} -eq 0 ]]; then
  roots=("$HERE" "$HERE/../lib")
fi

fail=0
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  base=$(basename "$path")
  if [[ "$base" == "legacy-marker-scan.sh" ]]; then
    continue
  fi
  # Package path yh-brain-box contains the marker as a prefix. Match the
  # retired source id, not that directory name.
  if grep -nE "${token}([^A-Za-z0-9-]|$)" "$path"; then
    box_ops_log "LEGACY_MARKER $path"
    fail=1
  fi
done < <(find "${roots[@]}" -type f \( -name '*.sh' -o -name '*.py' \) 2>/dev/null | sort)

if [[ "$fail" != "0" ]]; then
  box_ops_log "LEGACY_MARKER_PRESENT replace those copies with this package. Do not delete gbrain-restart-serves.sh."
  exit 1
fi
box_ops_log "LEGACY_MARKER_CLEAR"

#!/usr/bin/env bash
# Guarded copy of a writer_manifest file.
#
# Refuses unless every gate is present:
#   --apply
#   WRITER_MANIFEST_TRANSFER=yes
#   --src <file>
#   --dest <file>
# Destinations inside VAULT_PATH also need --allow-vault.
# This script is not on the cron. The hub mirror never calls it.
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

apply=0
allow_vault=0
src=""
dest=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) apply=1 ;;
    --allow-vault) allow_vault=1 ;;
    --src) src="${2:-}"; shift ;;
    --dest) dest="${2:-}"; shift ;;
    *)
      box_ops_log "REFUSED unknown argument"
      exit 3
      ;;
  esac
  shift
done

refuse() {
  box_ops_log "REFUSED writer_manifest transfer: $*"
  box_ops_log "required: --apply --src <file> --dest <file> and WRITER_MANIFEST_TRANSFER=yes"
  box_ops_log "a destination inside the vault also needs --allow-vault"
  exit 3
}

[[ "$apply" == "1" ]] || refuse "missing --apply"
[[ "${WRITER_MANIFEST_TRANSFER:-}" == "yes" ]] || refuse "WRITER_MANIFEST_TRANSFER is not yes"
[[ -n "$src" && -f "$src" ]] || refuse "missing --src file"
[[ -n "$dest" ]] || refuse "missing --dest"
base=$(basename "$src")
[[ "$base" == "writer_manifest" || "$base" == writer_manifest.* ]] || refuse "src is not a writer_manifest"
if [[ "$dest" == "$VAULT_PATH" || "$dest" == "$VAULT_PATH"/* ]]; then
  [[ "$allow_vault" == "1" ]] || refuse "dest is inside the vault"
fi
if [[ -L "$src" ]]; then
  refuse "src is a symlink"
fi

mkdir -p "$(dirname "$dest")"
cp -P "$src" "$dest"
box_ops_log "writer_manifest copied to $dest"

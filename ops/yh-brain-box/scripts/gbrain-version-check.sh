#!/usr/bin/env bash
# Compare the installed gbrain to the package target (0.60.82).
# Prints the manual upgrade command. Does not run `gbrain upgrade`.
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

target_file=""
for candidate in "$HERE/../TARGET_VERSION" "$STATE_DIR/TARGET_VERSION"; do
  if [[ -f "$candidate" ]]; then
    target_file=$candidate
    break
  fi
done
if [[ -n "$target_file" ]]; then
  TARGET_GBRAIN_VERSION=$(head -n 1 "$target_file" | tr -d '[:space:]')
fi

if ! command -v "${GBRAIN_BIN:-gbrain}" >/dev/null 2>&1 && [[ ! -x "${GBRAIN_BIN:-}" ]]; then
  box_ops_log "VERSION_UNKNOWN gbrain is not on PATH"
  exit 2
fi

ver=$(box_ops_gbrain --version 2>/dev/null || true)
out="$STATE_DIR/version-check.txt"
python3 - "$ver" "$TARGET_GBRAIN_VERSION" "$out" <<'PY'
import sys
raw, target, dest = sys.argv[1:]

def parts(text):
    for token in text.replace("v", " ").replace(",", " ").split():
        head = token.split("-", 1)[0]
        if head and head[0].isdigit() and "." in head:
            nums = []
            for piece in head.split("."):
                if piece.isdigit():
                    nums.append(int(piece))
                else:
                    break
            if nums:
                return nums
    return []

got = parts(raw)
want = parts(target)
width = max(len(got), len(want), 1)
got = got + [0] * (width - len(got))
want = want + [0] * (width - len(want))
if not parts(raw):
    state = "VERSION_UNKNOWN"
elif got < want:
    state = "VERSION_BEHIND"
else:
    state = "VERSION_OK"
manual = "gbrain upgrade"
text = "\n".join([
    f"{state} installed={raw.strip() or 'unknown'} target={target}",
    "check: gbrain --version",
    "check: gbrain check-update --json",
    f"manual: {manual}",
    "cron must not run the manual command",
    "",
])
open(dest, "w").write(text)
print(state)
PY
chmod 600 "$out" || true
box_ops_log "version check written $out"
# Quiet cron: behind is not a failure. The status file names the manual command.
exit 0

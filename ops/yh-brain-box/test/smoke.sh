#!/usr/bin/env bash
# Box-ops smoke test. Uses a stub gbrain and local git remotes.
# Does not open a brain and does not run dream.
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
OPS="$ROOT/ops/yh-brain-box"
BIN="$OPS/bin"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() {
  local name="$1"
  shift
  if "$@"; then
    printf 'ok %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name" >&2
    fail=1
  fi
}

for script in "$OPS"/bin/*.sh "$OPS"/lib/box-ops-common.sh "$OPS"/test/smoke.sh; do
  bash -n "$script"
done
printf 'ok bash -n\n'

if grep -nE 'git push([^\\]|\\[[:space:]])*--force|git push -f' "$OPS"/bin/*.sh "$OPS"/lib/*.sh; then
  echo "FAIL force-push present" >&2
  fail=1
else
  printf 'ok no force-push\n'
fi

export HOME="$TMP/home"
mkdir -p "$HOME"
export BOX_OPS_SMOKE=1
export BOX_ENV_FILE="$TMP/no-box-env"
export GBRAIN_BIN="$TMP/gbrain"
export GBRAIN_STUB_LOG="$TMP/gbrain.log"
export RESTART_SERVES="$TMP/restart.sh"
export GBRAIN_SERVE_PORT=18792
printf '#!/bin/bash\necho start >> "$TMP/restart.log"\n' > "$RESTART_SERVES"
# The restart script must see TMP. Inline it.
cat > "$RESTART_SERVES" <<EOF
#!/bin/bash
echo start >> "$TMP/restart.log"
EOF
chmod 755 "$RESTART_SERVES"

cat > "$GBRAIN_BIN" <<'EOF'
#!/bin/bash
home="${GBRAIN_HOME:-}"
if [[ -n "${GBRAIN_DATABASE_URL:-}${DATABASE_URL:-}" ]]; then db=set; else db=unset; fi
if [[ -n "${ZHIPUAI_API_KEY:-}" ]]; then key=set; else key=unset; fi
{
  printf 'home=%s db=%s key=%s ::' "$home" "$db" "$key"
  printf ' %q' "$@"
  printf '\n'
} >> "${GBRAIN_STUB_LOG:?}"
out=""
plan_mode="${GBRAIN_STUB_PLAN:-add}"
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--out" ]]; then
    out="${args[$((i+1))]}"
  fi
  if [[ "${args[$i]}" == "--output" ]]; then
    : > "${args[$((i+1))]}"
  fi
done
if [[ "${args[0]}" == "sources" && "${args[1]}" == "inspect" ]]; then
  case "$plan_mode" in
    connect) printf '%s\n' '{"ready":true,"findings":[]}' > "$out"; exit 0 ;;
    hold) printf '%s\n' '{"ready":false,"findings":[{"severity":"error","code":"source_not_ready","message":"dirty"}]}' > "$out"; exit 1 ;;
    *) printf '%s\n' '{"ready":false,"findings":[{"severity":"error","code":"profile_ambiguous","message":"review"}]}' > "$out"; exit 1 ;;
  esac
fi
if [[ "${args[0]}" == "sources" && "${args[1]}" == "connect" ]]; then
  if [[ " $* " != *" --yes "* ]]; then
    exit 3
  fi
  exit 0
fi
if [[ "${args[0]}" == "sources" && "${args[1]}" == "list" ]]; then
  printf '%s\n' '{"sources":[]}'
  exit 0
fi
if [[ "${args[0]}" == "dream" ]]; then
  printf '%s\n' '{"ok":true}'
  exit 0
fi
if [[ "${args[0]}" == "doctor" ]]; then
  printf '%s\n' '{"health_score":70}'
  exit 0
fi
if [[ "${args[0]}" == "check-update" ]]; then
  printf '%s\n' '{"update_available":false}'
  exit 0
fi
exit 0
EOF
chmod 755 "$GBRAIN_BIN"

pglite_home() {
  local home="$1" data="$2"
  mkdir -p "$home" "$data"
  python3 - "$home/config.json" "$data" <<'PY'
import json, sys
json.dump({"engine": "pglite", "database_path": sys.argv[2]}, open(sys.argv[1], "w"))
PY
}

run_dream() {
  # CI is forced off here. The hosted-URL case passes GBRAIN_DATABASE_URL
  # through so the script, not this wrapper, is what clears it.
  env \
    BOX_OPS_SMOKE=1 CI= \
    HOME="$HOME" BOX_ENV_FILE="$BOX_ENV_FILE" GBRAIN_BIN="$GBRAIN_BIN" \
    GBRAIN_STUB_LOG="$GBRAIN_STUB_LOG" RESTART_SERVES="$RESTART_SERVES" \
    WIKI_HOME="$WIKI_HOME" WIKI_PGLITE="$WIKI_PGLITE" INGEST_HOME="$INGEST_HOME" \
    INGEST_PGLITE="$INGEST_PGLITE" STATE_DIR="$STATE_DIR" LOCK_FILE="$STATE_DIR/brain-ops.lock" \
    BRAIN_OS="$BRAIN_OS" VAULT_PATH="$VAULT_PATH" WIKI_CHECKOUT="$WIKI_CHECKOUT" \
    BACKUP_DIR="$BACKUP_DIR" SG_ENV="$SG_ENV" \
    DREAM_SOURCE="${DREAM_SOURCE-}" \
    DREAM_PHASES="${DREAM_PHASES-}" \
    GBRAIN_DATABASE_URL="${GBRAIN_DATABASE_URL-}" \
    DATABASE_URL="${DATABASE_URL-}" \
    "$BIN/gbrain-dream-nightly.sh"
}

# --- dream: CI refusal ---
: > "$GBRAIN_STUB_LOG"
if CI=true BOX_OPS_SMOKE= "$BIN/gbrain-dream-nightly.sh" >"$TMP/ci.out" 2>"$TMP/ci.err"; then
  echo "FAIL ci dream should exit" >&2
  fail=1
else
  grep -q DREAM_HOST_ONLY "$TMP/ci.err"
  printf 'ok dream refuses CI\n'
fi
[[ ! -s "$GBRAIN_STUB_LOG" ]]
printf 'ok dream CI did not call gbrain\n'

BRAIN_OS="$TMP/brain-os"
STATE_DIR="$BRAIN_OS/state"
mkdir -p "$STATE_DIR" "$BRAIN_OS/logs"
WIKI_HOME="$TMP/wiki-home"
WIKI_PGLITE="$WIKI_HOME/wiki.pglite"
INGEST_HOME="$TMP/ingest-home"
INGEST_PGLITE="$INGEST_HOME/ingest.pglite"
VAULT_PATH="$TMP/vault"
WIKI_CHECKOUT="$TMP/wiki-checkout"
BACKUP_DIR="$TMP/backups"
SG_ENV="$TMP/sg.env"
printf 'ZHIPUAI_API_KEY=smoke-zhipu-not-real\n' > "$SG_ENV"
chmod 600 "$SG_ENV"
pglite_home "$WIKI_HOME" "$WIKI_PGLITE"
pglite_home "$INGEST_HOME" "$INGEST_PGLITE"

# host-only when the data dir is absent
saved="$WIKI_PGLITE"
WIKI_PGLITE="$TMP/missing-pglite"
: > "$GBRAIN_STUB_LOG"
if DREAM_SOURCE= WIKI_PGLITE="$WIKI_PGLITE" run_dream >"$TMP/miss.out" 2>"$TMP/miss.err"; then
  echo "FAIL missing pglite should exit" >&2
  fail=1
else
  grep -q DREAM_HOST_ONLY "$TMP/miss.err"
  printf 'ok dream host-only without PGLite dir\n'
fi
WIKI_PGLITE="$saved"

# retired source
: > "$GBRAIN_STUB_LOG"
if DREAM_SOURCE=yh-brain run_dream >"$TMP/yh.out" 2>"$TMP/yh.err"; then
  echo "FAIL yh-brain should exit 3" >&2
  fail=1
else
  [[ "$?" == "3" || "$(cat "$STATE_DIR/dream-last-exit")" == "3" ]]
  grep -q DREAM_BLOCKED "$TMP/yh.err"
  [[ ! -s "$GBRAIN_STUB_LOG" ]]
  printf 'ok dream blocks yh-brain\n'
fi

# postgres config
python3 - "$WIKI_HOME/config.json" <<'PY'
import json, sys
json.dump({"engine": "postgres", "database_url": "postgres://localhost/retired"}, open(sys.argv[1], "w"))
PY
: > "$GBRAIN_STUB_LOG"
if DREAM_SOURCE= run_dream >"$TMP/pg.out" 2>"$TMP/pg.err"; then
  echo "FAIL postgres preflight should exit" >&2
  fail=1
else
  grep -q PREFLIGHT_FAIL "$TMP/pg.err"
  [[ ! -s "$GBRAIN_STUB_LOG" ]]
  printf 'ok dream rejects hosted engine config\n'
fi
pglite_home "$WIKI_HOME" "$WIKI_PGLITE"

# happy dream, plus a hosted URL in the environment that must be cleared
: > "$GBRAIN_STUB_LOG"
: > "$TMP/restart.log"
if ! GBRAIN_DATABASE_URL='postgres://supabase.example/db' DATABASE_URL='postgres://mumbai.example/db' \
  DREAM_SOURCE= run_dream >"$TMP/dream.out" 2>"$TMP/dream.err"; then
  echo "FAIL dream happy path" >&2
  cat "$TMP/dream.err" >&2
  fail=1
else
  grep -q 'NIGHTLY_EXIT=0' "$TMP/dream.err"
  grep -q 'home='"$WIKI_HOME"' db=unset key=set :: dream --source default --json' "$GBRAIN_STUB_LOG"
  grep -q start "$TMP/restart.log"
  if grep -q 'smoke-zhipu-not-real' "$TMP/dream.err" "$GBRAIN_STUB_LOG"; then
    echo "FAIL key leaked" >&2
    fail=1
  fi
  if grep -q -- '--phase' "$GBRAIN_STUB_LOG"; then
    echo "FAIL default dream must be the full cycle" >&2
    fail=1
  fi
  printf 'ok dream source default on PGLite\n'
fi

# phase alias
: > "$GBRAIN_STUB_LOG"
DREAM_PHASES='backlinks,extract_stale,extract' DREAM_SOURCE= run_dream >"$TMP/ph.out" 2>"$TMP/ph.err"
grep -q 'dream --source default --phase backlinks --phase extract --json' "$GBRAIN_STUB_LOG"
if grep -q extract_stale "$GBRAIN_STUB_LOG"; then
  echo "FAIL extract_stale was passed to gbrain" >&2
  fail=1
else
  printf 'ok extract_stale maps to extract once\n'
fi

# --- backup ---
git_identity() {
  git -C "$1" config user.email 'ops@example.invalid'
  git -C "$1" config user.name 'ops'
}
init_pair() {
  local name="$1"
  local work="$2"
  local bare="$TMP/bare-$name"
  git init -q --bare -b main "$bare"
  git init -q "$work"
  git_identity "$work"
  echo seed > "$work/README.md"
  git -C "$work" add README.md
  git -C "$work" commit -q -m seed
  git -C "$work" branch -M main
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -q origin main
  printf '%s\n' "$bare"
}

mkdir -p "$VAULT_PATH" "$WIKI_CHECKOUT" "$BACKUP_DIR"
VAULT_BARE=$(init_pair vault "$VAULT_PATH")
WIKI_BARE=$(init_pair wiki "$WIKI_CHECKOUT")
# local file remotes are not the private GitHub URLs; the test flag allows them
echo more > "$VAULT_PATH/more.md"
git -C "$VAULT_PATH" add more.md
git -C "$VAULT_PATH" commit -q -m more
echo dirty > "$VAULT_PATH/untracked.md"
: > "$GBRAIN_STUB_LOG"
: > "$TMP/restart.log"
if ! BACKUP_ALLOW_LOCAL_REMOTE=1 BACKUP_KEEP=2 \
  env HOME="$HOME" BOX_ENV_FILE="$BOX_ENV_FILE" GBRAIN_BIN="$GBRAIN_BIN" \
    GBRAIN_STUB_LOG="$GBRAIN_STUB_LOG" RESTART_SERVES="$RESTART_SERVES" \
    BOX_OPS_SMOKE=1 \
    WIKI_HOME="$WIKI_HOME" WIKI_PGLITE="$WIKI_PGLITE" \
    VAULT_PATH="$VAULT_PATH" WIKI_CHECKOUT="$WIKI_CHECKOUT" \
    BACKUP_DIR="$BACKUP_DIR" STATE_DIR="$STATE_DIR" BRAIN_OS="$BRAIN_OS" \
    LOCK_FILE="$STATE_DIR/brain-ops.lock" \
    BACKUP_ALLOW_LOCAL_REMOTE=1 BACKUP_KEEP=2 \
    "$BIN/backup-push.sh" >"$TMP/bk.out" 2>"$TMP/bk.err"; then
  echo "FAIL backup happy path" >&2
  cat "$TMP/bk.err" >&2
  fail=1
else
  if [[ "$(git -C "$VAULT_BARE" rev-parse refs/heads/main)" != "$(git -C "$VAULT_PATH" rev-parse HEAD)" ]]; then
    echo "FAIL vault remote was not fast-forwarded" >&2
    fail=1
  fi
  grep -q 'dirty_paths=1' "$TMP/bk.err"
  grep -q 'backup create --output '"$BACKUP_DIR" "$GBRAIN_STUB_LOG"
  archives=$(find "$BACKUP_DIR" -name 'wiki-*.gbrain-backup' | wc -l)
  # one new archive; keep=2
  test "$archives" -le 2
  printf 'ok backup fast-forward and create\n'
fi

# diverged: do not move the remote
git -C "$VAULT_PATH" commit -q --allow-empty -m local-only
other="$TMP/other-vault"
git clone -q "$VAULT_BARE" "$other"
git_identity "$other"
git -C "$other" commit -q --allow-empty -m remote-only
git -C "$other" push -q origin main
before=$(git -C "$VAULT_BARE" rev-parse refs/heads/main)
if BACKUP_ALLOW_LOCAL_REMOTE=1 BACKUP_CREATE=0 \
  env HOME="$HOME" BOX_ENV_FILE="$BOX_ENV_FILE" GBRAIN_BIN="$GBRAIN_BIN" \
    GBRAIN_STUB_LOG="$GBRAIN_STUB_LOG" RESTART_SERVES="$RESTART_SERVES" BOX_OPS_SMOKE=1 \
    WIKI_HOME="$WIKI_HOME" WIKI_PGLITE="$WIKI_PGLITE" \
    VAULT_PATH="$VAULT_PATH" WIKI_CHECKOUT="$WIKI_CHECKOUT" \
    BACKUP_DIR="$BACKUP_DIR" STATE_DIR="$STATE_DIR" BRAIN_OS="$BRAIN_OS" \
    LOCK_FILE="$STATE_DIR/brain-ops.lock" \
    BACKUP_ALLOW_LOCAL_REMOTE=1 BACKUP_CREATE=0 \
    "$BIN/backup-push.sh" >"$TMP/div.out" 2>"$TMP/div.err"; then
  echo "FAIL diverged push should fail" >&2
  fail=1
else
  if [[ "$(git -C "$VAULT_BARE" rev-parse refs/heads/main)" != "$before" ]]; then
    echo "FAIL diverged push moved the remote" >&2
    fail=1
  fi
  grep -q 'Not force-pushing' "$TMP/div.err"
  printf 'ok backup refuses non-fast-forward\n'
fi

git -C "$VAULT_PATH" remote set-url origin 'https://example.supabase.co/Tashikoma-Claw/YH-Brain.git'
if BACKUP_CREATE=0 \
  env HOME="$HOME" BOX_ENV_FILE="$BOX_ENV_FILE" GBRAIN_BIN="$GBRAIN_BIN" \
    GBRAIN_STUB_LOG="$GBRAIN_STUB_LOG" RESTART_SERVES="$RESTART_SERVES" BOX_OPS_SMOKE=1 \
    WIKI_HOME="$WIKI_HOME" WIKI_PGLITE="$WIKI_PGLITE" \
    VAULT_PATH="$VAULT_PATH" WIKI_CHECKOUT="$WIKI_CHECKOUT" \
    BACKUP_DIR="$BACKUP_DIR" STATE_DIR="$STATE_DIR" BRAIN_OS="$BRAIN_OS" \
    LOCK_FILE="$STATE_DIR/brain-ops.lock" BACKUP_CREATE=0 \
    "$BIN/backup-push.sh" >"$TMP/sb.out" 2>"$TMP/sb.err"; then
  echo "FAIL supabase remote should fail" >&2
  fail=1
else
  grep -q REFUSED "$TMP/sb.err"
  printf 'ok backup refuses supabase remote\n'
fi

# --- delta ---
delta_env() {
  env HOME="$HOME" BOX_ENV_FILE="$BOX_ENV_FILE" GBRAIN_BIN="$GBRAIN_BIN" \
    GBRAIN_STUB_LOG="$GBRAIN_STUB_LOG" BOX_OPS_SMOKE=1 \
    WIKI_HOME="$WIKI_HOME" WIKI_PGLITE="$WIKI_PGLITE" \
    INGEST_HOME="$INGEST_HOME" INGEST_PGLITE="$INGEST_PGLITE" \
    VAULT_PATH="$VAULT_PATH" \
    NOTION_SNAPSHOT_PATH="${NOTION_SNAPSHOT_PATH:-$TMP/missing-notion}" \
    NOTION_MEETINGS_PATH="${NOTION_MEETINGS_PATH:-$TMP/missing-meetings}" \
    AGENTMAIL_PATH="${AGENTMAIL_PATH:-$TMP/missing-mail}" \
    STATE_DIR="$STATE_DIR" BRAIN_OS="$BRAIN_OS" \
    APPROVAL_FILE="${APPROVAL_FILE:-$TMP/no-approval.json}" \
    "$BIN/gbrain-multi-source-delta.sh"
}

# reset vault remote to the local bare so later tests are irrelevant; delta doesn't push
rm -rf "$VAULT_PATH"
git init -q "$VAULT_PATH"
git_identity "$VAULT_PATH"
mkdir -p "$VAULT_PATH/notion-snapshot"
echo '# hub' > "$VAULT_PATH/README.md"
echo '# snap' > "$VAULT_PATH/notion-snapshot/page.md"
git -C "$VAULT_PATH" add README.md notion-snapshot/page.md
git -C "$VAULT_PATH" commit -q -m vault

: > "$GBRAIN_STUB_LOG"
export GBRAIN_STUB_PLAN=add
if ! delta_env >"$TMP/d1.out" 2>"$TMP/d1.err"; then
  echo "FAIL preview-only delta" >&2
  cat "$TMP/d1.err" >&2
  fail=1
else
  grep -q 'sources inspect' "$GBRAIN_STUB_LOG"
  if grep -q 'sources add\|sources connect\| sync ' "$GBRAIN_STUB_LOG"; then
    echo "FAIL preview-only invoked import" >&2
    cat "$GBRAIN_STUB_LOG" >&2
    fail=1
  else
    printf 'ok delta preview does not import\n'
  fi
fi

APPROVAL_FILE="$STATE_DIR/multi-source-approve.json"
cat > "$APPROVAL_FILE" <<'EOF'
{"ingest_raw": true, "source_ids": ["vault", "notion-snapshot", "notion-meetings", "agentmail"], "wiki_import": false}
EOF
: > "$GBRAIN_STUB_LOG"
NOTION_SNAPSHOT_PATH="$VAULT_PATH/notion-snapshot" \
  delta_env >"$TMP/d2.out" 2>"$TMP/d2.err" || { echo "FAIL delta add"; cat "$TMP/d2.err"; fail=1; }
if ! grep -q "sources add vault --path $VAULT_PATH --no-federated" "$GBRAIN_STUB_LOG"; then
  # %q quoting may differ; check the pieces on the add line
  if ! grep 'sources add' "$GBRAIN_STUB_LOG" | grep -q vault || ! grep 'sources add' "$GBRAIN_STUB_LOG" | grep -q -- '--no-federated'; then
    echo "FAIL expected sources add --no-federated" >&2
    cat "$GBRAIN_STUB_LOG" >&2
    fail=1
  fi
fi
add_lines=$(grep -c 'sources add' "$GBRAIN_STUB_LOG" || true)
if [[ "$add_lines" != "1" ]]; then
  echo "FAIL overlapping slice was registered separately ($add_lines)" >&2
  cat "$GBRAIN_STUB_LOG" >&2
  fail=1
else
  grep -q 'mirror-readonly' "$GBRAIN_STUB_LOG"
  grep -q 'unfederate' "$GBRAIN_STUB_LOG"
  grep -q -- '--no-embed' "$GBRAIN_STUB_LOG"
  grep -q -- '--no-pull' "$GBRAIN_STUB_LOG"
  grep -q -- '--include' "$GBRAIN_STUB_LOG"
  if grep "sources add\|mirror-readonly\|unfederate\| sync " "$GBRAIN_STUB_LOG" | grep -q "home=$WIKI_HOME"; then
    echo "FAIL raw import targeted the wiki home" >&2
    fail=1
  fi
  grep "sources add" "$GBRAIN_STUB_LOG" | grep -q "home=$INGEST_HOME"
  printf 'ok delta add on ingest, slice stays a preview\n'
fi

export GBRAIN_STUB_PLAN=connect
: > "$GBRAIN_STUB_LOG"
if ! delta_env >"$TMP/d3.out" 2>"$TMP/d3.err"; then
  echo "FAIL delta connect" >&2
  cat "$TMP/d3.err" >&2
  fail=1
else
  grep -q 'sources connect' "$GBRAIN_STUB_LOG"
  grep -q -- '--yes' "$GBRAIN_STUB_LOG"
  if grep -q 'sources add' "$GBRAIN_STUB_LOG"; then
    echo "FAIL connect path also added" >&2
    fail=1
  else
    printf 'ok delta connect preview then --yes\n'
  fi
fi

export GBRAIN_STUB_PLAN=hold
: > "$GBRAIN_STUB_LOG"
if delta_env >"$TMP/d4.out" 2>"$TMP/d4.err"; then
  echo "FAIL hold should fail" >&2
  fail=1
else
  if grep -q 'sources add\|sources connect\| sync ' "$GBRAIN_STUB_LOG"; then
    echo "FAIL hold still imported" >&2
    cat "$GBRAIN_STUB_LOG" >&2
    fail=1
  else
    printf 'ok delta holds a dirty plan\n'
  fi
fi

export GBRAIN_STUB_PLAN=add
python3 - "$APPROVAL_FILE" <<'PY'
import json, sys
json.dump({"ingest_raw": True, "wiki_import": True, "source_ids": ["vault"]}, open(sys.argv[1], "w"))
PY
: > "$GBRAIN_STUB_LOG"
if delta_env >"$TMP/d5.out" 2>"$TMP/d5.err"; then
  echo "FAIL wiki_import should fail" >&2
  fail=1
else
  if grep -q 'sources add' "$GBRAIN_STUB_LOG"; then
    echo "FAIL wiki_import still added" >&2
    fail=1
  else
    printf 'ok delta refuses wiki import\n'
  fi
fi

# --- hygiene ---
: > "$GBRAIN_STUB_LOG"
: > "$TMP/restart.log"
if ! env HOME="$HOME" BOX_ENV_FILE="$BOX_ENV_FILE" GBRAIN_BIN="$GBRAIN_BIN" \
  GBRAIN_STUB_LOG="$GBRAIN_STUB_LOG" RESTART_SERVES="$RESTART_SERVES" BOX_OPS_SMOKE=1 \
  WIKI_HOME="$WIKI_HOME" WIKI_PGLITE="$WIKI_PGLITE" STATE_DIR="$STATE_DIR" \
  BRAIN_OS="$BRAIN_OS" LOCK_FILE="$STATE_DIR/brain-ops.lock" \
  "$BIN/gbrain-daily-hygiene.sh" >"$TMP/hy.out" 2>"$TMP/hy.err"; then
  echo "FAIL hygiene" >&2
  cat "$TMP/hy.err" >&2
  fail=1
else
  grep -q 'doctor --json' "$GBRAIN_STUB_LOG"
  grep -q 'check-update --json' "$GBRAIN_STUB_LOG"
  if grep -q 'upgrade' "$GBRAIN_STUB_LOG"; then
    echo "FAIL hygiene ran upgrade" >&2
    fail=1
  else
    printf 'ok hygiene doctor and check-update\n'
  fi
fi

# --- notion + digest ---
export NOTION_LAST_SYNC="$STATE_DIR/last_sync.json"
python3 - "$NOTION_LAST_SYNC" <<'PY'
import json, sys
json.dump({"synced_at": "2026-10-01T00:00:00+08:00", "pages": 3}, open(sys.argv[1], "w"))
PY
if env HOME="$HOME" BOX_ENV_FILE="$BOX_ENV_FILE" STATE_DIR="$STATE_DIR" BRAIN_OS="$BRAIN_OS" \
  NOTION_LAST_SYNC="$NOTION_LAST_SYNC" NOTION_STALE_HOURS=36 \
  "$BIN/notion-delta.sh" --check >"$TMP/n1.out" 2>"$TMP/n1.err"; then
  echo "FAIL stale notion should fail" >&2
  fail=1
else
  grep -q NOTION_STALE "$TMP/n1.err"
  printf 'ok notion stale check\n'
fi
python3 - "$NOTION_LAST_SYNC" <<'PY'
import json, sys
from datetime import datetime, timezone
json.dump({"synced_at": datetime.now(timezone.utc).isoformat(), "pages": 3}, open(sys.argv[1], "w"))
PY
env HOME="$HOME" BOX_ENV_FILE="$BOX_ENV_FILE" STATE_DIR="$STATE_DIR" BRAIN_OS="$BRAIN_OS" \
  NOTION_LAST_SYNC="$NOTION_LAST_SYNC" "$BIN/notion-delta.sh" --check >"$TMP/n2.out" 2>"$TMP/n2.err"
printf 'ok notion fresh check\n'
if env HOME="$HOME" BOX_ENV_FILE="$BOX_ENV_FILE" STATE_DIR="$STATE_DIR" BRAIN_OS="$BRAIN_OS" \
  NOTION_DELTA_CMD= "$BIN/notion-delta.sh" >"$TMP/n3.out" 2>"$TMP/n3.err"; then
  echo "FAIL missing exporter should exit 2" >&2
  fail=1
else
  [[ $? -eq 2 || "$(tail -n 1 "$TMP/n3.err" | grep -c NOTION_EXPORTER_MISSING)" == "1" ]]
  printf 'ok notion exporter missing\n'
fi

if ! env HOME="$HOME" BOX_ENV_FILE="$BOX_ENV_FILE" \
  INGEST_HOME="$INGEST_HOME" INGEST_PGLITE="$INGEST_PGLITE" \
  WIKI_HOME="$WIKI_HOME" WIKI_PGLITE="$WIKI_PGLITE" \
  STATE_DIR="$STATE_DIR" BRAIN_OS="$BRAIN_OS" \
  "$BIN/pipeline-digest.sh" >"$TMP/dg.out" 2>"$TMP/dg.err"; then
  echo "FAIL digest" >&2
  cat "$TMP/dg.err" >&2
  fail=1
else
  grep -q 'OK pipeline digest -> ingest.pglite' "$TMP/dg.out"
  printf 'ok pipeline digest\n'
fi

if [[ "$fail" != "0" ]]; then
  echo "smoke failed" >&2
  exit 1
fi
echo "smoke passed"

#!/usr/bin/env bash
# Phase 2 box-ops smoke. Stub gbrain only. No live dream, no live PGLite.
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
OPS="$ROOT/ops/yh-brain-box"
BIN="$OPS/scripts"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
# Ambient shells sometimes export a short gap. The embed assertion wants the default.
unset SERVE_GAP_MAX_SECONDS EMBED_CAP EMBED_CONSENT EMBED_CAP_OVERRIDE || true
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

for script in "$OPS"/scripts/*.sh "$OPS"/lib/box-ops-common.sh "$OPS"/test/smoke-phase2.sh; do
  bash -n "$script"
done
printf 'ok bash -n\n'

if grep -n '/home/box' "$OPS"/scripts/*.py; then
  echo "FAIL python hard-codes /home/box" >&2
  fail=1
else
  printf 'ok python paths are parameterized\n'
fi

if grep -nE -- '--all|--catch-up' "$OPS"/scripts/gbrain-embed-stale.sh "$OPS"/lib/box-ops-common.sh \
  | grep -v REFUSED | grep -v '==' | grep -vi never; then
  echo "FAIL embed script passes --all or --catch-up" >&2
  fail=1
else
  printf 'ok embed script has no live --all\n'
fi

# shellcheck source=/dev/null
source "$OPS/lib/box-ops-common.sh"
export BOX_ENV_FILE="$TMP/no-box-env"
export STATE_DIR="$TMP/state-defaults"
export BRAIN_OS="$TMP/brain-os"
mkdir -p "$STATE_DIR"
box_ops_load
if [[ "$LOCK_FILE" == "$DB_LOCK_FILE" ]]; then
  echo "FAIL long lock and db lock are the same file" >&2
  fail=1
else
  printf 'ok lock files differ\n'
fi
gap=$(SERVE_GAP_MAX_SECONDS=5000 box_ops_serve_gap_max)
if [[ "$gap" != "1200" ]]; then
  echo "FAIL serve gap clamp got $gap" >&2
  fail=1
else
  printf 'ok serve gap clamps to 1200\n'
fi
if ! grep -q 'serve_stop_begin unlimited' "$BIN/gbrain-dream-nightly.sh"; then
  echo "FAIL dream is not on the unlimited serve window" >&2
  fail=1
else
  printf 'ok dream serve window is unlimited\n'
fi
if grep -q 'box_ops_lock_wait' "$BIN/gbrain-daily-hygiene.sh"; then
  echo "FAIL hygiene still waits on the long lock" >&2
  fail=1
else
  printf 'ok hygiene does not take the long lock\n'
fi
grep -q 'serve_stop_begin limited' "$BIN/gbrain-daily-hygiene.sh"
grep -q 'serve_stop_begin limited' "$BIN/gbrain-embed-stale.sh"
printf 'ok doctor and embed use the limited serve window\n'

export HOME="$TMP/home"
mkdir -p "$HOME"
export GBRAIN_BIN="$TMP/gbrain"
export GBRAIN_STUB_LOG="$TMP/gbrain.log"
export RESTART_SERVES="$TMP/restart.sh"
export GBRAIN_SERVE_PORT=18792
cat > "$RESTART_SERVES" <<EOF
#!/bin/bash
echo start >> "$TMP/restart.log"
EOF
chmod 755 "$RESTART_SERVES"

cat > "$GBRAIN_BIN" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' "${GBRAIN_STUB_VERSION:-0.60.81}"
  printf 'version\n' >> "${GBRAIN_STUB_LOG:?}"
  exit 0
fi
{
  printf 'budget=%s home=%s ::' "${GBRAIN_EMBED_TIME_BUDGET_MS:-}" "${GBRAIN_HOME:-}"
  printf ' %q' "$@"
  printf '\n'
} >> "${GBRAIN_STUB_LOG:?}"
if [[ "${1:-}" == "doctor" ]]; then
  if [[ -n "${GBRAIN_STUB_DOCTOR:-}" ]]; then
    printf '%s\n' "$GBRAIN_STUB_DOCTOR"
  else
    printf '%s\n' '{"status":"healthy","health_score":90}'
  fi
  exit 0
fi
if [[ "${1:-}" == "embed" ]]; then
  if [[ " $* " == *" --dry-run "* ]]; then
    printf '{"would_embed":%s,"embedded":0,"dryRun":true}\n' "${GBRAIN_STUB_WOULD:-10}"
    exit 0
  fi
  printf '{"embedded":%s,"would_embed":0,"failures":0}\n' "${GBRAIN_STUB_EMBEDDED:-10}"
  exit 0
fi
if [[ "${1:-}" == "check-update" ]]; then
  printf '%s\n' '{"update_available":false}'
  exit 0
fi
exit 0
EOF
chmod 755 "$GBRAIN_BIN"

BRAIN_OS="$TMP/brain-os"
STATE_DIR="$BRAIN_OS/state"
mkdir -p "$STATE_DIR" "$BRAIN_OS/logs"
WIKI_HOME="$TMP/wiki-home"
WIKI_PGLITE="$WIKI_HOME/wiki.pglite"
INGEST_HOME="$TMP/ingest-home"
INGEST_PGLITE="$INGEST_HOME/ingest.pglite"
VAULT_PATH="$TMP/vault"
WIKI_CHECKOUT="$TMP/wiki-checkout"
SG_ENV="$TMP/sg.env"
printf 'ZHIPUAI_API_KEY=smoke-zhipu-not-real\nVOYAGE_API_KEY=smoke-voyage-not-real\n' > "$SG_ENV"
chmod 600 "$SG_ENV"
python3 - "$WIKI_HOME/config.json" "$WIKI_PGLITE" "$INGEST_HOME/config.json" "$INGEST_PGLITE" <<'PY'
import json, os, sys
for cfg, data in ((sys.argv[1], sys.argv[2]), (sys.argv[3], sys.argv[4])):
    os.makedirs(data, exist_ok=True)
    os.makedirs(os.path.dirname(cfg), exist_ok=True)
    json.dump({"engine": "pglite", "database_path": data}, open(cfg, "w"))
PY

common_env() {
  env HOME="$HOME" BOX_ENV_FILE="$TMP/no-box-env" BOX_OPS_SMOKE=1 \
    GBRAIN_BIN="$GBRAIN_BIN" GBRAIN_STUB_LOG="$GBRAIN_STUB_LOG" \
    RESTART_SERVES="$RESTART_SERVES" GBRAIN_SERVE_PORT=18792 \
    WIKI_HOME="$WIKI_HOME" WIKI_PGLITE="$WIKI_PGLITE" \
    INGEST_HOME="$INGEST_HOME" INGEST_PGLITE="$INGEST_PGLITE" \
    VAULT_PATH="$VAULT_PATH" WIKI_CHECKOUT="$WIKI_CHECKOUT" \
    STATE_DIR="$STATE_DIR" BRAIN_OS="$BRAIN_OS" \
    LOCK_FILE="$STATE_DIR/brain-ops.lock" \
    DB_LOCK_FILE="$STATE_DIR/brain-ops-db.lock" \
    SG_ENV="$SG_ENV" \
    "$@"
}

# --- serve gap watchdog ---
: > "$TMP/restart.log"
set +e
common_env SERVE_GAP_MAX_SECONDS=1 timeout 10 bash -c '
  set -euo pipefail
  source "$1"
  box_ops_load
  box_ops_serve_guard_on
  box_ops_serve_stop_begin limited 0
  box_ops_run_bounded sleep 30
  box_ops_serve_stop_end
' bash "$OPS/lib/box-ops-common.sh" >"$TMP/gap.out" 2>"$TMP/gap.err"
set -e
if grep -q SERVE_GAP_EXCEEDED "$TMP/gap.err" && grep -q start "$TMP/restart.log"; then
  printf 'ok serve gap kills and restarts\n'
else
  echo "FAIL serve gap watchdog" >&2
  cat "$TMP/gap.err" >&2
  fail=1
fi

# --- loop trap restarts when a stamp is left behind ---
: > "$TMP/restart.log"
common_env "$BIN/loop-entry.sh" bash -c 'printf "%s\n" "$$" > "$STATE_DIR/serve-stopped-pid"' \
  >"$TMP/loop.out" 2>"$TMP/loop.err"
grep -q 'long lock acquired' "$TMP/loop.err"
if grep -q 'db lock acquired' "$TMP/loop.err"; then
  echo "FAIL loop took the db lock" >&2
  fail=1
else
  grep -q start "$TMP/restart.log"
  printf 'ok loop holds the long lock and restarts serve from a leftover stamp\n'
fi

# --- hygiene / doctor status ---
: > "$GBRAIN_STUB_LOG"
: > "$TMP/restart.log"
if ! common_env GBRAIN_STUB_DOCTOR='{"status":"warnings","health_score":70}' \
  "$BIN/gbrain-daily-hygiene.sh" >"$TMP/hy.out" 2>"$TMP/hy.err"; then
  echo "FAIL hygiene warnings path" >&2
  cat "$TMP/hy.err" >&2
  fail=1
else
  day=$(date +%F)
  test -s "$STATE_DIR/logs/$day/doctor.json"
  grep -q '"status": "warnings"' "$STATE_DIR/logs/$day/doctor.json" || grep -q '"status":"warnings"' "$STATE_DIR/logs/$day/doctor.json"
  read -r word rest < "$STATE_DIR/health.status"
  [[ "$word" == "warn" && -n "$rest" ]]
  grep -q 'db lock acquired' "$TMP/hy.err"
  if grep -q 'long lock acquired' "$TMP/hy.err"; then
    echo "FAIL hygiene took the long lock" >&2
    fail=1
  fi
  if grep -q 'upgrade' "$GBRAIN_STUB_LOG"; then
    echo "FAIL hygiene ran upgrade" >&2
    fail=1
  fi
  grep -q start "$TMP/restart.log"
  printf 'ok doctor archive and warn status\n'
fi

# --- embed ---
: > "$GBRAIN_STUB_LOG"
: > "$TMP/restart.log"
if ! common_env EMBED_CONSENT=yes EMBED_CAP=200 SERVE_GAP_MAX_SECONDS=1200 \
  "$BIN/gbrain-embed-stale.sh" >"$TMP/em.out" 2>"$TMP/em.err"; then
  echo "FAIL embed happy path" >&2
  cat "$TMP/em.err" >&2
  fail=1
else
  grep -q 'budget_ms=1140000' "$TMP/em.err"
  grep -q 'db lock acquired' "$TMP/em.err"
  if grep -q 'long lock acquired' "$TMP/em.err"; then
    echo "FAIL embed took the long lock" >&2
    fail=1
  fi
  if grep -q -- '--all' "$GBRAIN_STUB_LOG" || grep -q -- '--catch-up' "$GBRAIN_STUB_LOG"; then
    echo "FAIL embed passed --all or --catch-up" >&2
    cat "$GBRAIN_STUB_LOG" >&2
    fail=1
  fi
  grep -- '--stale' "$GBRAIN_STUB_LOG" | grep -q -- '--batch-size'
  grep -- '--yes' "$GBRAIN_STUB_LOG" | grep -q -- '--stale'
  if grep -E -q 'smoke-voyage-not-real|smoke-zhipu-not-real' "$TMP/em.err" "$GBRAIN_STUB_LOG"; then
    echo "FAIL embed leaked a key" >&2
    fail=1
  fi
  grep -q start "$TMP/restart.log"
  printf 'ok embed stale cap argv\n'
fi

: > "$GBRAIN_STUB_LOG"
: > "$TMP/restart.log"
if common_env EMBED_CAP=200 "$BIN/gbrain-embed-stale.sh" >"$TMP/em2.out" 2>"$TMP/em2.err"; then
  echo "FAIL embed without consent should exit 3" >&2
  fail=1
else
  grep -q EMBED_CONSENT_REQUIRED "$TMP/em2.err"
  [[ ! -s "$GBRAIN_STUB_LOG" ]]
  if [[ -s "$TMP/restart.log" ]]; then
    echo "FAIL embed consent refusal stopped serve" >&2
    fail=1
  fi
  printf 'ok embed refuses without consent\n'
fi

: > "$GBRAIN_STUB_LOG"
: > "$TMP/restart.log"
if common_env EMBED_CONSENT=yes EMBED_CAP=200 GBRAIN_STUB_WOULD=500 GBRAIN_STUB_EMBEDDED=500 \
  "$BIN/gbrain-embed-stale.sh" >"$TMP/em3.out" 2>"$TMP/em3.err"; then
  echo "FAIL over-cap embed should exit 4" >&2
  fail=1
else
  grep -q EMBED_OVER_CAP "$TMP/em3.err"
  grep -q start "$TMP/restart.log"
  if grep -q -- '--all' "$GBRAIN_STUB_LOG"; then
    echo "FAIL over-cap used --all" >&2
    fail=1
  fi
  printf 'ok embed over-cap exits 4 and restarts serve\n'
fi

if common_env EMBED_CONSENT=yes "$BIN/gbrain-embed-stale.sh" --all >"$TMP/em4.out" 2>"$TMP/em4.err"; then
  echo "FAIL --all should be refused" >&2
  fail=1
else
  grep -q REFUSED "$TMP/em4.err"
  printf 'ok embed refuses --all\n'
fi

# --- hot packs ---
if ! common_env VAULT_PATH="$TMP/missing-vault" "$BIN/gbrain-hot-pack-rebuild.sh" >"$TMP/hp0.out" 2>"$TMP/hp0.err"; then
  echo "FAIL missing vault should skip" >&2
  fail=1
else
  grep -q HOT_PACK_SKIP "$TMP/hp0.err"
  printf 'ok hot pack skips a missing vault\n'
fi
mkdir -p "$VAULT_PATH/crm" "$WIKI_CHECKOUT/projects"
printf '%s\n' '---' 'title: Acme Example' 'slug: client-acme-example' '---' 'A client hub.' > "$VAULT_PATH/crm/client-acme-example.md"
printf '%s\n' '---' 'title: Widget Project' 'slug: project-widget-example' '---' 'A project hub.' > "$WIKI_CHECKOUT/projects/project-widget-example.md"
if ! common_env "$BIN/gbrain-hot-pack-rebuild.sh" >"$TMP/hp1.out" 2>"$TMP/hp1.err"; then
  echo "FAIL unapproved hot pack should hold" >&2
  cat "$TMP/hp1.err" >&2
  fail=1
else
  grep -q HOT_PACK_HOLD "$TMP/hp1.err"
  printf 'ok hot pack holds without approval\n'
fi
cat > "$STATE_DIR/hot-pack-approve.json" <<'EOF'
{"rebuild": true}
EOF
printf '%s\n' '{"ok": false}' > "$STATE_DIR/multi-source-preview-latest.json"
common_env HOT_PACK_OUT="$TMP/packs/accounts.slim.json" \
  "$BIN/gbrain-hot-pack-rebuild.sh" >"$TMP/hp2.out" 2>"$TMP/hp2.err"
grep -q HOT_PACK_HOLD "$TMP/hp2.err"
printf '%s\n' '{"ok": true, "wiki_source": "default"}' > "$STATE_DIR/multi-source-preview-latest.json"
if ! common_env HOT_PACK_OUT="$TMP/packs/accounts.slim.json" \
  "$BIN/gbrain-hot-pack-rebuild.sh" >"$TMP/hp3.out" 2>"$TMP/hp3.err"; then
  echo "FAIL hot pack rebuild" >&2
  cat "$TMP/hp3.err" >&2
  fail=1
else
  python3 - "$TMP/packs/accounts.slim.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
slugs = {row["slug"] for row in doc["accounts"]} | {row["slug"] for row in doc["projects"]}
assert "client-acme-example" in slugs, slugs
assert "project-widget-example" in slugs, slugs
PY
  printf 'ok hot pack writes new hub slugs\n'
fi

# --- hub align ---
mkdir -p "$VAULT_PATH/projects" "$WIKI_CHECKOUT/crm"
printf '%s\n' 'checkout copy' > "$WIKI_CHECKOUT/crm/client-acme-example.md"
printf '%s\n' 'vault copy' > "$VAULT_PATH/crm/client-acme-example.md"
if ! common_env "$BIN/hub-diff.sh" --strict >"$TMP/diff.out" 2>"$TMP/diff.err"; then
  grep -q 'differ crm/client-acme-example.md' "$TMP/diff.out"
  printf 'ok hub diff strict\n'
else
  echo "FAIL hub diff strict should exit 1" >&2
  fail=1
fi
common_env "$BIN/hub-mirror-checkout-to-vault.sh" >"$TMP/mir.out" 2>"$TMP/mir.err"
grep -q would-copy "$TMP/mir.err"
if grep -q 'checkout copy' "$VAULT_PATH/crm/client-acme-example.md"; then
  echo "FAIL dry-run mirror wrote the vault" >&2
  fail=1
else
  printf 'ok hub mirror dry-run\n'
fi
printf '%s\n' 'manifest' > "$WIKI_CHECKOUT/crm/writer_manifest"
if common_env "$BIN/hub-mirror-checkout-to-vault.sh" --apply >"$TMP/mir2.out" 2>"$TMP/mir2.err"; then
  echo "FAIL mirror should refuse writer_manifest" >&2
  fail=1
fi
grep -q 'checkout copy' "$VAULT_PATH/crm/client-acme-example.md"
if [[ -e "$VAULT_PATH/crm/writer_manifest" ]]; then
  echo "FAIL writer_manifest was copied onto the vault" >&2
  fail=1
else
  printf 'ok hub mirror apply skips writer_manifest\n'
fi
if common_env "$BIN/writer-manifest-transfer.sh" >"$TMP/wm.out" 2>"$TMP/wm.err"; then
  echo "FAIL manifest transfer should refuse" >&2
  fail=1
else
  grep -q REFUSED "$TMP/wm.err"
  printf 'ok writer_manifest transfer refuses by default\n'
fi
if common_env WRITER_MANIFEST_TRANSFER=yes \
  "$BIN/writer-manifest-transfer.sh" --apply --src "$WIKI_CHECKOUT/crm/writer_manifest" \
  --dest "$VAULT_PATH/crm/writer_manifest" >"$TMP/wm2.out" 2>"$TMP/wm2.err"; then
  echo "FAIL vault dest should refuse without --allow-vault" >&2
  fail=1
else
  [[ ! -e "$VAULT_PATH/crm/writer_manifest" ]]
  printf 'ok writer_manifest transfer refuses the vault\n'
fi
common_env WRITER_MANIFEST_TRANSFER=yes \
  "$BIN/writer-manifest-transfer.sh" --apply --allow-vault \
  --src "$WIKI_CHECKOUT/crm/writer_manifest" \
  --dest "$TMP/side/writer_manifest" >"$TMP/wm3.out" 2>"$TMP/wm3.err"
test -s "$TMP/side/writer_manifest"
printf 'ok writer_manifest transfer outside the vault\n'

# --- ingest tail (2026-10-04) ---
: > "$GBRAIN_STUB_LOG"
common_env "$BIN/ingest-finish-tail.sh" --check >"$TMP/in0.out" 2>"$TMP/in0.err"
grep -q INGEST_TAIL_CLEAR "$TMP/in0.err"
printf 'ok ingest tail clear\n'
cp "$OPS/state/ingest-tail.example.json" "$STATE_DIR/ingest-tail.json"
if common_env "$BIN/ingest-finish-tail.sh" --check >"$TMP/in1.out" 2>"$TMP/in1.err"; then
  echo "FAIL stuck tail check should exit 1" >&2
  fail=1
else
  grep -q '2026-10-04' "$TMP/in1.err"
  [[ ! -s "$GBRAIN_STUB_LOG" ]]
  printf 'ok ingest tail check reports the stuck case\n'
fi
if common_env "$BIN/ingest-finish-tail.sh" >"$TMP/in2.out" 2>"$TMP/in2.err"; then
  echo "FAIL ask mode should exit 3" >&2
  fail=1
else
  [[ ! -s "$GBRAIN_STUB_LOG" ]]
  printf 'ok ingest tail ask mode does not sync\n'
fi
: > "$GBRAIN_STUB_LOG"
if ! common_env "$BIN/ingest-finish-tail.sh" --apply --links >"$TMP/in3.out" 2>"$TMP/in3.err"; then
  echo "FAIL ingest apply" >&2
  cat "$TMP/in3.err" >&2
  fail=1
else
  grep 'sync' "$GBRAIN_STUB_LOG" | grep -q -- '--no-embed'
  grep 'extract' "$GBRAIN_STUB_LOG" | grep -q 'links'
  if grep -q ':: embed' "$GBRAIN_STUB_LOG" || grep -q ' embed ' "$GBRAIN_STUB_LOG"; then
    echo "FAIL ingest tail called embed" >&2
    cat "$GBRAIN_STUB_LOG" >&2
    fail=1
  fi
  grep 'sync' "$GBRAIN_STUB_LOG" | grep -q "home=$INGEST_HOME"
  printf 'ok ingest tail apply syncs without embeddings\n'
fi

# --- page split plan ---
wiki="$TMP/notion-wiki"
mkdir -p "$wiki"
printf 'small\n' > "$wiki/small.md"
dd if=/dev/zero bs=1000 count=130 status=none | tr '\0' 'a' > "$wiki/big.md"
before=$(sha256sum "$wiki/big.md" | awk '{print $1}')
common_env NOTION_WIKI_PATH="$wiki" PAGE_SPLIT_BYTES=120000 \
  "$BIN/notion-page-split-plan.sh" >"$TMP/split.out" 2>"$TMP/split.err"
grep -q 'oversize big.md' "$TMP/split.out"
if grep -q 'small.md' "$TMP/split.out"; then
  echo "FAIL small page was listed" >&2
  fail=1
fi
after=$(sha256sum "$wiki/big.md" | awk '{print $1}')
[[ "$before" == "$after" ]]
printf 'ok page split plan is read-only\n'

# --- legacy marker + version ---
if ! common_env "$BIN/legacy-marker-scan.sh" "$OPS/scripts" "$OPS/lib" >"$TMP/leg.out" 2>"$TMP/leg.err"; then
  echo "FAIL package still has the retired marker" >&2
  cat "$TMP/leg.err" >&2
  fail=1
else
  printf 'ok package scripts have no retired marker\n'
fi
printf '%s\n' 'gbrain dream --source yh-brain' > "$TMP/old.sh"
if common_env "$BIN/legacy-marker-scan.sh" "$TMP/old.sh" >"$TMP/leg2.out" 2>"$TMP/leg2.err"; then
  echo "FAIL scanner should catch the retired marker" >&2
  fail=1
else
  grep -q LEGACY_MARKER "$TMP/leg2.err"
  printf 'ok legacy scanner flags a live copy\n'
fi
: > "$GBRAIN_STUB_LOG"
if ! common_env "$BIN/gbrain-version-check.sh" >"$TMP/ver.out" 2>"$TMP/ver.err"; then
  echo "FAIL version check" >&2
  cat "$TMP/ver.err" >&2
  fail=1
else
  grep -q VERSION_BEHIND "$STATE_DIR/version-check.txt"
  grep -q 'manual: gbrain upgrade' "$STATE_DIR/version-check.txt"
  if grep -q upgrade "$GBRAIN_STUB_LOG"; then
    echo "FAIL version check invoked upgrade" >&2
    cat "$GBRAIN_STUB_LOG" >&2
    fail=1
  fi
  printf 'ok version check does not upgrade\n'
fi
: > "$GBRAIN_STUB_LOG"
common_env GBRAIN_STUB_VERSION=0.60.82.0 "$BIN/gbrain-version-check.sh" >"$TMP/ver2.out" 2>"$TMP/ver2.err"
grep -q VERSION_OK "$STATE_DIR/version-check.txt"
printf 'ok version check accepts 0.60.82\n'

# --- eval fixture ---
python3 - "$OPS/evals/queries.jsonl" "$OPS/evals/qrels.stub.json" <<'PY'
import json, sys
lines = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
assert len(lines) == 20, len(lines)
for row in lines:
    assert row.get("stub") is True
    assert row.get("query")
    assert row.get("relevant") == []
qrels = json.load(open(sys.argv[2]))
assert qrels["status"] == "stub"
assert len(qrels["queries"]) == 20
assert all(q["relevant_slugs"] == [] for q in qrels["queries"])
PY
grep -q 'retrieval-quality' "$OPS/evals/README.md"
printf 'ok eval fixture has 20 stub asks\n'

if [[ "$fail" != "0" ]]; then
  echo "phase 2 smoke failed" >&2
  exit 1
fi
echo "phase 2 smoke passed"

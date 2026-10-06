#!/usr/bin/env bash
# Shared helpers for the YH brain-box ops scripts.
# Paths default to the Grok Bot box. Override with env or state/box.env.
# No secrets live here.

if [[ -n "${BOX_OPS_COMMON_LOADED:-}" ]]; then
  return 0
fi
BOX_OPS_COMMON_LOADED=1

box_ops_log() {
  printf '%s %s\n' "$(date -Is)" "$*" >&2
}

box_ops_load_env_file() {
  local file="$1" label="$2"
  [[ -f "$file" ]] || return 0
  # Paths and keys only. Do not print the file.
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
  box_ops_log "loaded $label"
}

box_ops_load() {
  local env_file="${BOX_ENV_FILE:-/home/box/brain-os/state/box.env}"
  if [[ -f "$env_file" ]]; then
    box_ops_load_env_file "$env_file" "box.env"
  fi
  : "${BRAIN_OS:=/home/box/brain-os}"
  : "${WIKI_HOME:=/home/box/.gbrain}"
  : "${INGEST_HOME:=/home/box/.gbrain-homes/ingest}"
  : "${WIKI_PGLITE:=$WIKI_HOME/wiki.pglite}"
  : "${INGEST_PGLITE:=$INGEST_HOME/ingest.pglite}"
  : "${WIKI_CHECKOUT:=$WIKI_HOME/wiki-default-checkout}"
  : "${VAULT_PATH:=$BRAIN_OS/vault}"
  : "${NOTION_SNAPSHOT_PATH:=$VAULT_PATH/notion-snapshot}"
  : "${NOTION_MEETINGS_PATH:=$VAULT_PATH/notion-meetings}"
  : "${AGENTMAIL_PATH:=$VAULT_PATH/agentmail}"
  : "${STATE_DIR:=$BRAIN_OS/state}"
  : "${LOG_DIR:=$BRAIN_OS/logs}"
  # Long lock: dream and Loop. Does not by itself stop serve.
  : "${LOCK_FILE:=$STATE_DIR/brain-ops.lock}"
  # Short lock: the single PGLite writer / serve-stop window.
  : "${DB_LOCK_FILE:=$STATE_DIR/brain-ops-db.lock}"
  : "${SERVE_GAP_MAX_SECONDS:=1200}"
  : "${EMBED_CAP:=200}"
  : "${HOT_PACK_OUT:=/home/box/codex-harness/g2-sync/hot-packs/accounts.slim.json}"
  : "${HOT_PACK_APPROVAL:=$STATE_DIR/hot-pack-approve.json}"
  : "${TARGET_GBRAIN_VERSION:=0.60.82}"
  : "${BACKUP_DIR:=$BRAIN_OS/backups/wiki}"
  : "${GBRAIN_SERVE_PORT:=18792}"
  : "${RESTART_SERVES:=$BRAIN_OS/bin/gbrain-restart-serves.sh}"
  : "${SG_ENV:=${HOME:-/home/box}/.gbrain/sg.env}"
  : "${APPROVAL_FILE:=$STATE_DIR/multi-source-approve.json}"
  : "${BRAIN_ID:=host}"
  : "${HUB_GLOBS:=crm/client-*.md,crm/project-*.md,projects/*.md,clients/*.md}"
  mkdir -p "$STATE_DIR" "$LOG_DIR"
}

box_ops_load_sg_env() {
  box_ops_load
  if [[ ! -f "$SG_ENV" ]]; then
    box_ops_log "WARN: $SG_ENV is missing; dream LLM phases will not see ZHIPUAI_API_KEY"
    return 0
  fi
  local mode
  mode=$(stat -c '%a' "$SG_ENV" 2>/dev/null || stat -f '%OLp' "$SG_ENV")
  case "$mode" in
    600|400) ;;
    *) box_ops_log "WARN: $SG_ENV mode is $mode; chmod 600 (value not printed)" ;;
  esac
  box_ops_load_env_file "$SG_ENV" "sg.env"
  if [[ -z "${ZHIPUAI_API_KEY:-}" ]]; then
    box_ops_log "WARN: ZHIPUAI_API_KEY is unset after sourcing sg.env"
  else
    box_ops_log "sg.env has ZHIPUAI_API_KEY (value not printed)"
  fi
  # Embeddings on this box stay on Voyage. Zhipu is for facts and chat.
  if [[ -z "${VOYAGE_API_KEY:-}" ]]; then
    box_ops_log "WARN: VOYAGE_API_KEY is unset after sourcing sg.env (embeddings stay on Voyage)"
  else
    box_ops_log "sg.env has VOYAGE_API_KEY (value not printed)"
  fi
}

# A hosted URL in the environment forces the postgres engine and hides PGLite.
box_ops_clear_hosted_db_env() {
  if [[ -n "${GBRAIN_DATABASE_URL:-}${DATABASE_URL:-}" ]]; then
    box_ops_log "cleared hosted database URL env so this process stays on local PGLite"
  fi
  unset GBRAIN_DATABASE_URL
  unset DATABASE_URL
}

box_ops_preflight_pglite() {
  local home="$1" expect="$2"
  local cfg="$home/config.json"
  if [[ ! -f "$cfg" ]]; then
    box_ops_log "PREFLIGHT_FAIL: missing $cfg"
    return 2
  fi
  python3 - "$cfg" "$expect" <<'PY'
import json, os, sys
cfg, expect = sys.argv[1], sys.argv[2]
with open(cfg) as handle:
    config = json.load(handle)
url = str(config.get("database_url") or "")
engine = config.get("engine")
path = str(config.get("database_path") or "")
low = url.lower()
if url.strip():
    sys.stderr.write("PREFLIGHT_FAIL: config.json database_url is set; this host is local PGLite\n")
    sys.exit(2)
if "supabase" in low or "mumbai" in low:
    sys.stderr.write("PREFLIGHT_FAIL: retired hosted database target\n")
    sys.exit(2)
if engine != "pglite":
    sys.stderr.write("PREFLIGHT_FAIL: engine=%r expected pglite\n" % (engine,))
    sys.exit(2)
if path and os.path.abspath(path) != os.path.abspath(expect):
    sys.stderr.write("PREFLIGHT_FAIL: database_path %s != %s\n" % (path, expect))
    sys.exit(2)
if not os.path.isdir(expect):
    sys.stderr.write("PREFLIGHT_FAIL: PGLite directory missing: %s\n" % expect)
    sys.exit(2)
print("ok")
PY
}

box_ops_gbrain_bin() {
  if [[ -n "${GBRAIN_BIN:-}" ]]; then
    printf '%s\n' "$GBRAIN_BIN"
  else
    command -v gbrain
  fi
}

box_ops_gbrain() {
  "$(box_ops_gbrain_bin)" "$@"
}

# Like box_ops_gbrain, but a limited serve-stop window kills the CLI
# process at SERVE_GAP_MAX_SECONDS. Dream leaves the mode unlimited.
box_ops_gbrain_bounded() {
  if [[ "${BOX_OPS_SERVE_MODE:-limited}" == "unlimited" ]]; then
    box_ops_gbrain "$@"
    return $?
  fi
  box_ops_run_bounded "$(box_ops_gbrain_bin)" "$@"
}

box_ops_reject_retired_url() {
  local url="$1" label="$2"
  local low
  low=$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')
  case "$low" in
    *supabase*|*mumbai*)
      box_ops_log "REFUSED $label: retired hosted target"
      return 1
      ;;
    *garrytan/gbrain*)
      box_ops_log "REFUSED $label: this script does not push the gbrain repository"
      return 1
      ;;
  esac
  return 0
}

box_ops_remote_allowed() {
  local url="$1"
  box_ops_reject_retired_url "$url" "remote" || return 1
  case "$url" in
    *Tashikoma-Claw/YH-Brain|*Tashikoma-Claw/YH-Brain.git|\
    *Tashikoma-Claw/YH-Brain-wiki|*Tashikoma-Claw/YH-Brain-wiki.git)
      return 0
      ;;
  esac
  if [[ "${BACKUP_ALLOW_LOCAL_REMOTE:-}" == "1" ]]; then
    case "$url" in
      /*|file:*) return 0 ;;
    esac
  fi
  box_ops_log "REFUSED remote $url (expected a private Tashikoma-Claw/YH-Brain or YH-Brain-wiki URL)"
  return 1
}

box_ops_lock_prepare() {
  box_ops_load
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>>"$LOCK_FILE"
}

box_ops_lock_db_prepare() {
  box_ops_load
  mkdir -p "$(dirname "$DB_LOCK_FILE")"
  exec 8>>"$DB_LOCK_FILE"
}

box_ops_lock_nowait() {
  box_ops_lock_prepare
  if ! flock -n 9; then
    box_ops_log "lock held: $LOCK_FILE"
    return 1
  fi
  box_ops_log "long lock acquired: $LOCK_FILE"
}

box_ops_lock_wait() {
  local seconds="${1:-5400}"
  box_ops_lock_prepare
  box_ops_log "long lock wait ${seconds}s: $LOCK_FILE"
  if ! flock -w "$seconds" 9; then
    box_ops_log "lock timeout: $LOCK_FILE"
    return 1
  fi
  box_ops_log "long lock acquired: $LOCK_FILE"
}

box_ops_lock_db_wait() {
  local seconds="${1:-1200}"
  box_ops_lock_db_prepare
  box_ops_log "db lock wait ${seconds}s: $DB_LOCK_FILE"
  if ! flock -w "$seconds" 8; then
    box_ops_log "db lock timeout: $DB_LOCK_FILE"
    return 1
  fi
  box_ops_log "db lock acquired: $DB_LOCK_FILE mode=${BOX_OPS_SERVE_MODE:-limited}"
}

# Limited serve-stop windows clamp to 20 minutes. Dream passes unlimited.
box_ops_serve_gap_max() {
  local max="${SERVE_GAP_MAX_SECONDS:-1200}"
  if [[ "$max" -gt 1200 && "${SERVE_GAP_OVERRIDE:-}" != "1" ]]; then
    box_ops_log "SERVE_GAP clamped from ${max}s to 1200s"
    max=1200
  fi
  printf '%s\n' "$max"
}

box_ops_serve_restart_if_needed() {
  box_ops_load
  local rc=0
  if [[ "${serve_stopped:-0}" == "1" && "${serve_restarted:-0}" == "0" ]]; then
    serve_restarted=1
    rm -f "$STATE_DIR/serve-stopped-pid" "$STATE_DIR/serve-stopped-at"
    box_ops_start_wiki_serve || rc=1
  elif [[ -f "$STATE_DIR/serve-stopped-pid" ]]; then
    box_ops_log "serve stamp left behind; restarting :${GBRAIN_SERVE_PORT}"
    rm -f "$STATE_DIR/serve-stopped-pid" "$STATE_DIR/serve-stopped-at"
    box_ops_start_wiki_serve || rc=1
  fi
  return "$rc"
}

box_ops_serve_guard_exit() {
  local rc=$?
  trap - EXIT INT TERM
  box_ops_serve_restart_if_needed || rc=1
  if [[ -n "${BOX_OPS_EXIT_HOOK:-}" ]] && declare -F "$BOX_OPS_EXIT_HOOK" >/dev/null 2>&1; then
    "$BOX_OPS_EXIT_HOOK" "$rc" || true
  fi
  exit "$rc"
}

box_ops_serve_guard_on() {
  trap box_ops_serve_guard_exit EXIT INT TERM
}

# mode is "limited" (default, ≤20 min) or "unlimited" (dream window only).
box_ops_serve_stop_begin() {
  local mode="${1:-limited}"
  local wait_s="${2:-${DB_LOCK_WAIT_SECONDS:-1200}}"
  box_ops_load
  BOX_OPS_SERVE_MODE="$mode"
  if ! box_ops_lock_db_wait "$wait_s"; then
    return 1
  fi
  if ! box_ops_stop_wiki_serve; then
    return 1
  fi
  serve_stopped=1
  serve_restarted=0
  date +%s > "$STATE_DIR/serve-stopped-at"
  printf '%s\n' "$$" > "$STATE_DIR/serve-stopped-pid"
  box_ops_log "serve stopped mode=$mode lock=$DB_LOCK_FILE"
}

# Run a command inside a limited serve-stop window. `timeout` kills that
# command, not the shell: a trapped shell does not notice TERM until its
# foreground child exits. Unlimited (dream) runs the command as-is.
box_ops_run_bounded() {
  local max rc
  if [[ "${BOX_OPS_SERVE_MODE:-limited}" == "unlimited" ]]; then
    "$@"
    return $?
  fi
  max=$(box_ops_serve_gap_max)
  if ! command -v timeout >/dev/null 2>&1; then
    box_ops_log "WARN: timeout(1) missing; the ${max}s serve gap is not enforced on this command"
    "$@"
    return $?
  fi
  set +e
  timeout --signal=TERM "$max" "$@"
  rc=$?
  set -e
  if [[ "$rc" == "124" ]]; then
    box_ops_log "SERVE_GAP_EXCEEDED command timed out after ${max}s"
  fi
  return "$rc"
}

box_ops_serve_stop_end() {
  local rc=0
  local mode="${BOX_OPS_SERVE_MODE:-limited}"
  if [[ "$mode" != "unlimited" && -f "${STATE_DIR:-}/serve-stopped-at" ]]; then
    local start now max elapsed
    start=$(cat "$STATE_DIR/serve-stopped-at")
    now=$(date +%s)
    max=$(box_ops_serve_gap_max)
    elapsed=$((now - start))
    if [[ "$elapsed" -gt "$max" ]]; then
      box_ops_log "SERVE_GAP_EXCEEDED elapsed=${elapsed}s max=${max}s"
      rc=1
    fi
  fi
  box_ops_serve_restart_if_needed || rc=1
  rm -f "${STATE_DIR:-}/serve-stopped-pid" "${STATE_DIR:-}/serve-stopped-at" || true
  return "$rc"
}

# Embed argv for the hourly stale pass. Never --all, never --catch-up.
box_ops_embed_stale_args() {
  local cap="${EMBED_CAP:-200}"
  if [[ ! "$cap" =~ ^[0-9]+$ ]] || [[ "$cap" -lt 1 ]]; then
    box_ops_log "REFUSED EMBED_CAP=$cap"
    return 1
  fi
  if [[ "$cap" -gt 200 && "${EMBED_CAP_OVERRIDE:-}" != "1" ]]; then
    box_ops_log "REFUSED EMBED_CAP=$cap above 200 without EMBED_CAP_OVERRIDE=1"
    return 1
  fi
  EMBED_ARGS=(embed --stale --source default --batch-size "$cap" --priority recent --json)
  if [[ -n "${EMBED_MAX_USD:-}" ]]; then
    EMBED_ARGS+=(--max-usd "$EMBED_MAX_USD")
  fi
  if [[ "${EMBED_CONSENT:-}" == "yes" ]]; then
    EMBED_ARGS+=(--yes)
  fi
  local flag
  for flag in "${EMBED_ARGS[@]}"; do
    if [[ "$flag" == "--all" || "$flag" == "--catch-up" ]]; then
      box_ops_log "REFUSED embed flag $flag"
      return 1
    fi
  done
}

box_ops_serve_pids() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -ltnp "sport = :${GBRAIN_SERVE_PORT}" 2>/dev/null \
    | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' \
    | sort -u
}

box_ops_stop_wiki_serve() {
  box_ops_load
  if [[ "${BOX_OPS_SKIP_SERVE:-}" == "1" ]]; then
    return 0
  fi
  if ! command -v ss >/dev/null 2>&1; then
    if [[ "${BOX_OPS_SMOKE:-}" == "1" ]]; then
      return 0
    fi
    box_ops_log "PREFLIGHT_FAIL: ss is required to see the listener on :${GBRAIN_SERVE_PORT}"
    return 1
  fi
  local pid cmd
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    case "$cmd" in
      *gbrain*serve*)
        box_ops_log "stopping wiki serve pid=$pid on :${GBRAIN_SERVE_PORT}"
        kill -TERM "$pid" || true
        ;;
      *)
        box_ops_log "REFUSED to stop pid=$pid; it is not gbrain serve"
        return 1
        ;;
    esac
  done < <(box_ops_serve_pids)
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [[ -z "$(box_ops_serve_pids)" ]]; then
      return 0
    fi
    sleep 0.5
  done
  box_ops_log "wiki serve still listening on :${GBRAIN_SERVE_PORT}"
  return 1
}

box_ops_start_wiki_serve() {
  box_ops_load
  if [[ "${BOX_OPS_SKIP_SERVE:-}" == "1" ]]; then
    return 0
  fi
  if [[ -x "$RESTART_SERVES" ]]; then
    box_ops_log "starting serve via $RESTART_SERVES"
    "$RESTART_SERVES"
    return $?
  fi
  box_ops_log "SERVE_RESTART_MISSING: $RESTART_SERVES is the box owner of :${GBRAIN_SERVE_PORT}. This package does not replace it."
  return 1
}

box_ops_git_root() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

box_ops_plan_mode() {
  # Prints connect, add, or hold. profile_ambiguous is the expected
  # company-profile miss for a general markdown repo; other errors hold.
  python3 - "$1" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
plan = raw.get("plan") if isinstance(raw, dict) and "ready" not in raw and "plan" in raw else raw
errors = []
for item in plan.get("findings") or []:
    if item.get("severity") == "error" and item.get("code"):
        errors.append(item["code"])
if plan.get("ready") is True:
    print("connect")
elif errors and set(errors) <= {"profile_ambiguous"}:
    print("add")
else:
    sys.stderr.write("hold findings: %s\n" % ",".join(errors or ["not_ready"]))
    print("hold")
PY
}

box_ops_approval_allows() {
  local source_id="$1"
  [[ -f "$APPROVAL_FILE" ]] || return 1
  python3 - "$APPROVAL_FILE" "$source_id" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("wiki_import") is True:
    sys.stderr.write("REFUSED wiki_import: raw trees stay on the ingest brain\n")
    sys.exit(2)
allowed = doc.get("ingest_raw") is True and sys.argv[2] in (doc.get("source_ids") or [])
sys.exit(0 if allowed else 1)
PY
}

# 0 registered, 1 absent, 2 list command failed.
box_ops_source_registered() {
  local source_id="$1"
  local json
  if ! json=$(box_ops_gbrain sources list --json); then
    return 2
  fi
  python3 -c 'import json,sys; doc=json.loads(sys.argv[1]); ids=[s.get("id") for s in doc.get("sources") or []]; sys.exit(0 if sys.argv[2] in ids else 1)' "$json" "$source_id"
}

box_ops_ff_push() {
  local repo="$1" label="$2"
  if [[ ! -d "$repo/.git" && ! -f "$repo/.git" ]]; then
    box_ops_log "SKIP $label: not a git checkout ($repo)"
    return 1
  fi
  local url branch head remote dirty
  url=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  if [[ -z "$url" ]]; then
    box_ops_log "SKIP $label: no origin. Add a private remote first (APPLY.md)."
    return 1
  fi
  box_ops_remote_allowed "$url" || return 1
  branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  if [[ "$branch" == "HEAD" ]]; then
    box_ops_log "REFUSED $label: detached HEAD"
    return 1
  fi
  dirty=$(git -C "$repo" status --porcelain | wc -l | tr -d ' ')
  box_ops_log "$label dirty_paths=$dirty (not auto-committed) branch=$branch"
  GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch origin "$branch"
  head=$(git -C "$repo" rev-parse HEAD)
  remote=$(git -C "$repo" rev-parse "origin/$branch")
  if [[ "$head" == "$remote" ]]; then
    box_ops_log "$label already matches origin/$branch ($head)"
    return 0
  fi
  if ! git -C "$repo" merge-base --is-ancestor "$remote" "$head"; then
    box_ops_log "REFUSED $label: origin/$branch is not an ancestor of HEAD. Not force-pushing."
    return 1
  fi
  box_ops_log "$label fast-forward $remote -> $head"
  if git --no-pager push -h 2>&1 | grep -q -- '--ff-only'; then
    GIT_TERMINAL_PROMPT=0 git -C "$repo" push --ff-only origin "HEAD:${branch}"
  else
    GIT_TERMINAL_PROMPT=0 git -C "$repo" push origin "HEAD:${branch}"
  fi
}

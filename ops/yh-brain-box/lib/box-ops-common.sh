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
  : "${LOCK_FILE:=$STATE_DIR/brain-ops.lock}"
  : "${BACKUP_DIR:=$BRAIN_OS/backups/wiki}"
  : "${GBRAIN_SERVE_PORT:=18792}"
  : "${RESTART_SERVES:=$BRAIN_OS/bin/gbrain-restart-serves.sh}"
  : "${SG_ENV:=${HOME:-/home/box}/.gbrain/sg.env}"
  : "${APPROVAL_FILE:=$STATE_DIR/multi-source-approve.json}"
  : "${BRAIN_ID:=host}"
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

box_ops_gbrain() {
  if [[ -n "${GBRAIN_BIN:-}" ]]; then
    "$GBRAIN_BIN" "$@"
  else
    command gbrain "$@"
  fi
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

box_ops_lock_nowait() {
  box_ops_lock_prepare
  if ! flock -n 9; then
    box_ops_log "lock held: $LOCK_FILE"
    return 1
  fi
}

box_ops_lock_wait() {
  local seconds="${1:-5400}"
  box_ops_lock_prepare
  box_ops_log "waiting up to ${seconds}s for $LOCK_FILE"
  if ! flock -w "$seconds" 9; then
    box_ops_log "lock timeout: $LOCK_FILE"
    return 1
  fi
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

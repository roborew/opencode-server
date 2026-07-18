#!/usr/bin/env bash
# Shared helpers for OpenCode server setup (API, env, docker).
set -euo pipefail

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"
CONTAINER_NAME="${OPENCODE_CONTAINER:-opencode-server}"
# Host apps path inside the container (same-path bind). Set after load_env.
WORKSPACE_ROOT="${OPENCODE_WORKSPACE_ROOT:-${OPENCODE_APPS_DIR:-}}"
# Pre-migration container path still present in older project rows
LEGACY_WORKSPACE_ROOT="/workspace/apps"

# Preflight counters (set by preflight.sh)
PREFLIGHT_OK=0
PREFLIGHT_WARN=0
PREFLIGHT_FAIL=0
PREFLIGHT_MCP_NEEDS_AUTH=()

# Map between host OPENCODE_APPS_DIR paths and legacy /workspace/apps registrations.
to_host_workspace_path() {
  local dir="${1%/}"
  if [[ -n "${WORKSPACE_ROOT:-}" && ( "$dir" == "$WORKSPACE_ROOT" || "$dir" == "$WORKSPACE_ROOT"/* ) ]]; then
    echo "$dir"
    return
  fi
  if [[ "$dir" == "$LEGACY_WORKSPACE_ROOT" ]]; then
    echo "${WORKSPACE_ROOT}"
    return
  fi
  if [[ "$dir" == "$LEGACY_WORKSPACE_ROOT"/* ]]; then
    echo "${WORKSPACE_ROOT}/${dir#"${LEGACY_WORKSPACE_ROOT}/"}"
    return
  fi
  echo "$dir"
}

to_legacy_workspace_path() {
  local dir="${1%/}"
  if [[ "$dir" == "$LEGACY_WORKSPACE_ROOT" || "$dir" == "$LEGACY_WORKSPACE_ROOT"/* ]]; then
    echo "$dir"
    return
  fi
  if [[ -n "${WORKSPACE_ROOT:-}" && "$dir" == "$WORKSPACE_ROOT" ]]; then
    echo "$LEGACY_WORKSPACE_ROOT"
    return
  fi
  if [[ -n "${WORKSPACE_ROOT:-}" && "$dir" == "$WORKSPACE_ROOT"/* ]]; then
    echo "${LEGACY_WORKSPACE_ROOT}/${dir#"${WORKSPACE_ROOT}/"}"
    return
  fi
  echo "$dir"
}

load_env() {
  local env_file="${REPO_ROOT}/.env"
  if [[ ! -f "$env_file" ]]; then
    return 1
  fi
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # Strip optional surrounding quotes
      if [[ "$val" =~ ^\"(.*)\"$ ]]; then val="${BASH_REMATCH[1]}"; fi
      if [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
      val="${val//\$HOME/$HOME}"
      export "${key}=${val}"
    fi
  done < "$env_file"
  # Prefer explicit override, else OPENCODE_APPS_DIR from .env / environment
  if [[ -n "${OPENCODE_WORKSPACE_ROOT:-}" ]]; then
    WORKSPACE_ROOT="${OPENCODE_WORKSPACE_ROOT}"
  elif [[ -n "${OPENCODE_APPS_DIR:-}" ]]; then
    WORKSPACE_ROOT="${OPENCODE_APPS_DIR}"
  fi
  export WORKSPACE_ROOT
  return 0
}

opencode_base_url() {
  local host="${OPENCODE_HOST:-}"
  if [[ -z "$host" ]]; then
    local port="${OPENCODE_PUBLISH_PORT:-4097}"
    # Strip host:port binding if present (e.g. 127.0.0.1:4097)
    port="${port##*:}"
    host="http://127.0.0.1:${port}"
  fi
  echo "${host%/}"
}

opencode_auth() {
  local user="${OPENCODE_SERVER_USERNAME:-opencode}"
  local pass="${OPENCODE_SERVER_PASSWORD:-}"
  echo "${user}:${pass}"
}

api_get() {
  local path="$1"
  local base
  base="$(opencode_base_url)"
  curl -sf -u "$(opencode_auth)" "${base}${path}"
}

api_post() {
  local path="$1"
  local body="${2:-{}}"
  local extra_header="${3:-}"
  local base
  base="$(opencode_base_url)"
  if [[ -n "$extra_header" ]]; then
    curl -sf -u "$(opencode_auth)" \
      -H "Content-Type: application/json" \
      -H "$extra_header" \
      -X POST "${base}${path}" \
      -d "$body"
  else
    curl -sf -u "$(opencode_auth)" \
      -H "Content-Type: application/json" \
      -X POST "${base}${path}" \
      -d "$body"
  fi
}

api_delete() {
  local path="$1"
  local extra_header="${2:-}"
  local base
  base="$(opencode_base_url)"
  if [[ -n "$extra_header" ]]; then
    curl -sf -u "$(opencode_auth)" \
      -H "$extra_header" \
      -X DELETE "${base}${path}"
  else
    curl -sf -u "$(opencode_auth)" \
      -X DELETE "${base}${path}"
  fi
}

opencode_public_url() {
  local fqdn="${OPENCODE_FQDN:-opencode.local}"
  local port="${OPENCODE_PUBLISH_PORT:-4097}"
  port="${port##*:}"
  echo "http://${fqdn}:${port}"
}

list_sessions_json() {
  api_get "/session" 2>/dev/null || echo '[]'
}

wait_for_health() {
  local max_attempts="${1:-30}"
  local attempt=0
  while (( attempt < max_attempts )); do
    if api_get "/global/health" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  return 1
}

container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

docker_exec() {
  docker exec "$CONTAINER_NAME" "$@"
}

list_projects_json() {
  api_get "/project" 2>/dev/null || echo '[]'
}

project_registered() {
  local dir="$1"
  local host legacy projects
  host="$(to_host_workspace_path "$dir")"
  legacy="$(to_legacy_workspace_path "$dir")"
  projects="$(list_projects_json)"
  python3 -c "
import json, sys
targets = {sys.argv[1].rstrip('/'), sys.argv[2].rstrip('/')}
data = json.loads(sys.argv[3])
for p in data:
    wt = (p.get('worktree') or p.get('directory') or '').rstrip('/')
    if wt in targets:
        sys.exit(0)
sys.exit(1)
" "$host" "$legacy" "$projects"
}

register_project() {
  local dir="$1"
  local title="${2:-$(basename "$dir")}"
  # Always register at the host same-path (never /workspace/apps)
  dir="$(to_host_workspace_path "$dir")"
  if project_registered "$dir"; then
    echo "skip"
    return 0
  fi
  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"title": sys.argv[1]}))' "$title")"
  api_post "/session" "$body" "X-Opencode-Directory: ${dir}" >/dev/null
  # Drop leftover legacy /workspace/apps sessions for the same repo
  local legacy
  legacy="$(to_legacy_workspace_path "$dir")"
  if [[ "$legacy" != "$dir" ]]; then
    deregister_project "$legacy" >/dev/null 2>&1 || true
  fi
  echo "ok"
}

# List sessions whose directory matches the worktree.
list_sessions_for_directory() {
  local dir="$1"
  local all
  all="$(
    curl -sf -u "$(opencode_auth)" \
      -H "X-Opencode-Directory: ${dir}" \
      "$(opencode_base_url)/session" 2>/dev/null \
      || list_sessions_json
  )"
  python3 -c "
import json, sys
dir_ = sys.argv[1]
data = json.loads(sys.argv[2] or '[]')
out = []
for s in data:
    d = s.get('directory') or ''
    if d == dir_ or d.rstrip('/') == dir_.rstrip('/'):
        out.append(s)
print(json.dumps(out))
" "$dir" "$all"
}

# Remove all sessions for a worktree so it drops out of the active UI set.
# (OpenCode has no project.delete; sessions are the registration mechanism.)
deregister_project() {
  local dir="$1"
  local host legacy path
  host="$(to_host_workspace_path "$dir")"
  legacy="$(to_legacy_workspace_path "$dir")"
  local ok=0 fail=0

  for path in "$host" "$legacy"; do
    [[ -z "$path" ]] && continue
    local sessions ids
    sessions="$(list_sessions_for_directory "$path")"
    ids="$(python3 -c "
import json, sys
for s in json.loads(sys.argv[1] or '[]'):
    sid = s.get('id') or ''
    if sid:
        print(sid)
" "$sessions")"
    if [[ -z "$ids" ]]; then
      continue
    fi
    local id
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      if api_delete "/session/${id}" >/dev/null 2>&1; then
        ok=$((ok + 1))
      elif api_delete "/session/${id}" "X-Opencode-Directory: ${path}" >/dev/null 2>&1; then
        ok=$((ok + 1))
      else
        fail=$((fail + 1))
      fi
    done <<< "$ids"
  done

  if (( fail > 0 )); then
    echo "fail"
    return 1
  fi
  echo "ok"
}

list_registered_workspace_projects() {
  # Print host-path registrations. Legacy /workspace/apps/* rows map to OPENCODE_APPS_DIR.
  list_projects_json | python3 -c "
import json, sys
root = sys.argv[1].rstrip('/')
legacy = sys.argv[2].rstrip('/')
seen = set()
for p in json.load(sys.stdin):
    wt = (p.get('worktree') or '').rstrip('/')
    if not wt:
        continue
    if wt == root or wt.startswith(root + '/'):
        host = wt
    elif wt == legacy or wt.startswith(legacy + '/'):
        host = root + wt[len(legacy):]
    else:
        continue
    if host not in seen:
        seen.add(host)
        print(host)
" "$WORKSPACE_ROOT" "$LEGACY_WORKSPACE_ROOT"
}

list_mcp_json() {
  api_get "/mcp" 2>/dev/null || echo '{}'
}

# After `opencode mcp auth`, tokens are on disk but the long-running serve
# process may still report needs_auth until the MCP transport is reconnected.
mcp_server_reconnect() {
  local name="$1"
  api_post "/mcp/${name}/disconnect" '{}' >/dev/null 2>&1 || true
  api_post "/mcp/${name}/connect" '{}' >/dev/null 2>&1 || true
}

mcp_status_for() {
  local name="$1"
  local mcp_json
  mcp_json="$(list_mcp_json 2>/dev/null || echo '{}')"
  echo "$mcp_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
info = d.get(sys.argv[1], {})
print(info.get('status') or info.get('state') or 'unknown')
" "$name" 2>/dev/null || echo unknown
}

# CLI reads mcp-auth.json directly; use when HTTP /mcp is stale after OAuth.
mcp_cli_connected() {
  local name="$1"
  docker_exec opencode mcp list 2>/dev/null | grep -E "✓ ${name} " | grep -qi connected
}

list_providers_json() {
  api_get "/provider" 2>/dev/null || echo '{}'
}

discover_local_git_roots() {
  docker_exec find "$WORKSPACE_ROOT" -name .git -type d -prune 2>/dev/null \
    | sed 's|/.git$||' \
    | sort
}

relative_workspace_path() {
  local abs="$1"
  echo "${abs#${WORKSPACE_ROOT}/}"
}

preflight_record() {
  local level="$1"
  local message="$2"
  local hint="${3:-}"
  case "$level" in
    ok)   PREFLIGHT_OK=$((PREFLIGHT_OK + 1));   printf '  [ok]   %s\n' "$message" ;;
    warn) PREFLIGHT_WARN=$((PREFLIGHT_WARN + 1)); printf '  [warn] %s\n' "$message" ;;
    fail) PREFLIGHT_FAIL=$((PREFLIGHT_FAIL + 1)); printf '  [fail] %s\n' "$message" ;;
  esac
  if [[ -n "$hint" ]]; then
    printf '         → %s\n' "$hint"
  fi
}

preflight_summary() {
  echo
  if (( PREFLIGHT_FAIL > 0 )); then
    echo "${PREFLIGHT_WARN} warning(s), ${PREFLIGHT_FAIL} failure(s). Fix failures or re-run with --force."
    return 1
  fi
  if (( PREFLIGHT_WARN > 0 )); then
    echo "${PREFLIGHT_WARN} warning(s), 0 failures."
  else
    echo "All checks passed."
  fi
  return 0
}

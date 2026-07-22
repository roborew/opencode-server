#!/usr/bin/env bash
# Shared helpers for OpenCode server setup (API, env, docker).
set -euo pipefail

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"
CONTAINER_NAME="${OPENCODE_CONTAINER:-opencode-server}"
# Must match docker/entrypoint.sh + compose XDG_DATA_HOME (serve + mcp auth).
CONTAINER_XDG_DATA_HOME="${OPENCODE_CONTAINER_XDG:-/var/opencode-xdg}"
# Host apps path inside the container (same-path bind). Set after load_env.
WORKSPACE_ROOT="${OPENCODE_WORKSPACE_ROOT:-${OPENCODE_APPS_DIR:-}}"

# Preflight counters (set by preflight.sh)
PREFLIGHT_OK=0
PREFLIGHT_WARN=0
PREFLIGHT_FAIL=0
PREFLIGHT_MCP_NEEDS_AUTH=()

# Ensure absolute host OPENCODE_APPS_DIR paths (identity if already host).
to_host_workspace_path() {
  local dir="${1%/}"
  if [[ -n "${WORKSPACE_ROOT:-}" && ( "$dir" == "$WORKSPACE_ROOT" || "$dir" == "$WORKSPACE_ROOT"/* ) ]]; then
    echo "$dir"
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

api_patch() {
  local path="$1"
  local body="${2:-{}}"
  local base
  base="$(opencode_base_url)"
  curl -sf -u "$(opencode_auth)" \
    -H "Content-Type: application/json" \
    -X PATCH "${base}${path}" \
    -d "$body"
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

# Prefer compose-injected XDG; still pass explicitly for older containers.
docker_exec_xdg() {
  docker exec -e "XDG_DATA_HOME=${CONTAINER_XDG_DATA_HOME}" "$CONTAINER_NAME" "$@"
}

docker_exec_xdg_it() {
  docker exec -it -e "XDG_DATA_HOME=${CONTAINER_XDG_DATA_HOME}" "$CONTAINER_NAME" "$@"
}

list_projects_json() {
  api_get "/project" 2>/dev/null || echo '[]'
}

project_registered() {
  local dir="$1"
  local host projects
  host="$(to_host_workspace_path "$dir")"
  projects="$(list_projects_json)"
  python3 -c "
import json, sys
target = sys.argv[1].rstrip('/')
data = json.loads(sys.argv[2])
for p in data:
    wt = (p.get('worktree') or p.get('directory') or '').rstrip('/')
    if wt == target:
        sys.exit(0)
sys.exit(1)
" "$host" "$projects"
}

register_project() {
  local dir="$1"
  local title="${2:-$(basename "$dir")}"
  dir="$(to_host_workspace_path "$dir")"
  if project_registered "$dir"; then
    echo "skip"
    return 0
  fi
  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"title": sys.argv[1]}))' "$title")"
  api_post "/session" "$body" "X-Opencode-Directory: ${dir}" >/dev/null
  echo "ok"
}

# Seed icon.color when missing. Clients only enable the colour picker once icon exists
# (session seed leaves icon null; Desktop-created projects usually already have one).
ensure_project_icons() {
  local root="${WORKSPACE_ROOT:-}"
  local projects
  projects="$(list_projects_json)"
  python3 -c "
import json, sys, urllib.request, base64
root = sys.argv[1].rstrip('/')
auth = sys.argv[2]
base = sys.argv[3].rstrip('/')
palette = ['orange','mint','pink','lime','purple','cyan','blue','red','amber','green']
data = json.loads(sys.argv[4] or '[]')
n = 0
for p in data:
    wt = (p.get('worktree') or '').rstrip('/')
    if not root or not wt or wt == '/' or not (wt == root or wt.startswith(root + '/')):
        continue
    icon = p.get('icon') or {}
    if isinstance(icon, dict) and icon.get('color'):
        continue
    pid = p.get('id') or ''
    if not pid:
        continue
    color = palette[sum(ord(c) for c in pid) % len(palette)]
    body = json.dumps({'icon': {'color': color}}).encode()
    req = urllib.request.Request(
        f'{base}/project/{pid}',
        data=body,
        method='PATCH',
        headers={
            'Authorization': 'Basic ' + base64.b64encode(auth.encode()).decode(),
            'Content-Type': 'application/json',
        },
    )
    try:
        urllib.request.urlopen(req)
        n += 1
        print(f\"  icon {wt.rsplit('/', 1)[-1]} -> {color}\")
    except Exception as exc:
        print(f\"  icon skip {wt.rsplit('/', 1)[-1]}: {exc}\", file=sys.stderr)
print(f\"Seeded icons: {n}\")
" "$root" "$(opencode_auth)" "$(opencode_base_url)" "$projects"
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
  local path
  path="$(to_host_workspace_path "$dir")"
  local ok=0 fail=0

  local sessions ids
  sessions="$(list_sessions_for_directory "$path")"
  ids="$(python3 -c "
import json, sys
for s in json.loads(sys.argv[1] or '[]'):
    sid = s.get('id') or ''
    if sid:
        print(sid)
" "$sessions")"
  if [[ -n "$ids" ]]; then
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
  fi

  if (( fail > 0 )); then
    echo "fail"
    return 1
  fi
  echo "ok"
}

list_registered_workspace_projects() {
  # Print host-path registrations under OPENCODE_APPS_DIR only.
  list_projects_json | python3 -c "
import json, sys
root = sys.argv[1].rstrip('/')
seen = set()
for p in json.load(sys.stdin):
    wt = (p.get('worktree') or '').rstrip('/')
    if not wt or not root:
        continue
    if wt == root or wt.startswith(root + '/'):
        if wt not in seen:
            seen.add(wt)
            print(wt)
" "$WORKSPACE_ROOT"
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
  docker_exec_xdg opencode mcp list 2>/dev/null | grep -E "✓ ${name} " | grep -qi connected
}

# Drop incomplete PKCE stubs (oauthState/codeVerifier, no access token) so a
# fresh setup auth is not poisoned by a prior Desktop/CLI attempt.
mcp_clear_pending_oauth() {
  local name="${1:-}"
  docker_exec_xdg python3 -c "
import json, shutil, time
from pathlib import Path
p = Path('/var/lib/opencode-data/mcp-auth.json')
if not p.exists():
    print('mcp-auth: missing')
    raise SystemExit(0)
bak = p.with_name(p.name + '.bak-' + time.strftime('%Y%m%dT%H%M%SZ'))
shutil.copy2(p, bak)
d = json.loads(p.read_text())
kept = {}
removed = []
prefix = '''${name}'''
for k, v in d.items():
    tokens = (v or {}).get('tokens') if isinstance(v, dict) else None
    has_access = isinstance(tokens, dict) and bool(tokens.get('accessToken'))
    pending = isinstance(v, dict) and ('oauthState' in v or 'codeVerifier' in v) and not has_access
    if pending and (not prefix or k == prefix or k.startswith(prefix + '-') or (prefix.startswith('cloudflare') and str(k).startswith('cloudflare'))):
        removed.append(k)
        continue
    kept[k] = v
p.write_text(json.dumps(kept, indent=2) + '\n')
print('mcp-auth backup:', bak.name)
print('mcp-auth removed:', removed or '[]')
"
}

# True when opencode serve (not just socat) owns 127.0.0.1:19876 — CLI mcp auth
# then registers state in a different process and the browser callback CSRF-fails.
mcp_oauth_callback_held_by_serve() {
  docker_exec python3 -c "
import os, pathlib
port_hex = f'{19876:04X}'
inodes = set()
for path in ('/proc/net/tcp', '/proc/net/tcp6'):
    try:
        lines = open(path)
    except OSError:
        continue
    for line in lines:
        parts = line.split()
        if parts[0] == 'sl':
            continue
        if parts[1].split(':')[1].upper() == port_hex and parts[3] == '0A':
            inodes.add(parts[9])
for proc in pathlib.Path('/proc').iterdir():
    if not proc.name.isdigit():
        continue
    try:
        for fd in (proc / 'fd').iterdir():
            try:
                target = os.readlink(fd)
            except OSError:
                continue
            if target.startswith('socket:[') and target[8:-1] in inodes:
                cmd = (proc / 'cmdline').read_bytes().replace(b'\\0', b' ').decode(errors='ignore')
                if 'opencode serve' in cmd or (cmd.startswith('opencode') and 'mcp auth' not in cmd and 'serve' in cmd):
                    raise SystemExit(0)
    except OSError:
        continue
raise SystemExit(1)
" 2>/dev/null
}

# Free :19876 for setup's interactive mcp auth (serve keeps an idle callback server).
mcp_ensure_oauth_callback_free() {
  if ! mcp_oauth_callback_held_by_serve; then
    return 0
  fi
  echo "OAuth callback port 19876 is held by opencode serve; restarting ${CONTAINER_NAME} so setup auth can bind it…"
  docker restart "$CONTAINER_NAME" >/dev/null
  wait_for_health 45 || return 1
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

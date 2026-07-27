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

# Upsert KEY=VALUE in REPO_ROOT/.env. Optional 3rd arg is a comment header when
# appending a new key (macOS/GNU sed -i portability avoided via awk).
upsert_env_key() {
  local key="$1"
  local value="$2"
  local new_section_comment="${3:-}"
  local env_file="${REPO_ROOT}/.env"
  local tmp
  touch "$env_file"
  tmp="$(mktemp)"
  if grep -qE "^${key}=" "$env_file" 2>/dev/null; then
    awk -v k="$key" -v v="$value" '
      BEGIN { done=0 }
      $0 ~ "^" k "=" {
        if (!done) { print k "=" v; done=1; next }
      }
      { print }
      END { if (!done) print k "=" v }
    ' "$env_file" >"$tmp"
    mv "$tmp" "$env_file"
  else
    rm -f "$tmp"
    if [[ -n "$new_section_comment" ]]; then
      printf '\n# %s\n%s=%s\n' "$new_section_comment" "$key" "$value" >>"$env_file"
    else
      printf '\n%s=%s\n' "$key" "$value" >>"$env_file"
    fi
  fi
}

# Resolve host UID/GID for the opencode container and upsert into .env.
# Order: explicit numeric OPENCODE_UID+GID → OPENCODE_USERNAME → current user.
# Prints "uid:gid (source)" on stdout; returns 0 on success.
ensure_opencode_uid_gid() {
  local uid gid source name
  local existing_uid="${OPENCODE_UID:-}"
  local existing_gid="${OPENCODE_GID:-}"

  if [[ "$existing_uid" =~ ^[0-9]+$ && "$existing_gid" =~ ^[0-9]+$ ]]; then
    uid="$existing_uid"
    gid="$existing_gid"
    source="explicit"
  elif [[ -n "${OPENCODE_USERNAME:-}" ]]; then
    name="${OPENCODE_USERNAME}"
    if ! uid="$(id -u "$name" 2>/dev/null)" || ! gid="$(id -g "$name" 2>/dev/null)"; then
      echo "ensure_opencode_uid_gid: unknown OPENCODE_USERNAME=${name}" >&2
      return 1
    fi
    source="user ${name}"
  else
    uid="$(id -u)"
    gid="$(id -g)"
    name="$(id -un)"
    source="user ${name}"
  fi

  export OPENCODE_UID="$uid"
  export OPENCODE_GID="$gid"
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    upsert_env_key OPENCODE_UID "$uid" "Runtime UID/GID (auto-filled by setup/preflight)"
    upsert_env_key OPENCODE_GID "$gid"
  fi
  echo "${uid}:${gid} (${source})"
}

# Ensure OPENCODE_APPS_DIR / OPENCODE_WORKTREES_DIR when already set (compose +
# preflight). Prefer Infisical for paths — do not invent ${HOME}/projects and
# write it into .env (that used to override Infisical via compose.sh pins).
ensure_opencode_host_paths() {
  local apps="${OPENCODE_APPS_DIR:-}"
  local wt="${OPENCODE_WORKTREES_DIR:-}"

  if [[ -z "$apps" ]] && container_running; then
    apps="$(container_env_get OPENCODE_APPS_DIR)"
  fi
  if [[ -z "$wt" ]] && container_running; then
    wt="$(container_env_get OPENCODE_WORKTREES_DIR)"
  fi

  if [[ -z "$apps" ]]; then
    apps="${HOME}/projects"
  fi
  if [[ -z "$wt" ]]; then
    wt="${HOME}/.local/share/opencode/worktree"
  fi

  export OPENCODE_APPS_DIR="$apps"
  export OPENCODE_WORKTREES_DIR="$wt"
  export WORKSPACE_ROOT="$apps"
  # Do not upsert paths into host .env — Infisical (or an explicit host edit) owns them.
  echo "${apps}"
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
  local user="${OPENCODE_SERVER_USERNAME:-}"
  local pass="${OPENCODE_SERVER_PASSWORD:-}"
  # Host .env often has Infisical bootstrap only — pull runtime auth from the
  # running container (.env compose injection or Infisical) when needed.
  if container_running; then
    if [[ -z "$user" ]]; then
      user="$(container_env_get OPENCODE_SERVER_USERNAME)"
    fi
    if [[ -z "$pass" || "$pass" == "change-me" ]]; then
      pass="$(container_env_get OPENCODE_SERVER_PASSWORD)"
    fi
  fi
  user="${user:-opencode}"
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

opencode_fqdn() {
  # Prefer host .env (optional pin). Else the alias Compose set from Infisical.
  if [[ -n "${OPENCODE_FQDN:-}" ]]; then
    echo "$OPENCODE_FQDN"
    return
  fi
  if container_running; then
    local alias
    alias="$(
      docker inspect "$CONTAINER_NAME" --format \
        '{{range $net, $v := .NetworkSettings.Networks}}{{range $v.Aliases}}{{println .}}{{end}}{{end}}' \
        2>/dev/null \
        | grep -Ev "^(${CONTAINER_NAME}|opencode)\$" \
        | head -1
    )"
    if [[ -n "$alias" ]]; then
      echo "$alias"
      return
    fi
  fi
  # No hardcoded fallback — OPENCODE_FQDN must come from Infisical (compose.sh) or host .env.
  echo ""
}

opencode_public_url() {
  local fqdn port
  fqdn="$(opencode_fqdn)"
  if [[ -z "$fqdn" ]]; then
    echo ""
    return 1
  fi
  port="${OPENCODE_PUBLISH_PORT:-4097}"
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

# Read KEY from PID 1 environ inside a container (runtime secrets — .env and/or Infisical).
# Must run as PID 1's uid: container root lacks CAP_SYS_PTRACE, so /proc/*/environ
# of another uid returns EACCES even for uid 0.
# Falls back to `docker inspect` Config.Env for minimal images (e.g. twingate) with no sh.
container_env_get() {
  local key="$1"
  local cname="${2:-$CONTAINER_NAME}"
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
    return 0
  fi
  local uid out=""
  uid="$(docker exec "$cname" stat -c '%u' /proc/1 2>/dev/null || true)"
  if [[ -n "$uid" ]]; then
    out="$(
      docker exec -u "$uid" "$cname" sh -c \
        "tr '\\0' '\\n' < /proc/1/environ 2>/dev/null | sed -n 's/^${key}=//p' | head -1" \
        2>/dev/null || true
    )"
  fi
  if [[ -z "$out" ]]; then
    out="$(
      docker inspect "$cname" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | sed -n "s/^${key}=//p" | head -1
    )"
  fi
  printf '%s' "$out"
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

# After session registration, projects often have icon=null and name=null.
# Desktop colour saves write name="" (meaning "default") and sometimes invalid
# colours like "green"; iOS then shows "?" instead of the folder name.
# Normalize so every client gets a real name + a valid avatar colour.
normalize_registered_projects() {
  local root="${WORKSPACE_ROOT:-}"
  local projects
  projects="$(list_projects_json)"
  python3 -c "
import json, sys, urllib.request, base64
root = sys.argv[1].rstrip('/')
auth = sys.argv[2]
base = sys.argv[3].rstrip('/')
palette = ['pink', 'mint', 'orange', 'purple', 'cyan', 'lime']
valid = set(palette)
data = json.loads(sys.argv[4] or '[]')
used = {((p.get('icon') or {}).get('color') or '') for p in data if ((p.get('icon') or {}).get('color') or '') in valid}
n = 0
for p in data:
    wt = (p.get('worktree') or '').rstrip('/')
    if not root or not wt or wt == '/' or not (wt == root or wt.startswith(root + '/')):
        continue
    pid = p.get('id') or ''
    if not pid:
        continue
    folder = wt.rsplit('/', 1)[-1]
    icon = p.get('icon') if isinstance(p.get('icon'), dict) else {}
    color = (icon or {}).get('color') or ''
    name = p.get('name')
    need_color = color not in valid
    # null/None is fine for some clients; empty string breaks iOS (\"?\").
    need_name = name is None or name == ''
    if not need_color and not need_name:
        continue
    if need_color:
        available = [c for c in palette if c not in used]
        color = available[0] if available else palette[sum(ord(c) for c in pid) % len(palette)]
        used.add(color)
    body = {'icon': {'color': color}}
    if need_name:
        body['name'] = folder
    req = urllib.request.Request(
        f'{base}/project/{pid}',
        data=json.dumps(body).encode(),
        method='PATCH',
        headers={
            'Authorization': 'Basic ' + base64.b64encode(auth.encode()).decode(),
            'Content-Type': 'application/json',
        },
    )
    try:
        urllib.request.urlopen(req)
        n += 1
        bits = []
        if need_color:
            bits.append(f'color={color}')
        if need_name:
            bits.append(f'name={folder}')
        print(f\"  normalize {folder}: {', '.join(bits)}\")
    except Exception as exc:
        print(f'  normalize skip {folder}: {exc}', file=sys.stderr)
print(f'Normalized projects: {n}')
" "$root" "$(opencode_auth)" "$(opencode_base_url)" "$projects"
}

# Back-compat alias used by setup.sh
assign_missing_project_colors() {
  normalize_registered_projects "$@"
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
  if [[ -n "${PREFLIGHT_PUBLIC_URL:-}" ]]; then
    echo "Open OpenCode: ${PREFLIGHT_PUBLIC_URL}"
    echo
  fi
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

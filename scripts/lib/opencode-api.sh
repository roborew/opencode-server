#!/usr/bin/env bash
# Shared helpers for OpenCode server setup (API, env, docker).
set -euo pipefail

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"
CONTAINER_NAME="${OPENCODE_CONTAINER:-opencode-server}"
# Must match docker/entrypoint.sh + compose XDG_DATA_HOME for persistent serve state.
CONTAINER_XDG_DATA_HOME="${OPENCODE_CONTAINER_XDG:-/var/opencode-xdg}"
# Host apps path inside the container (same-path bind). Set after load_env.
WORKSPACE_ROOT="${OPENCODE_WORKSPACE_ROOT:-${OPENCODE_APPS_DIR:-}}"

# Preflight counters (set by preflight.sh)
PREFLIGHT_OK=0
PREFLIGHT_WARN=0
PREFLIGHT_FAIL=0

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
  # OpenCode v2 hardcodes the basic-auth username to "opencode"
  # (OPENCODE_SERVER_USERNAME is unsupported); only the password is
  # configurable.
  local pass="${OPENCODE_SERVER_PASSWORD:-}"
  # Host .env often has Infisical bootstrap only — pull runtime auth from the
  # running container (.env compose injection or Infisical) when needed. Only
  # probe Docker when the password is actually missing: `docker ps` has no
  # timeout and must not run on every readiness poll.
  if [[ -z "$pass" || "$pass" == "change-me" ]]; then
    if container_running; then
      pass="$(container_env_get OPENCODE_SERVER_PASSWORD)"
    fi
  fi
  echo "opencode:${pass}"
}

api_get() {
  local path="$1"
  local timeout="${2:-}"
  local base
  local -a limits=(--connect-timeout 2)
  if [[ -n "$timeout" ]]; then
    limits+=(--max-time "$timeout")
  fi
  base="$(opencode_base_url)"
  curl -sf -u "$(opencode_auth)" "${limits[@]}" "${base}${path}"
}

api_post() {
  local path="$1"
  local body="${2:-}"
  local extra_header="${3:-}"
  if [[ -z "$body" ]]; then
    body='{}'
  fi
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
  # Returns 0 when the resource is gone: 2xx and 404 both mean "absent now",
  # so a parent-then-child session deletion is not counted as a failure.
  local path="$1"
  local extra_header="${2:-}"
  local base code
  local -a header_args=()
  if [[ -n "$extra_header" ]]; then
    header_args=(-H "$extra_header")
  fi
  base="$(opencode_base_url)"
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -u "$(opencode_auth)" \
    ${header_args[@]+"${header_args[@]}"} \
    --connect-timeout 2 --max-time 15 \
    -X DELETE "${base}${path}" 2>/dev/null || true)"
  case "${code:-000}" in
    2*|404) return 0 ;;
    *) return 1 ;;
  esac
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

# v2 GET /api/session wraps the list in {"data": [...], "cursor": {...}} and
# pages with an opaque cursor. Follow every page — a fixed limit can omit the
# newest sessions (deregister_project must see all of them). Fails loudly so
# callers do not treat an enumeration error as "no sessions".
list_sessions_json() {
  local cursor="" raw pages="" page_count=0 sep
  sep=$'\x1e' # record separator — cannot occur inside a JSON document
  while :; do
    local url="/api/session?limit=1000"
    if [[ -n "$cursor" ]]; then
      url="${url}&cursor=${cursor}"
    else
      url="${url}&order=asc"
    fi
    if ! raw="$(api_get "$url")"; then
      echo "list_sessions_json: GET ${url} failed" >&2
      return 1
    fi
    cursor="$(printf '%s' "$raw" | python3 -c '
import json, sys, urllib.parse
d = json.load(sys.stdin)
print(urllib.parse.quote((d.get("cursor") or {}).get("next") or "", safe=""))
')" || {
      echo "list_sessions_json: unparseable session page" >&2
      return 1
    }
    pages="${pages}${sep}${raw}"
    page_count=$((page_count + 1))
    if (( page_count > 1000 )); then
      echo "list_sessions_json: too many session pages" >&2
      return 1
    fi
    if [[ -z "$cursor" ]]; then
      break
    fi
  done
  printf '%s' "$pages" | python3 -c '
import json, sys
out = []
for chunk in sys.stdin.read().split("\x1e"):
    chunk = chunk.strip()
    if not chunk:
        continue
    out.extend(json.loads(chunk).get("data") or [])
print(json.dumps(out))
'
}

wait_for_health() {
  local max_attempts="${1:-30}"
  local attempt=0
  while (( attempt < max_attempts )); do
    if api_get "/api/info" >/dev/null 2>&1; then
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
  api_get "/api/project" 2>/dev/null || echo '[]'
}

# Resolve a directory through v2's location API. Besides validating the path,
# this persists (and, if necessary, unarchives) its owning project before we
# create the seed session used by clients. Bounded: a server that accepts the
# connection but never answers must not block the whole project sync.
resolve_project_location() {
  local dir="$1" encoded
  encoded="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1].rstrip("/"), safe=""))' "$dir")"
  api_get "/api/location?location%5Bdirectory%5D=${encoded}" 15
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
    wt = (p.get('canonical') or p.get('worktree') or p.get('directory') or '').rstrip('/')
    if wt == target:
        sys.exit(0)
sys.exit(1)
" "$host" "$projects"
}

# Every session directory on the server (deduped, one API listing).
# Returns nonzero when the session list cannot be fetched.
session_directories() {
  local all
  if ! all="$(list_sessions_json)"; then
    return 1
  fi
  # Read the JSON on stdin: session lists can exceed the OS argument limit.
  printf '%s' "$all" | python3 -c '
import json, sys
seen = set()
for s in json.load(sys.stdin) or []:
    d = ((s.get("location") or {}).get("directory") or s.get("directory") or "").rstrip("/")
    if d:
        seen.add(d)
for d in sorted(seen):
    print(d)
'
}

# True when $dir (or a session in a directory below it) has a session.
# Sessions in a nested repository that is its own project do not count.
# $2 = newline-separated session directories, $3 = newline-separated projects.
dir_has_session() {
  local dir="$1" sessions="${2:-}" projects="${3:-}"
  python3 -c '
import sys
target = sys.argv[1].rstrip("/")
session_dirs = [d.rstrip("/") for d in sys.argv[2].splitlines() if d.strip()]
projects = {p.rstrip("/") for p in sys.argv[3].splitlines() if p.strip()}
for d in session_dirs:
    if d != target and not d.startswith(target + "/"):
        continue
    if any(p != target and (d == p or d.startswith(p + "/")) for p in projects):
        continue
    sys.exit(0)
sys.exit(1)
' "$dir" "$sessions" "$projects"
}

# Registration is complete only when the project exists *and* a session lives
# in it. Location resolution alone persists the project, so a failed or
# cleaned-up seed would otherwise be skipped forever on the next run.
_seed_session_present() {
  local dir="$1" sessions projects
  if ! sessions="$(session_directories)"; then
    return 2
  fi
  projects="$(list_projects_json | python3 -c '
import json, sys
for p in json.loads(sys.stdin.read() or "[]"):
    wt = (p.get("canonical") or p.get("worktree") or p.get("directory") or "").rstrip("/")
    if wt:
        print(wt)
')"
  dir_has_session "$dir" "$sessions" "$projects"
}

# Verify a registration by project id when the server supplies one. Two local
# clones of the same origin share a single project whose canonical path is the
# first clone, so a path-only lookup would miss the second clone.
verify_registered_project() {
  local dir="$1" id="${2:-}"
  list_projects_json | python3 -c '
import json, sys
target = sys.argv[1].rstrip("/")
pid = sys.argv[2]
for p in json.loads(sys.stdin.read() or "[]"):
    if pid and p.get("id") == pid:
        sys.exit(0)
    wt = (p.get("canonical") or p.get("worktree") or p.get("directory") or "").rstrip("/")
    if wt == target:
        sys.exit(0)
sys.exit(1)
' "$dir" "$id"
}

register_project() {
  local dir="$1"
  local title="${2:-$(basename "$dir")}"
  dir="$(to_host_workspace_path "$dir")"

  if project_registered "$dir"; then
    local seed_state
    if _seed_session_present "$dir"; then
      echo "skip"
      return 0
    else
      seed_state=$?
    fi
    if (( seed_state == 2 )); then
      echo "could not list sessions for ${dir}; leaving it registered — re-run to retry the seed" >&2
      echo "skip"
      return 0
    fi
    echo "project ${dir} is registered but has no session — creating the seed" >&2
  fi

  local resolved response actual resolved_id="" resolved_canonical=""
  if ! resolved="$(resolve_project_location "$dir")"; then
    echo "could not resolve project location ${dir}" >&2
    return 1
  fi
  # <directory> TAB <project id> TAB <project canonical path>. The project
  # fields are optional (older responses omit them).
  if ! IFS=$'\t' read -r actual resolved_id resolved_canonical <<< "$(python3 -c '
import json, sys
value = json.loads(sys.argv[1])
project = value.get("project") or {}
print("\t".join([
    value.get("directory") or "",
    project.get("id") or "",
    (project.get("canonical") or project.get("worktree") or "").rstrip("/"),
]))
' "$resolved")"; then
    echo "invalid location response for ${dir}" >&2
    return 1
  fi
  if [[ "$actual" != "$dir" ]]; then
    echo "location API resolved ${dir} to unexpected directory ${actual:-<invalid response>}" >&2
    return 1
  fi
  if [[ -n "$resolved_id" && -n "$resolved_canonical" && "$resolved_canonical" != "$dir" ]]; then
    echo "location for ${dir} belongs to project ${resolved_id}, already registered at ${resolved_canonical}" >&2
    echo "  OpenCode keeps one project per repository origin — register one clone per origin, or deregister ${resolved_canonical} first" >&2
    return 1
  fi

  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"title": sys.argv[1], "location": {"directory": sys.argv[2]}}))' "$title" "$dir")"
  if ! response="$(api_post "/api/session" "$body")"; then
    echo "could not create seed session in ${dir}" >&2
    return 1
  fi
  if ! actual="$(python3 -c '
import json, sys
value = json.loads(sys.argv[1])
session = value.get("data") or value
print((session.get("location") or {}).get("directory") or "")
' "$response")"; then
    echo "invalid create-session response for ${dir}" >&2
    return 1
  fi
  if [[ "$actual" != "$dir" ]]; then
    echo "seed session landed in ${actual:-<unknown>} instead of ${dir}" >&2
    # Delete only the session this attempt created; the caller may retry, and a
    # stray session in the parent directory would otherwise linger forever.
    local session_id
    session_id="$(python3 -c '
import json, sys
value = json.loads(sys.argv[1])
session = value.get("data") or value
print(session.get("id") or "")
' "$response" 2>/dev/null || true)"
    if [[ -z "$session_id" ]]; then
      echo "create-session response had no id; the misplaced session was left in place" >&2
      return 1
    fi
    if api_delete "/api/session/${session_id}" >/dev/null 2>&1; then
      echo "removed the misplaced seed session ${session_id}" >&2
    else
      echo "could not remove misplaced seed session ${session_id}; it remains on the server" >&2
    fi
    return 1
  fi
  if ! verify_registered_project "$dir" "$resolved_id"; then
    echo "project ${dir} is still absent from /api/project after registration" >&2
    return 1
  fi
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
    wt = (p.get('canonical') or p.get('worktree') or '').rstrip('/')
    if not root or wt == '/' or not (wt == root or wt.startswith(root + '/')):
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
        f'{base}/api/project/{pid}',
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

# List sessions belonging to the worktree: the directory itself plus any
# session started in a subdirectory. Sessions inside a nested repository that is
# its own registered project stay out — archiving this project must not delete
# them. v2 Session.directory lives at location.directory (nested); filter
# client-side (v1's X-Opencode-Directory header is gone).
list_sessions_for_directory() {
  local dir="$1"
  local all projects
  if ! all="$(list_sessions_json)"; then
    return 1
  fi
  projects="$(list_projects_json)"
  # Session lists are piped on stdin: they can exceed the argument limit.
  printf '%s' "$all" | python3 -c "
import json, sys
target = sys.argv[1].rstrip('/')
projects = set()
for p in json.loads(sys.argv[2] or '[]'):
    wt = (p.get('canonical') or p.get('worktree') or p.get('directory') or '').rstrip('/')
    if wt:
        projects.add(wt)
out = []
for s in json.load(sys.stdin) or []:
    d = ((s.get('location') or {}).get('directory') or s.get('directory') or '').rstrip('/')
    if d != target and not d.startswith(target + '/'):
        continue
    if any(p != target and (d == p or d.startswith(p + '/')) for p in projects):
        continue
    out.append(s)
print(json.dumps(out))
" "$dir" "$projects"
}

# v2 has no project.delete or project.archive endpoint. Archive removed
# projects in the same on-volume DB used by Project.sweep; /api/project omits
# archived rows immediately, and resolving the location later unarchives them.
#
# Session deletes go through OPENCODE_HOST while the archive below writes SQLite
# in the local container. Refuse when those are not the same instance, otherwise
# `--host` could delete sessions on one server and archive a project on another.
require_same_server_for_archive() {
  local base publish_port host port
  base="$(opencode_base_url)"
  publish_port="${OPENCODE_PUBLISH_PORT:-4097}"
  publish_port="${publish_port##*:}"
  host="${base#*://}"
  host="${host%%/*}"
  port=""
  if [[ "$host" == \[*\]* ]]; then
    # Bracketed IPv6: [::1]:4097
    port="${host#*\]}"
    host="${host%%\]*}"
    host="${host#\[}"
    port="${port#:}"
  elif [[ "$host" == *:* ]]; then
    port="${host##*:}"
    host="${host%:*}"
  fi
  case "$host" in
    127.0.0.1 | localhost | ::1 | 0.0.0.0) ;;
    *)
      echo "refusing to delete sessions or archive projects: API target ${base} is not the local container (${CONTAINER_NAME}) — archive_project would edit a different server's database" >&2
      return 1
      ;;
  esac
  # An explicit host without a port falls back to :80, never the publish port.
  if [[ "$port" != "$publish_port" ]]; then
    echo "refusing to delete sessions or archive projects: API target ${base} does not use the local publish port ${publish_port} — archive_project would edit a different server's database" >&2
    return 1
  fi
  return 0
}

archive_project() {
  local dir="$1"
  local path
  path="$(to_host_workspace_path "$dir")"
  if ! require_same_server_for_archive; then
    return 1
  fi
  docker_exec python3 -c '
import sqlite3, sys, time

db_path, directory = sys.argv[1], sys.argv[2].rstrip("/")
con = sqlite3.connect(db_path, timeout=10)
con.execute("PRAGMA busy_timeout=10000")
# One statement so a concurrent worktree change cannot archive a row that has
# since moved to a different path.
now = time.time_ns() // 1_000_000
archived = con.execute(
    "UPDATE project SET time_archived = ? WHERE worktree = ?", (now, directory)
).rowcount
con.commit()
con.close()
print(f"archived {archived} project(s)")
' "${CONTAINER_XDG_DATA_HOME}/opencode/opencode.db" "$path"
}

# Delete sessions for a deselected worktree and archive its project. OpenCode
# persists projects independently of sessions, so deleting sessions alone does
# not remove the project from clients.
deregister_project() {
  local dir="$1"
  local path
  path="$(to_host_workspace_path "$dir")"
  local ok=0 fail=0

  # Check before any session is deleted: the archive below only works on the
  # local container's DB, so a non-local --host must not be deregistered.
  if ! require_same_server_for_archive; then
    return 1
  fi

  local sessions ids
  if ! sessions="$(list_sessions_for_directory "$path")"; then
    echo "fail"
    return 1
  fi
  if ! ids="$(python3 -c "
import json, sys
for s in json.loads(sys.argv[1] or '[]'):
    sid = s.get('id') or ''
    if sid:
        print(sid)
" "$sessions")"; then
    echo "fail"
    return 1
  fi
  if [[ -n "$ids" ]]; then
    local id
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      if api_delete "/api/session/${id}" >/dev/null 2>&1; then
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
  if ! archive_project "$path"; then
    echo "fail"
    return 1
  fi
  # The archive writes SQLite directly, so a server that keeps serving its own
  # project list would otherwise be reported as a successful removal. Use a
  # strict list: `list_projects_json` substitutes [] on error, which would look
  # like a successful removal.
  local projects
  if ! projects="$(api_get "/api/project" 15 2>/dev/null)" \
    || ! printf '%s' "$projects" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    echo "archived ${path} in the local database, but the project list could not be read — removal is unverified" >&2
    return 1
  fi
  if printf '%s' "$projects" | python3 -c "
import json, sys
target = sys.argv[1].rstrip('/')
for p in json.load(sys.stdin):
    wt = (p.get('canonical') or p.get('worktree') or p.get('directory') or '').rstrip('/')
    if wt == target:
        sys.exit(0)
sys.exit(1)
" "$path"; then
    echo "archived ${path} in the local database but the server still lists it — verify ${CONTAINER_NAME} uses that database, then re-run" >&2
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
    wt = (p.get('canonical') or p.get('worktree') or '').rstrip('/')
    if not wt or not root:
        continue
    if wt == root or wt.startswith(root + '/'):
        if wt not in seen:
            seen.add(wt)
            print(wt)
" "$WORKSPACE_ROOT"
}

list_mcp_json() {
  api_get "/api/mcp" 2>/dev/null || echo '{}'
}

list_providers_json() {
  api_get "/api/provider" 2>/dev/null || echo '{}'
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

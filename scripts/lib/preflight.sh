#!/usr/bin/env bash
# Preflight checklist for OpenCode Docker stack.
set -euo pipefail

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opencode-api.sh
source "${SCRIPT_LIB_DIR}/opencode-api.sh"
# shellcheck source=sandbox-enable.sh
source "${SCRIPT_LIB_DIR}/sandbox-enable.sh"
# shellcheck source=repo-env.sh
source "${SCRIPT_LIB_DIR}/repo-env.sh"

PREFLIGHT_JSON_MODE="${PREFLIGHT_JSON_MODE:-0}"

run_preflight() {
  PREFLIGHT_OK=0
  PREFLIGHT_WARN=0
  PREFLIGHT_FAIL=0
  PREFLIGHT_PUBLIC_URL=""

  echo "Preflight"

  check_env_file
  ensure_host_uid_gid
  check_required_env
  check_sandbox
  check_container
  check_optional_env
  check_opencode_health
  check_fqdn_local
  check_workspace_mount
  check_worktree_mount
  check_repo_ownership
  check_repo_envs
  check_opencode_data_volume
  check_milvus
  check_gh_auth
  check_coderabbit_auth
  check_providers
  check_twingate_connector
  check_mcps

  if [[ "$PREFLIGHT_JSON_MODE" == "1" ]]; then
    print_preflight_json
  fi

  preflight_summary
}

check_env_file() {
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    preflight_record ok ".env present"
    load_env || preflight_record fail "Failed to load .env"
  else
    preflight_record fail ".env missing" "cp .env.example .env"
  fi
}

# Auto-fill OPENCODE_UID/GID from the host user (or OPENCODE_USERNAME).
ensure_host_uid_gid() {
  if [[ ! -f "${REPO_ROOT}/.env" ]]; then
    return
  fi
  load_env 2>/dev/null || true
  local resolved
  if ! resolved="$(ensure_opencode_uid_gid)"; then
    preflight_record fail "Could not resolve OPENCODE_UID/GID" \
      "set OPENCODE_UID/OPENCODE_GID or a valid OPENCODE_USERNAME in .env"
    return
  fi
  preflight_record ok "OPENCODE_UID/GID = ${resolved}"
}

# Resolve apps/worktrees from Infisical-injected container env when host .env omits them.
resolve_runtime_paths() {
  load_env 2>/dev/null || true
  if [[ -z "${OPENCODE_APPS_DIR:-}" ]] && container_running; then
    OPENCODE_APPS_DIR="$(container_env_get OPENCODE_APPS_DIR)"
    export OPENCODE_APPS_DIR
  fi
  if [[ -z "${OPENCODE_WORKTREES_DIR:-}" ]] && container_running; then
    OPENCODE_WORKTREES_DIR="$(container_env_get OPENCODE_WORKTREES_DIR)"
    export OPENCODE_WORKTREES_DIR
  fi
  if [[ -n "${OPENCODE_APPS_DIR:-}" ]]; then
    export WORKSPACE_ROOT="${OPENCODE_APPS_DIR}"
  elif [[ -n "${OPENCODE_WORKSPACE_ROOT:-}" ]]; then
    export WORKSPACE_ROOT="${OPENCODE_WORKSPACE_ROOT}"
  fi
}

check_required_env() {
  if [[ ! -f "${REPO_ROOT}/.env" ]]; then
    return
  fi
  load_env || return
  if [[ -n "${INFISICAL_PROJECT_ID:-}" && -n "${INFISICAL_CLIENT_ID:-}${INFISICAL_TOKEN:-}" ]]; then
    preflight_record ok "Infisical bootstrap configured"
    return
  fi
  local pass="${OPENCODE_SERVER_PASSWORD:-}"
  if [[ -z "$pass" || "$pass" == "change-me" ]]; then
    preflight_record fail "OPENCODE_SERVER_PASSWORD not set or still change-me" \
      "edit .env or configure INFISICAL_* bootstrap"
  else
    preflight_record ok "OPENCODE_SERVER_PASSWORD configured"
  fi
}

# Runtime secrets may come from host .env (compose env_file/environment) or
# Infisical (compose.sh / entrypoint). Either way they must appear on PID 1.
check_optional_env() {
  if ! container_running; then
    return
  fi
  local -a missing=()
  local key val
  for key in GH_TOKEN OPENCODE_SERVER_PASSWORD GIT_USER_NAME; do
    val="$(container_env_get "$key")"
    [[ -z "$val" ]] && missing+=("$key")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    for m in "${missing[@]}"; do
      preflight_record warn "container missing ${m}" \
        "set ${m} in .env or Infisical so the running container receives it"
    done
  else
    preflight_record ok "container env present (GH_TOKEN, password, GIT_USER_NAME)"
  fi
}

check_sandbox() {
  load_env 2>/dev/null || true
  local mode="${OPENCODE_SANDBOX_MODE:-off}"
  local enabled="${OPENCODE_SANDBOX_ENABLED:-0}"
  mode="$(echo "$mode" | tr '[:upper:]' '[:lower:]')"

  case "$mode" in
    off|"")
      preflight_record ok "sandbox mode=off (host-safe default; no Sysbox siblings)"
      return
      ;;
  esac

  if [[ "$enabled" == "1" ]]; then
    if host_has_sysbox_runtime; then
      preflight_record ok "sandbox enabled (Sysbox siblings; COMPOSE_FILE includes sandbox overlay)"
    else
      preflight_record warn \
        "OPENCODE_SANDBOX_ENABLED=1 but sysbox-runc missing on host" \
        "./scripts/setup.sh sandbox  # or install Sysbox — see docs/sandbox.md"
    fi
    if container_running; then
      if docker exec "$CONTAINER_NAME" test -S /var/run/docker.sock 2>/dev/null; then
        preflight_record ok "sandbox: docker.sock mounted in ${CONTAINER_NAME}"
      else
        preflight_record warn \
          "sandbox enabled but docker.sock not in container" \
          "docker compose up -d  # with COMPOSE_FILE including docker-compose.sandbox.yml"
      fi
      # docker exec doesn't inherit the entrypoint's PATH, so use the absolute
      # path the Dockerfile installs the CLI at.
      if docker exec "$CONTAINER_NAME" test -x /usr/local/bin/sandbox 2>/dev/null; then
        local probe
        if probe="$(docker exec -e OPENCODE_SANDBOX_ENABLED=1 "$CONTAINER_NAME" /usr/local/bin/sandbox probe 2>/dev/null)"; then
          if echo "$probe" | grep -q '"available":true'; then
            preflight_record ok "sandbox probe available inside container"
          else
            preflight_record warn "sandbox probe: ${probe}"
          fi
        else
          preflight_record warn "sandbox probe failed inside container" "check image has /usr/local/bin/sandbox"
        fi
      else
        preflight_record warn \
          "sandbox CLI missing in container" \
          "docker compose build opencode && docker compose up -d"
      fi
    fi
    return
  fi

  if [[ "$mode" == "auto" ]]; then
    preflight_record warn \
      "sandbox mode=auto but not enabled (Sysbox not detected or setup not re-run)" \
      "./scripts/setup.sh sandbox"
  elif [[ "$mode" == "on" ]]; then
    preflight_record fail \
      "sandbox mode=on but OPENCODE_SANDBOX_ENABLED!=1" \
      "install Sysbox + ./scripts/setup.sh sandbox — see docs/sandbox.md"
  else
    preflight_record warn "sandbox mode=${mode} enabled=${enabled}"
  fi
}

check_repo_envs() {
  resolve_runtime_paths
  if [[ -z "${WORKSPACE_ROOT:-}" || ! -d "${WORKSPACE_ROOT}" ]]; then
    return
  fi
  # Per-repo .env is for Sysbox sibling sandbox builds only — server Infisical
  # does not inject into siblings. Skip when sandbox is off (Mac default).
  local mode="${OPENCODE_SANDBOX_MODE:-off}"
  local enabled="${OPENCODE_SANDBOX_ENABLED:-0}"
  mode="$(echo "$mode" | tr '[:upper:]' '[:lower:]')"
  if [[ "$enabled" != "1" && "$mode" != "on" ]]; then
    return
  fi
  local needs_paste=0 ok=0 scanned=0 skipped=0
  local root status
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    if repo_env_should_skip "$root"; then
      skipped=$((skipped + 1))
      continue
    fi
    scanned=$((scanned + 1))
    (( scanned > 40 )) && break
    status="$(classify_repo_env "$root")"
    case "$status" in
      ok) ok=$((ok + 1)) ;;
      needs_paste) needs_paste=$((needs_paste + 1)) ;;
    esac
  done < <(find "$WORKSPACE_ROOT" -maxdepth 3 -name .git -type d -prune 2>/dev/null | while read -r g; do dirname "$g"; done)

  local skip_note=""
  local skip_pat
  skip_pat="$(repo_env_skip_patterns)"
  if [[ "$skipped" -gt 0 && -n "$skip_pat" ]]; then
    skip_note="; skipped ${skipped} matching ${skip_pat}"
  fi

  if [[ "$scanned" -eq 0 ]]; then
    if [[ "$skipped" -gt 0 ]]; then
      preflight_record ok "repo .env: no work repos to check${skip_note}"
    else
      preflight_record warn "no git repos under ${WORKSPACE_ROOT} to check for .env"
    fi
    return
  fi
  if [[ "$needs_paste" -eq 0 ]]; then
    preflight_record ok "repo .env: ${ok}/${scanned} ready for Infisical/sandbox builds${skip_note}"
    return
  fi
  preflight_record warn \
    "repo .env: ok=${ok} needs_paste=${needs_paste} (of ${scanned}${skip_note})" \
    "./scripts/setup.sh projects local  # paste Infisical + repo vars into each .env (never auto-created)"
}

check_container() {
  if container_running; then
    preflight_record ok "container ${CONTAINER_NAME} running"
  else
    preflight_record fail "container ${CONTAINER_NAME} not running" "docker compose up -d"
  fi
}

check_opencode_health() {
  if ! container_running; then
    return
  fi
  load_env 2>/dev/null || return
  local health version code port attempt
  port="${OPENCODE_PUBLISH_PORT:-4097}"
  port="${port##*:}"

  # Readiness can lag right after recreate (entrypoint + serve + bridge).
  for attempt in {1..20}; do
    if health="$(api_get "/global/health" 2>/dev/null)"; then
      if command -v python3 >/dev/null 2>&1; then
        version="$(echo "$health" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('version','?'))" 2>/dev/null || echo '?')"
      else
        version="?"
      fi
      preflight_record ok "opencode-server healthy (v${version})"
      return
    fi
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/global/health" 2>/dev/null || true)"
    code="${code:-000}"
    if [[ "$code" == "401" ]]; then
      break
    fi
    if [[ "$code" != "000" ]]; then
      break
    fi
    sleep 2
  done

  # Host .env password often missing/wrong when secrets live in Infisical.
  # Retry the authenticated check with Infisical-injected env when configured.
  if [[ -n "${INFISICAL_PROJECT_ID:-}" && -n "${INFISICAL_CLIENT_ID:-}${INFISICAL_TOKEN:-}" ]] \
    && command -v infisical >/dev/null 2>&1; then
    local domain token client_id client_secret
    domain="${INFISICAL_DOMAIN:-${INFISICAL_API_URL:-}}"
    token="${INFISICAL_TOKEN:-}"
    if [[ -z "$token" ]]; then
      client_id="${INFISICAL_CLIENT_ID:-}"
      client_secret="${INFISICAL_CLIENT_SECRET:-}"
      if [[ -n "$client_id" && -n "$client_secret" && -n "$domain" ]]; then
        token="$(
          infisical login \
            --method=universal-auth \
            --client-id="$client_id" \
            --client-secret="$client_secret" \
            --domain="$domain" \
            --silent \
            --plain 2>/dev/null
        )" || token=""
      fi
    fi
    if [[ -n "$token" && -n "$domain" ]]; then
      health="$(
        infisical run \
          --projectId="$INFISICAL_PROJECT_ID" \
          --env="${INFISICAL_ENV:-dev}" \
          --domain="$domain" \
          --token="$token" \
          -- sh -c "curl -sf -u \"\${OPENCODE_SERVER_USERNAME:-opencode}:\${OPENCODE_SERVER_PASSWORD}\" \"http://127.0.0.1:${port}/global/health\"" \
          2>/dev/null
      )" || health=""
      if [[ -n "$health" ]]; then
        if command -v python3 >/dev/null 2>&1; then
          version="$(echo "$health" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('version','?'))" 2>/dev/null || echo '?')"
        else
          version="?"
        fi
        preflight_record ok "opencode-server healthy via Infisical (v${version})"
        return
      fi
    fi
  fi

  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/global/health" 2>/dev/null || true)"
  code="${code:-000}"
  if [[ "$code" == "401" ]]; then
    preflight_record warn \
      "opencode-server up (HTTP 401) — could not authenticate health check" \
      "password missing/mismatch in container; check OPENCODE_SERVER_PASSWORD in .env or Infisical"
    return
  fi
  if [[ "$code" == "000" ]]; then
    preflight_record fail "OpenCode not reachable on :${port}" "wait for startup; docker logs opencode-server"
    return
  fi
  preflight_record fail "OpenCode health check failed (HTTP ${code})" "check logs: docker logs opencode-server"
}

# Confirm OPENCODE_FQDN resolves on the Docker host and serves health (same URL as Twingate).
check_fqdn_local() {
  load_env 2>/dev/null || true
  local fqdn port url resolved
  fqdn="$(opencode_fqdn)"
  port="${OPENCODE_PUBLISH_PORT:-4097}"
  port="${port##*:}"
  url="$(opencode_public_url)"
  PREFLIGHT_PUBLIC_URL="$url"

  if [[ -z "${OPENCODE_FQDN:-}" ]]; then
    preflight_record ok "OPENCODE_FQDN from container/compose: ${fqdn}" \
      "optional: set OPENCODE_FQDN=${fqdn} in host .env to match Infisical"
  fi

  resolved=""
  if command -v dscacheutil >/dev/null 2>&1; then
    resolved="$(dscacheutil -q host -a name "$fqdn" 2>/dev/null | awk '/^ip_address:/{print $2; exit}')"
  fi
  if [[ -z "$resolved" ]] && command -v getent >/dev/null 2>&1; then
    resolved="$(getent ahostsv4 "$fqdn" 2>/dev/null | awk '{print $1; exit}' || true)"
  fi
  if [[ -z "$resolved" ]] && command -v python3 >/dev/null 2>&1; then
    resolved="$(
      python3 -c "import socket; print(socket.getaddrinfo('${fqdn}', None, socket.AF_INET)[0][4][0])" 2>/dev/null || true
    )"
  fi

  if [[ -z "$resolved" ]]; then
    preflight_record warn "OPENCODE_FQDN ${fqdn} does not resolve on this host" \
      "./scripts/setup.sh bootstrap  # or: sudo sh -c 'echo \"127.0.0.1 ${fqdn}\" >> /etc/hosts'"
    printf '         Open: %s\n' "$url"
    return
  fi

  case "$resolved" in
    127.0.0.1|::1)
      preflight_record ok "OPENCODE_FQDN ${fqdn} → ${resolved}"
      ;;
    *)
      preflight_record warn "OPENCODE_FQDN ${fqdn} → ${resolved} (expected 127.0.0.1 on Docker host)" \
        "./scripts/setup.sh bootstrap  # map ${fqdn} → 127.0.0.1 in /etc/hosts"
      ;;
  esac

  if ! container_running; then
    printf '         Open (when up): %s\n' "$url"
    return
  fi

  local code curl_args=(
    -s -o /dev/null -w '%{http_code}'
    -u "$(opencode_auth)"
    --connect-timeout 3 --max-time 8
  )
  # macOS often times out resolving *.local via mDNS even when /etc/hosts maps
  # it — pin the IP we already resolved so the FQDN URL is still exercised.
  if [[ -n "$resolved" ]]; then
    curl_args+=(--resolve "${fqdn}:${port}:${resolved}")
  fi
  code="$(curl "${curl_args[@]}" "${url}/global/health" 2>/dev/null || true)"
  code="${code:-000}"
  if [[ "$code" == "200" ]]; then
    preflight_record ok "local FQDN reachable" "$url"
  elif [[ "$code" == "401" ]]; then
    preflight_record warn "local FQDN responds (HTTP 401) — auth mismatch" "$url"
  else
    preflight_record warn "local FQDN not reachable (HTTP ${code})" \
      "./scripts/setup.sh bootstrap  # hosts + container; Open: ${url}"
  fi
}

check_workspace_mount() {
  if ! container_running; then
    return
  fi
  resolve_runtime_paths
  if [[ -z "${WORKSPACE_ROOT:-}" ]]; then
    preflight_record fail "OPENCODE_APPS_DIR not set" \
      "set in Infisical (or host .env) and recreate: ./scripts/compose.sh up -d --force-recreate opencode"
    return
  fi
  if docker_exec test -d "$WORKSPACE_ROOT" 2>/dev/null; then
    local count
    count="$(docker_exec sh -c "ls -1 '${WORKSPACE_ROOT}' 2>/dev/null | wc -l" | tr -d ' ')"
    preflight_record ok "workspace mount ${WORKSPACE_ROOT} (${count} entries)"
  else
    preflight_record fail "workspace mount missing at ${WORKSPACE_ROOT}" \
      "check OPENCODE_APPS_DIR in Infisical matches a real host path"
  fi
}

check_opencode_data_volume() {
  if ! container_running; then
    return
  fi
  # DB/auth must live on the named volume (entrypoint symlinks into XDG).
  if docker_exec sh -c 'test -L /var/opencode-xdg/opencode/opencode.db && readlink /var/opencode-xdg/opencode/opencode.db | grep -q /var/lib/opencode-data/' 2>/dev/null; then
    preflight_record ok "opencode.db linked to opencode-data volume"
  else
    preflight_record warn \
      "opencode.db not linked to opencode-data volume" \
      "./scripts/wipe-opencode-data.sh  # rebuild entrypoint + fresh volume"
  fi
}

# Flag dirs under WORKSPACE_ROOT (OPENCODE_APPS_DIR) that the current user
# cannot write to. Symptom: setup aborts with `touch ... Permission denied`
# when creating per-repo .env files. Most common cause is a repo dir owned by
# a different user (often root) inside an otherwise robin-owned workspace.
# In interactive mode we offer to `sudo chown -R` to the current user.
PREFLIGHT_FIX_OWNERSHIP="${PREFLIGHT_FIX_OWNERSHIP:-1}"

check_repo_ownership() {
  resolve_runtime_paths
  if [[ -z "${WORKSPACE_ROOT:-}" || ! -d "${WORKSPACE_ROOT}" ]]; then
    return
  fi
  local current_uid
  current_uid="$(id -u)"
  local bad=() scanned=0
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    scanned=$((scanned + 1))
    local owner_uid
    owner_uid="$(stat -c '%u' "$d" 2>/dev/null || echo 0)"
    if [[ "$owner_uid" != "$current_uid" ]] && ! [[ -w "$d" ]]; then
      bad+=("$d")
    fi
  done < <(find "$WORKSPACE_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
  if (( scanned == 0 )); then
    return
  fi
  if [[ ${#bad[@]} -eq 0 ]]; then
    preflight_record ok "workspace dirs writable as $(id -un) (${scanned} entries)"
    return
  fi
  local sample
  sample="$(printf '%s, ' "${bad[@]:0:3}" | sed 's/, $//')"
  if ! try_fix_workspace_ownership "$WORKSPACE_ROOT" "${bad[@]}"; then
    preflight_record warn \
      "${#bad[@]}/${scanned} workspace dir(s) not owned/writable by $(id -un): ${sample}" \
      "sudo chown -R \"$(id -un):$(id -gn)\" \"$WORKSPACE_ROOT\"   # then ./scripts/setup.sh projects local"
    return
  fi
  # Re-scan after attempted fix; if anything is still bad, warn.
  local still_bad=()
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    local owner_uid
    owner_uid="$(stat -c '%u' "$d" 2>/dev/null || echo 0)"
    if [[ "$owner_uid" != "$current_uid" ]] && ! [[ -w "$d" ]]; then
      still_bad+=("$d")
    fi
  done < <(find "$WORKSPACE_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
  if [[ ${#still_bad[@]} -eq 0 ]]; then
    preflight_record ok "workspace dirs writable as $(id -un) (${scanned} entries; auto-chowned)"
    return
  fi
  local still_sample
  still_sample="$(printf '%s, ' "${still_bad[@]:0:3}" | sed 's/, $//')"
  preflight_record warn \
    "${#still_bad[@]}/${scanned} workspace dir(s) still not writable after auto-fix: ${still_sample}" \
    "sudo chown -R \"$(id -un):$(id -gn)\" \"$WORKSPACE_ROOT\""
}

# Offer to chown WORKSPACE_ROOT to the current user via sudo. Returns 0 if a
# chown actually ran (and succeeded), 1 if the user declined / sudo missing /
# chown failed. Set PREFLIGHT_FIX_OWNERSHIP=0 to skip the offer entirely.
try_fix_workspace_ownership() {
  local root="$1"
  shift
  local -a bad=("$@")
  if [[ "${PREFLIGHT_FIX_OWNERSHIP}" != "1" ]]; then
    return 1
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    return 1
  fi
  local user group
  user="$(id -un)"
  group="$(id -gn)"
  if [[ -t 1 && -t 0 ]]; then
    echo
    echo "Workspace dirs not owned by ${user}. Auto-fix will run:"
    echo "  sudo chown -R ${user}:${group} ${root}"
    echo "Affected: ${#bad[@]} dir(s) under ${root}"
    local ans="n"
    if [[ "${YES:-0}" == "1" ]]; then
      ans="y"
    else
      read -r -p "Run sudo chown now? [Y/n] " ans
    fi
    if ! [[ "${ans:-y}" =~ ^[Yy]?$ ]]; then
      return 1
    fi
  fi
  if sudo chown -R "${user}:${group}" "${root}" 2>/tmp/preflight-chown.err; then
    rm -f /tmp/preflight-chown.err
    return 0
  fi
  echo "sudo chown failed:" >&2
  cat /tmp/preflight-chown.err >&2 || true
  rm -f /tmp/preflight-chown.err
  return 1
}

check_worktree_mount() {
  if ! container_running; then
    return
  fi
  resolve_runtime_paths
  local host_wt="${OPENCODE_WORKTREES_DIR:-}"
  local container_wt="/var/opencode-xdg/opencode/worktree"
  if [[ -z "$host_wt" ]]; then
    preflight_record warn "OPENCODE_WORKTREES_DIR not set" \
      "set in Infisical (or host .env) for host-visible worktrees"
    return
  fi
  if ! docker_exec test -d "$container_wt" 2>/dev/null; then
    preflight_record fail "worktree mount missing at ${container_wt}" "check OPENCODE_WORKTREES_DIR bind in compose"
    return
  fi
  if ! docker_exec test -w "$container_wt" 2>/dev/null; then
    preflight_record fail "worktree mount not writable at ${container_wt}"
    return
  fi
  local count
  count="$(docker_exec sh -c "ls -1 '${container_wt}' 2>/dev/null | wc -l" | tr -d ' ')"
  preflight_record ok "worktree mount ${host_wt} → ${container_wt} (${count} entries)"
}

check_milvus() {
  load_env 2>/dev/null || return
  local port="${MILVUS_HEALTH_PUBLISH_PORT:-9091}"
  port="${port##*:}"
  if curl -sf "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
    preflight_record ok "milvus healthz (localhost:${port})"
    return
  fi
  if container_running && docker_exec curl -sf http://localhost:9091/healthz >/dev/null 2>&1; then
    preflight_record ok "milvus healthz (inside network)"
    return
  fi
  preflight_record fail "milvus not healthy" "docker compose up -d && check milvus services"
}

check_gh_auth() {
  if ! container_running; then
    return
  fi
  load_env 2>/dev/null || true
  local status
  if status="$(docker_exec gh auth status 2>&1)"; then
    :
  else
    preflight_record fail "gh auth failed" \
      "set a valid GH_TOKEN in .env or Infisical (fine-grained PAT or classic with repo + read:org)"
    return
  fi

  # Fine-grained PATs (github_pat_*) do not expose classic OAuth scopes in
  # `gh auth status`. Validate by capability instead of grepping repo/read:org.
  if echo "$status" | grep -q 'github_pat_'; then
    preflight_record ok "gh auth (fine-grained PAT)"
  else
    local scopes=""
    if echo "$status" | grep -qiE '(^|[[:space:]'\''"])repo([,]|[[:space:]'\''"]|$)'; then
      scopes="repo"
    fi
    if echo "$status" | grep -qi "read:org"; then
      scopes="${scopes:+$scopes, }read:org"
    fi
    if [[ -z "$scopes" ]]; then
      preflight_record warn "gh auth ok but missing classic scopes (repo, read:org)" \
        "prefer a fine-grained PAT — see docs/integrations.md"
    else
      preflight_record ok "gh auth (classic scopes: ${scopes})"
    fi
  fi

  local gh_org="${GH_ORG:-}"
  if [[ -z "$gh_org" ]]; then
    gh_org="$(container_env_get GH_ORG)"
  fi
  if [[ -n "$gh_org" ]]; then
    if docker_exec gh api "orgs/${gh_org}" >/dev/null 2>&1; then
      preflight_record ok "gh org access: ${gh_org}"
    else
      preflight_record fail "cannot access org ${gh_org}" \
        "check GH_ORG, token resource owner, and org Members: Read"
      return
    fi
    if docker_exec gh api "orgs/${gh_org}/repos?per_page=1" >/dev/null 2>&1; then
      preflight_record ok "gh org repo list: ${gh_org}"
    else
      preflight_record fail "cannot list repos in ${gh_org}" \
        "grant Contents (and Metadata) on the org's repositories"
    fi
  fi
}

check_coderabbit_auth() {
  if ! container_running; then
    return
  fi
  if docker_exec coderabbit auth status >/dev/null 2>&1; then
    preflight_record ok "coderabbit auth (Agentic API key)"
  else
    preflight_record warn "coderabbit auth failed" \
      "set CODERABBIT_API_KEY in .env or Infisical (Agentic key from CodeRabbit dashboard)"
  fi
}

check_providers() {
  if ! container_running; then
    return
  fi
  local providers
  providers="$(list_providers_json 2>/dev/null || echo '{}')"
  local connected=0
  if command -v python3 >/dev/null 2>&1; then
    connected="$(echo "$providers" | python3 -c "
import json, sys
d = json.load(sys.stdin)
c = d.get('connected', [])
print(len(c) if isinstance(c, list) else 0)
" 2>/dev/null || echo 0)"
  fi
  if [[ "$connected" -gt 0 ]]; then
    preflight_record ok "provider(s) connected (${connected})"
  else
    preflight_record warn "no provider auth detected" \
      "set OPENROUTER_API_KEY in .env or Infisical, or connect via server UI"
  fi
}

check_twingate_connector() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx twingate-connector; then
    # Twingate image is minimal (no sh/stat) — use compose Config.Env via inspect.
    local network=""
    network="$(container_env_get TWINGATE_NETWORK twingate-connector)" || network=""
    if [[ -n "$network" ]]; then
      preflight_record ok "twingate-connector running (network=${network})"
    else
      preflight_record ok "twingate-connector running"
    fi
  else
    preflight_record warn "twingate-connector not running" \
      "remote access off — start via ./scripts/compose.sh if needed"
  fi
}

check_mcps() {
  if ! container_running; then
    return
  fi
  load_env 2>/dev/null || return
  local mcp_json
  mcp_json="$(list_mcp_json 2>/dev/null || echo '{}')"
  if [[ "$mcp_json" == "{}" || "$mcp_json" == "null" ]]; then
    preflight_record warn "no MCP status from server"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    preflight_record warn "python3 required for detailed MCP checks"
    return
  fi
  local mcp_report
  mcp_report="$(echo "$mcp_json" | python3 -c "
import json, sys, os

data = json.load(sys.stdin)
for name, info in sorted(data.items()):
    if not isinstance(info, dict):
        continue
    enabled = info.get('enabled', True)
    if enabled is False:
        print(f'disabled|{name}')
        continue
    status = info.get('status') or info.get('state') or 'unknown'
    print(f'{status}|{name}')
" 2>/dev/null || true)"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local status="${line%%|*}"
    local name="${line#*|}"
    case "$status" in
      disabled)
        # Skip disabled MCPs silently
        ;;
      connected|ready|ok)
        preflight_record ok "mcp/${name}: ${status}"
        ;;
      needs_auth|needs_client_registration|authenticating)
        preflight_record fail "mcp/${name}: ${status}" \
          "configure the upstream authentication in MCPJungle, then reconnect mcp/${name}"
        ;;
      *)
        if [[ "$name" == "claude-context" ]]; then
          check_claude_context "$status" "$name"
        else
          preflight_record warn "mcp/${name}: ${status}"
        fi
        ;;
    esac
  done <<< "$mcp_report"

}

check_claude_context() {
  local status="$1"
  local name="$2"
  local openai_key
  openai_key="$(container_env_get OPENAI_API_KEY)"
  if [[ -z "$openai_key" ]]; then
    preflight_record warn "mcp/${name}: OPENAI_API_KEY not set in container"
  elif [[ "$status" =~ ^(connected|ready|ok)$ ]]; then
    preflight_record ok "mcp/${name}: ${status}"
  else
    preflight_record warn "mcp/${name}: ${status} (check OPENAI_API_KEY in .env or Infisical, and Milvus)"
  fi
}

print_preflight_json() {
  python3 -c "
import json
print(json.dumps({
    'ok': ${PREFLIGHT_OK},
    'warn': ${PREFLIGHT_WARN},
    'fail': ${PREFLIGHT_FAIL},
}))
"
}

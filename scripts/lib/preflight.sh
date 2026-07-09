#!/usr/bin/env bash
# Preflight checklist for OpenCode Docker stack.
set -euo pipefail

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opencode-api.sh
source "${SCRIPT_LIB_DIR}/opencode-api.sh"

PREFLIGHT_JSON_MODE="${PREFLIGHT_JSON_MODE:-0}"
PREFLIGHT_INTERACTIVE_AUTH="${PREFLIGHT_INTERACTIVE_AUTH:-1}"

run_preflight() {
  PREFLIGHT_OK=0
  PREFLIGHT_WARN=0
  PREFLIGHT_FAIL=0
  PREFLIGHT_MCP_NEEDS_AUTH=()

  echo "Preflight"

  check_env_file
  check_required_env
  check_optional_env
  check_container
  check_opencode_health
  check_workspace_mount
  check_milvus
  check_ssh_agent
  check_gh_auth
  check_providers
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

check_required_env() {
  if [[ ! -f "${REPO_ROOT}/.env" ]]; then
    return
  fi
  load_env || return
  local pass="${OPENCODE_SERVER_PASSWORD:-}"
  if [[ -z "$pass" || "$pass" == "change-me" ]]; then
    preflight_record fail "OPENCODE_SERVER_PASSWORD not set or still change-me" "edit .env"
  else
    preflight_record ok "OPENCODE_SERVER_PASSWORD configured"
  fi
}

check_optional_env() {
  load_env 2>/dev/null || return
  local -a missing=()
  [[ -z "${OPENROUTER_API_KEY:-}" ]] && missing+=("OPENROUTER_API_KEY (model provider)")
  [[ -z "${OPENAI_API_KEY:-}" ]] && missing+=("OPENAI_API_KEY (claude-context embeddings)")
  [[ -z "${GH_TOKEN:-}" ]] && missing+=("GH_TOKEN (GitHub CLI)")
  [[ -z "${GH_ORG:-}" ]] && missing+=("GH_ORG (org repo listing)")
  [[ -z "${DOCS_MCP_URL:-}" ]] && missing+=("DOCS_MCP_URL (docs MCP)")
  [[ -z "${TWINGATE_NETWORK:-}" ]] && missing+=("TWINGATE_* (remote access)")
  if [[ ${#missing[@]} -gt 0 ]]; then
    for m in "${missing[@]}"; do
      preflight_record warn "Optional: $m"
    done
  else
    preflight_record ok "Optional env vars present"
  fi
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
  local health version
  if health="$(api_get "/global/health" 2>/dev/null)"; then
    if command -v python3 >/dev/null 2>&1; then
      version="$(echo "$health" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('version','?'))" 2>/dev/null || echo '?')"
    else
      version="?"
    fi
    preflight_record ok "opencode-server healthy (v${version})"
  else
    preflight_record fail "OpenCode health check failed" "check OPENCODE_SERVER_PASSWORD and logs"
  fi
}

check_workspace_mount() {
  if ! container_running; then
    return
  fi
  if docker_exec test -d "$WORKSPACE_ROOT" 2>/dev/null; then
    local count
    count="$(docker_exec sh -c "ls -1 '${WORKSPACE_ROOT}' 2>/dev/null | wc -l" | tr -d ' ')"
    preflight_record ok "workspace mount ${WORKSPACE_ROOT} (${count} entries)"
  else
    preflight_record fail "workspace mount missing at ${WORKSPACE_ROOT}" "check OPENCODE_APPS_DIR in .env"
  fi
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

check_ssh_agent() {
  if ! container_running; then
    return
  fi
  load_env 2>/dev/null || return
  if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    preflight_record warn "SSH_AUTH_SOCK not set (git signing / SSH clone may fail)"
    return
  fi
  if docker_exec test -S /ssh-agent 2>/dev/null; then
    preflight_record ok "SSH agent socket mounted"
  else
    preflight_record warn "SSH agent socket not available in container" "fix SSH_AUTH_SOCK path in .env"
  fi
}

check_gh_auth() {
  if ! container_running; then
    return
  fi
  load_env 2>/dev/null || return
  if [[ -z "${GH_TOKEN:-}" ]]; then
    preflight_record warn "GH_TOKEN not set — gh auth skipped"
    return
  fi
  local status
  if status="$(docker_exec gh auth status 2>&1)"; then
  :
  else
    preflight_record fail "gh auth failed" \
      "set GH_TOKEN in .env (fine-grained PAT or classic with repo + read:org)"
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
        "prefer a fine-grained PAT — see README"
    else
      preflight_record ok "gh auth (classic scopes: ${scopes})"
    fi
  fi

  if [[ -n "${GH_ORG:-}" ]]; then
    if docker_exec gh api "orgs/${GH_ORG}" >/dev/null 2>&1; then
      preflight_record ok "gh org access: ${GH_ORG}"
    else
      preflight_record fail "cannot access org ${GH_ORG}" \
        "check GH_ORG, token resource owner, and org Members: Read"
      return
    fi
    if docker_exec gh api "orgs/${GH_ORG}/repos?per_page=1" >/dev/null 2>&1; then
      preflight_record ok "gh org repo list: ${GH_ORG}"
    else
      preflight_record fail "cannot list repos in ${GH_ORG}" \
        "grant Contents (and Metadata) on the org's repositories"
    fi
  fi
}

check_providers() {
  if ! container_running; then
    return
  fi
  load_env 2>/dev/null || return
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
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    preflight_record ok "OPENROUTER_API_KEY set in env"
  elif [[ "$connected" -gt 0 ]]; then
    preflight_record ok "provider(s) connected (${connected})"
  else
    preflight_record warn "no provider auth detected" "set OPENROUTER_API_KEY or connect via server UI"
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
        PREFLIGHT_MCP_NEEDS_AUTH+=("$name")
        preflight_record fail "mcp/${name}: ${status}" \
          "docker exec -it ${CONTAINER_NAME} opencode mcp auth ${name}"
        ;;
      *)
        if [[ "$name" == "docs-mcp-server" ]]; then
          check_docs_mcp_reachability "$status" "$name"
        elif [[ "$name" == "claude-context" ]]; then
          check_claude_context "$status" "$name"
        else
          preflight_record warn "mcp/${name}: ${status}"
        fi
        ;;
    esac
  done <<< "$mcp_report"

  if [[ ${#PREFLIGHT_MCP_NEEDS_AUTH[@]} -gt 0 && "$PREFLIGHT_INTERACTIVE_AUTH" == "1" ]]; then
    offer_mcp_auth
  fi
}

check_docs_mcp_reachability() {
  local status="$1"
  local name="$2"
  load_env 2>/dev/null || return
  local url="${DOCS_MCP_URL:-}"
  if [[ -z "$url" ]]; then
    preflight_record warn "mcp/${name}: ${status} (DOCS_MCP_URL not set)"
    return
  fi
  if docker_exec curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
    preflight_record ok "mcp/${name}: reachable"
  else
    preflight_record warn "DOCS_MCP_URL unreachable from container" "start docs MCP on host or fix URL (${url})"
  fi
}

check_claude_context() {
  local status="$1"
  local name="$2"
  load_env 2>/dev/null || return
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    preflight_record warn "mcp/${name}: OPENAI_API_KEY not set"
  elif [[ "$status" =~ ^(connected|ready|ok)$ ]]; then
    preflight_record ok "mcp/${name}: ${status}"
  else
    preflight_record warn "mcp/${name}: ${status} (check OPENAI_API_KEY and Milvus)"
  fi
}

offer_mcp_auth() {
  for name in "${PREFLIGHT_MCP_NEEDS_AUTH[@]}"; do
    echo
    read -r -p "Authenticate mcp/${name} now? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      echo "Open the authorize URL in a browser that can reach 127.0.0.1:19876"
      echo "  Local Mac: use this machine's browser"
      echo "  Remote/DO: ssh -N -L 19876:127.0.0.1:19876 user@host  (then use the laptop browser)"
      docker exec -it "$CONTAINER_NAME" opencode mcp auth "$name" || true
      # Auth writes tokens to disk; serve process needs an MCP reconnect to pick them up.
      echo "Reconnecting mcp/${name} on the OpenCode server…"
      mcp_server_reconnect "$name"
      local status
      status="$(mcp_status_for "$name")"
      if [[ ! "$status" =~ ^(connected|ready|ok)$ ]] && mcp_cli_connected "$name"; then
        status="connected"
      fi
      if [[ "$status" =~ ^(connected|ready|ok)$ ]]; then
        preflight_record ok "mcp/${name}: authenticated (${status})"
        PREFLIGHT_FAIL=$((PREFLIGHT_FAIL - 1))
      else
        preflight_record fail "mcp/${name}: still ${status}" \
          "docker exec -it ${CONTAINER_NAME} opencode mcp debug ${name}"
      fi
    fi
  done
}

print_preflight_json() {
  python3 -c "
import json
print(json.dumps({
    'ok': ${PREFLIGHT_OK},
    'warn': ${PREFLIGHT_WARN},
    'fail': ${PREFLIGHT_FAIL},
    'mcp_needs_auth': $(printf '%s\n' "${PREFLIGHT_MCP_NEEDS_AUTH[@]:-}" | python3 -c "import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null || echo '[]'),
}))
"
}

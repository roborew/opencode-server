#!/usr/bin/env bash
# Host-side Sysbox sandbox enablement for opencode-server setup.
# OPENCODE_SANDBOX_MODE: off (default) | auto | on
set -euo pipefail

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opencode-api.sh
source "${SCRIPT_LIB_DIR}/opencode-api.sh"

SANDBOX_COMPOSE_FILE="docker-compose.sandbox.yml"
SANDBOX_COMPOSE_PAIR="docker-compose.yml:${SANDBOX_COMPOSE_FILE}"

# True if host Docker advertises sysbox-runc.
host_has_sysbox_runtime() {
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1 || return 1
  local runtimes
  runtimes="$(docker info --format '{{range $k, $v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null || true)"
  [[ "$runtimes" == *"sysbox-runc"* ]]
}

# Optional smoke: sysbox can start a container (skipped when SKIP_SYSBOX_SMOKE=1).
host_sysbox_smoke() {
  if [[ "${SKIP_SYSBOX_SMOKE:-0}" == "1" ]]; then
    return 0
  fi
  docker run --runtime=sysbox-runc --rm alpine:3.20 true >/dev/null 2>&1
}

# Probe host capability. Prints reason on stderr when failing.
# Exit 0 = available, 1 = unavailable.
probe_host_sandbox() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker CLI not found on host" >&2
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "docker daemon not reachable" >&2
    return 1
  fi
  if ! host_has_sysbox_runtime; then
    echo "sysbox-runc not registered in Docker runtimes" >&2
    return 1
  fi
  if ! host_sysbox_smoke; then
    echo "sysbox-runc smoke run failed (docker run --runtime=sysbox-runc --rm alpine true)" >&2
    return 1
  fi
  return 0
}

_strip_sandbox_from_compose_file() {
  local current="${1:-}"
  local out="" part
  IFS=':' read -r -a parts <<<"$current"
  for part in "${parts[@]+"${parts[@]}"}"; do
    [[ -z "$part" || "$part" == "$SANDBOX_COMPOSE_FILE" ]] && continue
    if [[ -z "$out" ]]; then
      out="$part"
    else
      out="${out}:${part}"
    fi
  done
  # If only the default compose remains, clear COMPOSE_FILE (compose default).
  if [[ "$out" == "docker-compose.yml" || -z "$out" ]]; then
    echo ""
  else
    echo "$out"
  fi
}

_enable_sandbox_compose() {
  upsert_env_key "OPENCODE_SANDBOX_ENABLED" "1" "Sysbox sibling sandboxes (optional)"
  upsert_env_key "COMPOSE_FILE" "$SANDBOX_COMPOSE_PAIR"
  if [[ -z "${OPENCODE_SANDBOX_IMAGE:-}" ]]; then
    upsert_env_key "OPENCODE_SANDBOX_IMAGE" "opencode-sandbox:local"
  fi
}

_disable_sandbox_compose() {
  local env_file="${REPO_ROOT}/.env"
  if [[ ! -f "$env_file" ]]; then
    return 0
  fi
  upsert_env_key "OPENCODE_SANDBOX_ENABLED" "0"
  load_env 2>/dev/null || true
  local current="${COMPOSE_FILE:-}"
  local next
  next="$(_strip_sandbox_from_compose_file "$current")"
  if [[ -z "$next" ]]; then
    # Remove COMPOSE_FILE line if present so Mac path uses default compose only.
    if grep -qE '^COMPOSE_FILE=' "${env_file}"; then
      local tmp
      tmp="$(mktemp)"
      grep -vE '^COMPOSE_FILE=' "${env_file}" >"$tmp" || true
      mv "$tmp" "${env_file}"
    fi
  else
    upsert_env_key "COMPOSE_FILE" "$next"
  fi
}

# Resolve OPENCODE_SANDBOX_MODE and update .env / print next steps.
# Returns 0 always for auto/off; returns 1 when mode=on and probe fails.
configure_sandbox_mode() {
  load_env 2>/dev/null || true
  local mode="${OPENCODE_SANDBOX_MODE:-off}"
  mode="$(echo "$mode" | tr '[:upper:]' '[:lower:]')"

  case "$mode" in
    off|"")
      echo "Sandbox: mode=off (default) — Mac-identical stack; no docker.sock mount."
      _disable_sandbox_compose
      load_env 2>/dev/null || true
      return 0
      ;;
    auto)
      echo "Sandbox: mode=auto — probing host for Sysbox..."
      if probe_host_sandbox; then
        echo "Sandbox: Sysbox detected — enabling sibling sandboxes."
        _enable_sandbox_compose
        load_env 2>/dev/null || true
        echo "Sandbox: set OPENCODE_SANDBOX_ENABLED=1 and COMPOSE_FILE=${SANDBOX_COMPOSE_PAIR}"
        echo "Sandbox: rebuild/restart with:"
        echo "  docker compose build opencode"
        echo "  docker build -t \${OPENCODE_SANDBOX_IMAGE:-opencode-sandbox:local} -f docker/sandbox/Dockerfile docker/sandbox"
        echo "  docker compose up -d"
        return 0
      fi
      echo "Sandbox: Sysbox not detected — sandbox features off (stack continues)."
      echo "Sandbox: see docs/sandbox.md — Optional Sysbox sibling sandboxes."
      _disable_sandbox_compose
      load_env 2>/dev/null || true
      return 0
      ;;
    on)
      echo "Sandbox: mode=on — requiring Sysbox..."
      if probe_host_sandbox; then
        echo "Sandbox: Sysbox OK — enabling sibling sandboxes."
        _enable_sandbox_compose
        load_env 2>/dev/null || true
        echo "Sandbox: set OPENCODE_SANDBOX_ENABLED=1 and COMPOSE_FILE=${SANDBOX_COMPOSE_PAIR}"
        echo "Sandbox: rebuild/restart with:"
        echo "  docker compose build opencode"
        echo "  docker build -t \${OPENCODE_SANDBOX_IMAGE:-opencode-sandbox:local} -f docker/sandbox/Dockerfile docker/sandbox"
        echo "  docker compose up -d"
        return 0
      fi
      echo "Sandbox: ERROR — OPENCODE_SANDBOX_MODE=on but Sysbox probe failed." >&2
      echo "Sandbox: Install Sysbox CE (package path) — see docs/sandbox.md." >&2
      _disable_sandbox_compose
      return 1
      ;;
    *)
      echo "Sandbox: unknown OPENCODE_SANDBOX_MODE='${mode}' (use off|auto|on)" >&2
      return 1
      ;;
  esac
}

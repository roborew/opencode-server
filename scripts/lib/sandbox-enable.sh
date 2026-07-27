#!/usr/bin/env bash
# Host-side Sysbox sandbox enablement for opencode-server setup.
# OPENCODE_SANDBOX_MODE: off (default) | auto | on
#
# Single entry point is ./scripts/setup.sh (default) which calls
# configure_sandbox_mode. When sandbox gets enabled (either by user setting
# OPENCODE_SANDBOX_MODE=auto|on, or auto probing Sysbox on the host), this
# module also drives the stack rebuild + restart so the docker.sock overlay
# and OPENCODE_SANDBOX_ENABLED=1 actually land on the running container — no
# extra `docker compose build` / `build-image.sh` / `up -d` required from the
# operator. Use OPENCODE_SANDBOX_SKIP_AUTO_BUILD=1 to opt out and do it
# manually.
set -euo pipefail

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opencode-api.sh
source "${SCRIPT_LIB_DIR}/opencode-api.sh"

SANDBOX_COMPOSE_FILE="docker-compose.sandbox.yml"
SANDBOX_COMPOSE_PAIR="docker-compose.yml:${SANDBOX_COMPOSE_FILE}"
SCRIPT_BIN_DIR="$(cd "${SCRIPT_LIB_DIR}/.." && pwd)"

# Pick the right compose entry: Infisical wrapper if available, else bare.
# Pulls OPENCODE_SANDBOX_* and OPENCODE_APPS_DIR through Infisical so the build
# sees the same runtime env the container will get.
compose_cmd() {
  if [[ -x "${SCRIPT_BIN_DIR}/compose.sh" ]] && command -v infisical >/dev/null 2>&1; then
    if [[ -n "${INFISICAL_PROJECT_ID:-}" && -n "${INFISICAL_DOMAIN:-}${INFISICAL_API_URL:-}" ]]; then
      echo "${SCRIPT_BIN_DIR}/compose.sh"
      return
    fi
  fi
  echo "docker compose"
}

# True when the stack is already up with the overlay applied (docker.sock
# mounted in the opencode container) and sandbox is reported enabled.
sandbox_stack_already_enabled() {
  if [[ "${OPENCODE_SANDBOX_ENABLED:-0}" != "1" ]]; then
    return 1
  fi
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx opencode-server; then
    return 1
  fi
  if ! docker exec opencode-server test -S /var/run/docker.sock 2>/dev/null; then
    return 1
  fi
  if ! docker exec opencode-server test -x /usr/local/bin/sandbox 2>/dev/null; then
    return 0
  fi
  local probe
  probe="$(docker exec -e OPENCODE_SANDBOX_ENABLED=1 opencode-server /usr/local/bin/sandbox probe 2>/dev/null || true)"
  [[ "$probe" == *'"available":true'* ]]
}

# True when a recreate is required: container running but docker.sock missing
# (overlay not yet applied) or sandbox CLI missing (stale image).
sandbox_stack_needs_recreate() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx opencode-server || return 1
  if ! docker exec opencode-server test -S /var/run/docker.sock 2>/dev/null; then
    return 0
  fi
  if ! docker exec opencode-server test -x /usr/local/bin/sandbox 2>/dev/null; then
    return 0
  fi
  return 1
}

# True when the sibling image exists with the current tag.
sibling_image_present() {
  local image="${OPENCODE_SANDBOX_IMAGE:-opencode-sandbox:local}"
  command -v docker >/dev/null 2>&1 || return 1
  docker image inspect "$image" >/dev/null 2>&1
}

# Build the opencode image and the sibling image, then bring the stack up with
# the overlay. Idempotent: if everything is already in place, prints a one-line
# "already enabled" message and returns.
auto_enable_sandbox_stack() {
  if [[ "${OPENCODE_SANDBOX_SKIP_AUTO_BUILD:-0}" == "1" ]]; then
    echo "Sandbox: OPENCODE_SANDBOX_SKIP_AUTO_BUILD=1 — skipping auto build/restart."
    return 0
  fi
  local cc
  cc="$(compose_cmd)"
  if sandbox_stack_already_enabled && sibling_image_present; then
    echo "Sandbox: stack already enabled (docker.sock in container, sibling image present)."
    return 0
  fi
  local image="${OPENCODE_SANDBOX_IMAGE:-opencode-sandbox:local}"
  # Decide whether we need a full image build or just a recreate. If the
  # opencode image is missing or older than its build context, rebuild.
  local needs_image_build=1
  local image_name="opencode-server-opencode"
  if command -v docker >/dev/null 2>&1 && docker image inspect "$image_name" >/dev/null 2>&1; then
    if [[ -f "${REPO_ROOT}/Dockerfile" ]] && [[ -f "${REPO_ROOT}/docker-compose.sandbox.yml" ]]; then
      local image_ts ctx_ts
      image_ts="$(docker image inspect "$image_name" --format '{{.Created}}' 2>/dev/null || echo 1970)"
      ctx_ts="$(stat -c %Y "${REPO_ROOT}/Dockerfile" "${REPO_ROOT}/docker-compose.sandbox.yml" 2>/dev/null | sort -n | tail -1)"
      if [[ "$ctx_ts" =~ ^[0-9]+$ ]] && [[ "$image_ts" =~ ^[0-9TZ:.\+-]+$ ]]; then
        local image_epoch
        image_epoch="$(date -u -d "$image_ts" +%s 2>/dev/null || echo 0)"
        if [[ "$image_epoch" -ge "$ctx_ts" ]]; then
          needs_image_build=0
        fi
      fi
    fi
  fi
  if [[ "$needs_image_build" == "1" ]]; then
    echo "Sandbox: building opencode image (with overlay env)..."
    $cc build opencode
  else
    echo "Sandbox: opencode image up to date — skipping rebuild."
  fi
  # Sibling image lives outside the compose graph. OPENCODE_SANDBOX_IMAGE may
  # come from Infisical via the running container; re-resolve it once the build
  # has updated config.
  if [[ -z "$image" || "$image" == "opencode-sandbox:local" ]] \
      && command -v docker >/dev/null 2>&1 \
      && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx opencode-server; then
    local from_container
    from_container="$(container_env_get OPENCODE_SANDBOX_IMAGE 2>/dev/null || true)"
    [[ -n "$from_container" ]] && image="$from_container"
  fi
  if ! sibling_image_present || [[ "$image" != "${OPENCODE_SANDBOX_IMAGE:-opencode-sandbox:local}" ]]; then
    echo "Sandbox: building sibling image ${image}..."
    OPENCODE_SANDBOX_IMAGE="$image" "${SCRIPT_BIN_DIR}/sandbox/build-image.sh"
  else
    echo "Sandbox: sibling image ${image} present — skipping rebuild."
  fi
  if sandbox_stack_needs_recreate || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx opencode-server; then
    echo "Sandbox: bringing stack up with overlay..."
    $cc up -d opencode
  else
    echo "Sandbox: recreating opencode service to mount docker.sock..."
    $cc up -d --force-recreate opencode
  fi
  echo "Sandbox: stack up. Probing..."
  local attempt
  for attempt in {1..45}; do
    if sandbox_stack_already_enabled; then
      echo "Sandbox: ready."
      return 0
    fi
    sleep 2
  done
  echo "Sandbox: WARN — stack did not report ready within 90s; check 'docker logs opencode-server'." >&2
  return 0
}

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

# Resolve OPENCODE_SANDBOX_MODE and update .env, then drive the build/restart
# so the overlay lands on the running container. Returns 0 always for auto/off;
# returns 1 when mode=on and the Sysbox probe fails.
#
# When OPENCODE_SANDBOX_MODE=auto and the host has Sysbox, this also enables
# sandbox on a Mac-shaped host (the canonical Ubuntu setup). When mode=off
# nothing changes. OPENCODE_SANDBOX_SKIP_AUTO_BUILD=1 disables the build
# portion (handy for the smoke test or for operators who want to drive the
# stack manually).
configure_sandbox_mode() {
  load_env 2>/dev/null || true
  # Fall back to the running container's env when the host .env omits the
  # sandbox block (Infisical-only deployment).
  if command -v docker >/dev/null 2>&1 \
      && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx opencode-server; then
    if [[ -z "${OPENCODE_SANDBOX_MODE:-}" ]]; then
      OPENCODE_SANDBOX_MODE="$(container_env_get OPENCODE_SANDBOX_MODE 2>/dev/null || true)"
      export OPENCODE_SANDBOX_MODE
    fi
    if [[ -z "${OPENCODE_SANDBOX_IMAGE:-}" ]]; then
      OPENCODE_SANDBOX_IMAGE="$(container_env_get OPENCODE_SANDBOX_IMAGE 2>/dev/null || true)"
      export OPENCODE_SANDBOX_IMAGE
    fi
  fi

  local mode="${OPENCODE_SANDBOX_MODE:-off}"
  mode="$(echo "$mode" | tr '[:upper:]' '[:lower:]')"

  case "$mode" in
    off|"")
      echo "Sandbox: mode=off (default) — host-safe stack; no docker.sock mount."
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
        auto_enable_sandbox_stack
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
        auto_enable_sandbox_stack
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

#!/usr/bin/env bash
# Smoke: probe → create → nested compose test → destroy.
# On Mac / sandbox off: expects SANDBOX_UNAVAILABLE (exit 2) and exits 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SANDBOX="${SCRIPT_DIR}/sandbox"
REPO_FIXTURE_DIR="${REPO_ROOT}/docker/sandbox/fixtures/compose-smoke"
SMOKE_ID="smoke-$$"

# Inherit the lib helpers (opencode-env / container_env_get) so we can read
# PID 1's environ with the right uid (root inside the container cannot read
# another uid's /proc/1/environ). The lib also has the right UID/GID helpers.
# shellcheck source=../lib/opencode-api.sh
source "${SCRIPT_DIR}/../lib/opencode-api.sh"

# Prefer in-container CLI when OpenCode is running with sandbox enabled.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx opencode-server; then
  if docker exec opencode-server test -x /usr/local/bin/sandbox 2>/dev/null; then
    run_sandbox() {
      local sb_enabled="${OPENCODE_SANDBOX_ENABLED:-}"
      if [[ -z "$sb_enabled" ]]; then
        sb_enabled="$(container_env_get OPENCODE_SANDBOX_ENABLED 2>/dev/null || true)"
      fi
      if [[ -n "$sb_enabled" ]]; then
        docker exec -e OPENCODE_SANDBOX_ENABLED="$sb_enabled" opencode-server /usr/local/bin/sandbox "$@"
      else
        docker exec opencode-server /usr/local/bin/sandbox "$@"
      fi
    }
  else
    run_sandbox() { "$SANDBOX" "$@"; }
  fi
else
  run_sandbox() { "$SANDBOX" "$@"; }
fi

# Resolve the smoke worktree path. Infisical is the source of truth and the
# host .env is bootstrap-only; ask the running container. The fixture must
# live under a host path that is (a) bind-mounted into the container at the
# same path, and (b) writable by the host user. We use a sibling subdir of
# OPENCODE_WORKTREES_DIR because compose bind-mounts that exact host path
# into the container (the runtime user owns it). Going above the worktree
# dir would land in a container-only /home/robin/... stub that does not
# reflect the host filesystem, so write access would be lost.
resolve_worktrees_dir() {
  if [[ -n "${OPENCODE_WORKTREES_DIR:-}" ]]; then
    echo "${OPENCODE_WORKTREES_DIR%/}"
    return
  fi
  local v
  v="$(container_env_get OPENCODE_WORKTREES_DIR 2>/dev/null || true)"
  if [[ -n "$v" ]]; then
    echo "${v%/}"
    return
  fi
}

WORKTREES_DIR="$(resolve_worktrees_dir)"
if [[ -z "${WORKTREES_DIR:-}" ]]; then
  echo "Smoke: cannot determine OPENCODE_WORKTREES_DIR (host or container)" >&2
  exit 1
fi
SMOKE_FIXTURE_DIR="${WORKTREES_DIR}/.smoke-fixtures/compose-smoke"

# Ensure the fixture exists at the path the in-container CLI can see. The
# canonical copy lives in the repo; copy once on first run so OPENCODE_APPS_DIR
# always has a host-path copy the sibling can bind.
ensure_fixture_under_apps_dir() {
  if [[ -f "${SMOKE_FIXTURE_DIR}/docker-compose.test.yml" ]]; then
    return 0
  fi
  if [[ ! -f "${REPO_FIXTURE_DIR}/docker-compose.test.yml" ]]; then
    echo "Smoke: canonical fixture missing at ${REPO_FIXTURE_DIR}/docker-compose.test.yml" >&2
    return 1
  fi
  echo "Smoke: seeding ${REPO_FIXTURE_DIR} -> ${SMOKE_FIXTURE_DIR}"
  mkdir -p "${SMOKE_FIXTURE_DIR}"
  cp -a "${REPO_FIXTURE_DIR}/." "${SMOKE_FIXTURE_DIR}/"
}

echo "== sandbox probe =="
set +e
probe_out="$(run_sandbox probe 2>&1)"
probe_rc=$?
set -e
echo "$probe_out"

if [[ "$probe_rc" -eq 2 ]] || echo "$probe_out" | grep -q '"available":false'; then
  echo "Smoke: sandbox unavailable (expected on Mac / OPENCODE_SANDBOX_MODE=off). OK."
  exit 0
fi

if [[ "$probe_rc" -ne 0 ]]; then
  echo "Smoke: unexpected probe failure (rc=${probe_rc})" >&2
  exit 1
fi

if ! echo "$probe_out" | grep -q '"available":true'; then
  echo "Smoke: probe did not report available=true" >&2
  exit 1
fi

# Host-path fixture (same path inside sibling when mounted from OpenCode).
# Path must be visible to the in-container `sandbox` CLI and the host docker
# daemon bind — i.e. under OPENCODE_APPS_DIR. Seed from repo on first run.
if ! ensure_fixture_under_apps_dir; then
  exit 1
fi
WORKTREE="$SMOKE_FIXTURE_DIR"
if [[ ! -f "${WORKTREE}/docker-compose.test.yml" ]]; then
  echo "Smoke: missing fixture ${WORKTREE}/docker-compose.test.yml" >&2
  exit 1
fi

cleanup() {
  run_sandbox destroy --id "$SMOKE_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== sandbox create =="
run_sandbox create --id "$SMOKE_ID" --worktree "$WORKTREE"

echo "== sandbox exec compose test =="
run_sandbox exec --id "$SMOKE_ID" -- \
  docker compose -f docker-compose.test.yml run --rm test

if [[ "${SMOKE_EXPOSE:-0}" == "1" ]]; then
  host="${SMOKE_EXPOSE_HOSTNAME:-}"
  port="${SMOKE_EXPOSE_PORT:-80}"
  if [[ -z "$host" ]]; then
    echo "Smoke: SMOKE_EXPOSE=1 requires SMOKE_EXPOSE_HOSTNAME" >&2
    exit 1
  fi
  echo "== sandbox expose =="
  run_sandbox expose --id "$SMOKE_ID" --port "$port" --hostname "$host"
  echo "== sandbox unexpose =="
  run_sandbox unexpose --id "$SMOKE_ID"
fi

echo "== sandbox destroy =="
run_sandbox destroy --id "$SMOKE_ID"
trap - EXIT

if [[ "${SMOKE_EXPOSE:-0}" == "1" ]]; then
  echo "Smoke: OK (create → compose test → expose → unexpose → destroy)"
else
  echo "Smoke: OK (create → compose test → destroy)"
fi

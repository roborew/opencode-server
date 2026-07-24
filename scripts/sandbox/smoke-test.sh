#!/usr/bin/env bash
# Smoke: probe → create → nested compose test → destroy.
# On Mac / sandbox off: expects SANDBOX_UNAVAILABLE (exit 2) and exits 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SANDBOX="${SCRIPT_DIR}/sandbox"
FIXTURE_DIR="${REPO_ROOT}/docker/sandbox/fixtures/compose-smoke"
SMOKE_ID="smoke-$$"

# Prefer in-container CLI when OpenCode is running with sandbox enabled.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx opencode-server; then
  if docker exec opencode-server test -x /usr/local/bin/sandbox 2>/dev/null; then
    run_sandbox() { docker exec -e OPENCODE_SANDBOX_ENABLED="${OPENCODE_SANDBOX_ENABLED:-}" opencode-server sandbox "$@"; }
  else
    run_sandbox() { "$SANDBOX" "$@"; }
  fi
else
  run_sandbox() { "$SANDBOX" "$@"; }
fi

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

# Host-path fixture (same path inside sibling when mounted from OpenCode)
WORKTREE="$FIXTURE_DIR"
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

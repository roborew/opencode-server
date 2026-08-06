#!/usr/bin/env bash
# Launch `opencode serve` behind the worktree delete-guard proxy.
# Used by entrypoint for both plain and Infisical-wrapped startups.
set -euo pipefail

# Re-apply after Infisical inject (secrets/env not visible in outer entrypoint).
# shellcheck source=/dev/null
source /usr/local/bin/configure-git-identity.sh
configure_git_identity

CONTAINER_WT="${OPENCODE_CONTAINER_WORKTREE:-/var/opencode-xdg/opencode/worktree}"
export OPENCODE_EXPERIMENTAL_WORKSPACES="${OPENCODE_EXPERIMENTAL_WORKSPACES:-true}"
export OPENCODE_CONTAINER_WORKTREE="$CONTAINER_WT"

if [[ "${OPENCODE_DELETE_GUARD:-1}" == "0" || "${OPENCODE_DELETE_GUARD:-1}" == "false" ]]; then
  exec "$@"
fi
if [[ ! -f /usr/local/bin/worktree-delete-guard.py ]]; then
  exec "$@"
fi

cmd=("$@")
upstream=()
i=0
while [[ $i -lt ${#cmd[@]} ]]; do
  if [[ "${cmd[$i]}" == "--port" && $((i + 1)) -lt ${#cmd[@]} ]]; then
    upstream+=(--port 4098)
    i=$((i + 2))
    continue
  fi
  if [[ "${cmd[$i]}" == "--hostname" && $((i + 1)) -lt ${#cmd[@]} ]]; then
    upstream+=(--hostname 127.0.0.1)
    i=$((i + 2))
    continue
  fi
  upstream+=("${cmd[$i]}")
  i=$((i + 1))
done

export OPENCODE_UPSTREAM_HOST=127.0.0.1
export OPENCODE_UPSTREAM_PORT=4098
export OPENCODE_GUARD_HOST=0.0.0.0
export OPENCODE_GUARD_PORT=4097

echo "opencode-serve-guarded: delete-guard 0.0.0.0:4097 → 127.0.0.1:4098 (EXPERIMENTAL_WORKSPACES=${OPENCODE_EXPERIMENTAL_WORKSPACES})" >&2
setsid "${upstream[@]}" &
upstream_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if (echo >/dev/tcp/127.0.0.1/4098) >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$upstream_pid" 2>/dev/null; then
    echo "opencode-serve-guarded: upstream exited before bind" >&2
    wait "$upstream_pid" || true
    exit 1
  fi
  sleep 0.5
done
# Keep both processes as children. The old `exec` left the delete guard alive
# when OpenCode was OOM-killed, so Docker kept reporting a broken container as
# running and never applied restart: unless-stopped.
python3 /usr/local/bin/worktree-delete-guard.py &
guard_pid=$!

stop_children() {
  kill "$upstream_pid" "$guard_pid" 2>/dev/null || true
  wait "$upstream_pid" "$guard_pid" 2>/dev/null || true
}
trap 'stop_children; exit 0' INT TERM HUP

if wait -n "$upstream_pid" "$guard_pid"; then
  exit_status=0
else
  exit_status=$?
fi
if ! kill -0 "$upstream_pid" 2>/dev/null; then
  exited_pid="opencode"
elif ! kill -0 "$guard_pid" 2>/dev/null; then
  exited_pid="delete-guard"
else
  exited_pid="unknown"
fi

echo "opencode-serve-guarded: ${exited_pid} exited (status=${exit_status}); stopping service so Docker restarts it" >&2
stop_children
# Any unexpected child exit is a service failure, including status 0.
exit 1

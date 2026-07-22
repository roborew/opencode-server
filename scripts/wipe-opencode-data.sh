#!/usr/bin/env bash
# Wipe Docker OpenCode state (named volume). Optionally clear Desktop's
# open-project list for this server URL so a reconnect starts clean.
#
# Does NOT delete git repos under OPENCODE_APPS_DIR or worktree checkouts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=lib/opencode-api.sh
source "${SCRIPT_DIR}/lib/opencode-api.sh"

YES="${YES:-0}"
RESET_DESKTOP="${RESET_DESKTOP:-0}"
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    --desktop) RESET_DESKTOP=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/wipe-opencode-data.sh [--yes] [--desktop]

Stops the compose stack, removes the opencode-data Docker volume (DB, sessions,
MCP auth tokens for the server), and starts again with --build.

  --desktop   Also clear OpenCode Desktop's open-project / recently-closed
              lists for this server URL (macOS Application Support).
              Requires Desktop fully quit (Cmd+Q). Use this when migrating
              off legacy /workspace/apps paths or starting a clean E2E test.

Safe by default: host repos and worktrees are left alone.
EOF
      exit 0
      ;;
  esac
done

load_env || true

echo "This removes Docker volume opencode-server_opencode-data (server DB/auth)."
echo "OPENCODE_APPS_DIR repos and worktrees are NOT deleted."
if [[ "$RESET_DESKTOP" == "1" ]]; then
  echo "Also clearing Desktop open-list for this server URL (--desktop)."
fi
if [[ "$YES" != "1" ]]; then
  read -r -p "Continue? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

reset_desktop_server_memory() {
  local app_support="${HOME}/Library/Application Support/ai.opencode.desktop"
  local global="${app_support}/opencode.global.dat"
  local fqdn="${OPENCODE_FQDN:-opencode.local}"
  local port="${OPENCODE_PUBLISH_PORT:-4097}"
  port="${port##*:}"
  local server_url="http://${fqdn}:${port}"

  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Desktop reset skipped (macOS only)."
    return 0
  fi
  if [[ ! -f "$global" ]]; then
    echo "Desktop global.dat not found — nothing to clear."
    return 0
  fi
  if [[ -e "${app_support}/SingletonLock" ]]; then
    echo "OpenCode Desktop is still running (SingletonLock present)." >&2
    echo "Quit Desktop fully (Cmd+Q), then re-run with --desktop." >&2
    return 1
  fi

  local ts backup
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="${app_support}/opencode.global.dat.bak-wipe-${ts}"
  cp "$global" "$backup"
  echo "Desktop backup: ${backup}"

  python3 - "$global" "$server_url" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
server_url = sys.argv[2].rstrip("/")
data = json.loads(path.read_text())
raw_server = data.get("server")
server = json.loads(raw_server) if isinstance(raw_server, str) else (raw_server or {})

projects = server.setdefault("projects", {})
old = projects.get(server_url, [])
projects[server_url] = []
print(f"Cleared open projects for {server_url}: {len(old)} -> 0")

closed = server.setdefault("recentlyClosed", {})
prev = closed.get(server_url, [])
closed[server_url] = [
    p for p in prev
    if isinstance(p, str) and not p.startswith("/workspace/")
][:16]
print(f"Scrubbed recentlyClosed: {len(prev)} -> {len(closed[server_url])}")

lp = server.setdefault("lastProject", {})
if isinstance(lp, dict) and server_url in lp:
    lp.pop(server_url, None)
    print(f"Cleared lastProject for {server_url}")

if isinstance(raw_server, str):
    data["server"] = json.dumps(server, separators=(",", ":"))
else:
    data["server"] = server
path.write_text(json.dumps(data, indent="\t") + "\n")
PY
}

if [[ "$RESET_DESKTOP" == "1" ]]; then
  reset_desktop_server_memory
fi

echo "Stopping stack..."
docker compose down

echo "Removing volume opencode-server_opencode-data (if present)..."
docker volume rm opencode-server_opencode-data 2>/dev/null || true

echo "Starting stack (rebuild image)..."
docker compose up -d --build

echo
echo "Done. Fresh server is up."
echo "Next (Desktop still closed):"
echo "  ./scripts/setup.sh"
echo "  # projects local → registers host paths + assigns OpenCode colours"
echo "  # then reopen Desktop and connect to http://${OPENCODE_FQDN:-opencode.local}:${OPENCODE_PUBLISH_PORT##*:}"
echo "  # Open each project once via + (host paths under OPENCODE_APPS_DIR) — no /workspace paths."

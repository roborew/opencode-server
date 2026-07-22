#!/usr/bin/env bash
# Wipe Docker OpenCode state only (named volume). Does NOT touch Desktop
# ~/.local/share/opencode or your git repos under OPENCODE_APPS_DIR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

YES="${YES:-0}"
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/wipe-opencode-data.sh [--yes]

Stops the compose stack, removes the opencode-data Docker volume (DB, sessions,
MCP auth tokens for the server), and starts again with --build.

Safe for Desktop: host ~/.local/share/opencode is left alone.
Worktrees under OPENCODE_WORKTREES_DIR are left alone (host bind).
EOF
      exit 0
      ;;
  esac
done

echo "This removes Docker volume opencode-server_opencode-data (server DB/auth)."
echo "Desktop ~/.local/share/opencode and OPENCODE_APPS_DIR repos are NOT deleted."
if [[ "$YES" != "1" ]]; then
  read -r -p "Continue? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "Stopping stack..."
docker compose down

echo "Removing volume opencode-server_opencode-data (if present)..."
docker volume rm opencode-server_opencode-data 2>/dev/null || true

echo "Starting stack (rebuild image)..."
docker compose up -d --build

echo
echo "Done. Next:"
echo "  ./scripts/setup.sh"
echo "  # re-auth MCP if prompted, then projects local — registers host paths only"

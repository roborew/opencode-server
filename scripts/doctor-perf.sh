#!/usr/bin/env bash
# Quick performance doctor for OpenCode Desktop + this Docker stack.
# Usage: ./scripts/doctor-perf.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="${HOME}/Library/Application Support/ai.opencode.desktop"

# shellcheck source=lib/opencode-api.sh
source "${SCRIPT_DIR}/lib/opencode-api.sh"

hr() { printf '\n== %s ==\n' "$1"; }

hr "Host OpenCode / claude-context"
if /bin/ps -ax -o rss=,pcpu=,command= 2>/dev/null | /usr/bin/grep -E 'OpenCode\.app|claude-context' | /usr/bin/grep -v grep; then
  :
else
  echo "(no OpenCode.app or claude-context processes)"
fi
CC_COUNT="$(/bin/ps -ax -o command= 2>/dev/null | /usr/bin/grep -c '[c]laude-context' || true)"
CC_RSS="$(/bin/ps -ax -o rss=,command= 2>/dev/null | /usr/bin/grep '[c]laude-context' \
  | /usr/bin/awk '{s+=$1} END {printf "%.0f", s/1024}' || true)"
echo "claude-context processes=${CC_COUNT:-0} rss_mb=${CC_RSS:-0}"

hr "Host memory pressure (summary)"
memory_pressure 2>/dev/null | head -20 || echo "(memory_pressure unavailable)"

hr "Docker stats"
if docker stats --no-stream 2>/dev/null; then
  :
else
  echo "docker stats failed — is Docker Desktop running / socket accessible?"
fi

hr "opencode-server limits"
if docker inspect opencode-server --format \
  'MemoryLimit={{.HostConfig.Memory}} NanoCpus={{.HostConfig.NanoCpus}} State={{.State.Status}}' 2>/dev/null; then
  :
else
  echo "(opencode-server not running or not inspectable)"
fi

hr "Desktop app-data"
if [[ -d "${DESKTOP_DIR}" ]]; then
  du -sh "${DESKTOP_DIR}" 2>/dev/null || true
  echo "workspace .dat count: $(find "${DESKTOP_DIR}" -maxdepth 1 -name 'opencode.workspace.*.dat' 2>/dev/null | wc -l | tr -d ' ')"
  echo "crashpad pending: $(find "${DESKTOP_DIR}/Crashpad/pending" -type f 2>/dev/null | wc -l | tr -d ' ')"
  du -sh "${DESKTOP_DIR}/Cache" "${DESKTOP_DIR}/kilo" 2>/dev/null || true
else
  echo "(no ${DESKTOP_DIR})"
fi

hr "OpenCode caches / worktrees"
du -sh "${HOME}/.cache/opencode" 2>/dev/null || echo "~/.cache/opencode: (missing)"
du -sh "${HOME}/.local/share/opencode/worktree" 2>/dev/null || echo "worktree dir: (missing)"

hr "Host claude-context MCP flag"
HOST_CFG="${HOME}/.config/opencode/opencode.json"
if [[ -f "${HOST_CFG}" ]]; then
  python3 - <<PY
import json
with open("${HOST_CFG}") as f:
    d = json.load(f)
cc = d.get("mcp", {}).get("claude-context", {})
print("enabled =", cc.get("enabled"))
print("(keep false while Desktop uses Docker; server MCP is separate)")
PY
else
  echo "(no ${HOST_CFG})"
fi

hr "Server health (localhost)"
load_env || true
if [[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]]; then
  curl -sf -u "$(opencode_auth)" "$(opencode_base_url)/global/health" && echo \
    || echo "health check failed"
else
  echo "OPENCODE_SERVER_PASSWORD unset — skip"
fi

hr "Hints"
cat <<'EOF'
- Many host claude-context processes → quit Desktop, pkill -f claude-context-mcp, set mcp.claude-context.enabled=false in ~/.config/opencode/opencode.json
- After CONFIG_REPO/CONFIG_REF changes → docker compose build --no-cache opencode && docker compose up -d opencode (never down -v)
- Idle without indexing → COMPOSE_PROFILES= docker compose up -d  (omit milvus profile) or: docker compose stop milvus-standalone milvus-minio etcd
- Full doctor after a freeze: run this script while the UI is glitching
EOF

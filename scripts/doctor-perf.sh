#!/usr/bin/env bash
# Quick performance doctor for OpenCode Desktop + this Docker stack.
# Usage: ./scripts/doctor-perf.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="${HOME}/Library/Application Support/ai.opencode.desktop"

# shellcheck source=lib/opencode-api.sh
source "${SCRIPT_DIR}/lib/opencode-api.sh"

hr() { printf '\n== %s ==\n' "$1"; }

hr "Host OpenCode processes"
if /bin/ps -ax -o rss=,pcpu=,command= 2>/dev/null | /usr/bin/grep -E 'OpenCode\.app' | /usr/bin/grep -v grep; then
  :
else
  echo "(no OpenCode.app processes)"
fi

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

hr "code-index"
code_index_doctor_report

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

hr "Server health (localhost)"
load_env || true
if [[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]]; then
  curl -sf -u "$(opencode_auth)" "$(opencode_base_url)/api/info" && echo \
    || echo "health check failed"
else
  echo "OPENCODE_SERVER_PASSWORD unset — skip"
fi

hr "Hints"
cat <<'EOF'
- After CONFIG_REPO/CONFIG_REF changes → docker compose build --no-cache opencode && docker compose up -d opencode (never down -v)
- Full doctor after a freeze: run this script while the UI is glitching
EOF

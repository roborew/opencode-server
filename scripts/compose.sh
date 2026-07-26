#!/usr/bin/env bash
# Infisical-injected docker compose wrapper.
# Host .env holds Infisical bootstrap (+ non-secret local config). Secrets
# (TWINGATE_*, OPENCODE_SERVER_PASSWORD, API keys, etc.) come from Infisical
# at compose start via `infisical run` — never baked into the image, never
# permanently pulled into .env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=lib/opencode-api.sh
source "${SCRIPT_DIR}/lib/opencode-api.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/compose.sh [docker compose args...]

Wraps `docker compose` with Infisical secret injection so Compose interpolation
(e.g. TWINGATE_*) and services see project secrets without storing them in .env.

Examples:
  ./scripts/compose.sh up -d --build
  ./scripts/compose.sh up -d --force-recreate opencode
  ./scripts/compose.sh down

Requires:
  - Host Infisical CLI
      macOS:  brew install infisical/get-cli/infisical
      Ubuntu: curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | sudo -E bash
              sudo apt-get update && sudo apt-get install -y infisical
  - .env with INFISICAL_PROJECT_ID, INFISICAL_ENV, INFISICAL_DOMAIN or
    INFISICAL_API_URL, and INFISICAL_CLIENT_ID+SECRET (or INFISICAL_TOKEN)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  echo "compose.sh: .env missing — cp .env.example .env and set INFISICAL_* bootstrap" >&2
  exit 1
fi

load_env || {
  echo "compose.sh: failed to load .env" >&2
  exit 1
}

# Bind-mount parity: write OPENCODE_UID/GID before compose starts.
ensure_opencode_uid_gid >/dev/null || {
  echo "compose.sh: could not resolve OPENCODE_UID/GID" >&2
  exit 1
}
ensure_opencode_host_paths >/dev/null || true
# Reload so compose process sees upserted UID/GID/paths from .env.
load_env || true

if ! command -v infisical >/dev/null 2>&1; then
  echo "compose.sh: Infisical CLI not found on PATH." >&2
  echo "  macOS:  brew install infisical/get-cli/infisical" >&2
  echo "  Ubuntu: curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | sudo -E bash" >&2
  echo "          sudo apt-get update && sudo apt-get install -y infisical" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "compose.sh: docker not found on PATH" >&2
  exit 1
fi

project_id="${INFISICAL_PROJECT_ID:-}"
domain="${INFISICAL_DOMAIN:-${INFISICAL_API_URL:-}}"
infisical_env="${INFISICAL_ENV:-dev}"

if [[ -z "$project_id" || -z "$domain" ]]; then
  echo "compose.sh: set INFISICAL_PROJECT_ID and INFISICAL_DOMAIN (or INFISICAL_API_URL) in .env" >&2
  exit 1
fi

# Map short names used in this repo to Infisical CLI universal-auth env vars.
if [[ -n "${INFISICAL_CLIENT_ID:-}" && -z "${INFISICAL_UNIVERSAL_AUTH_CLIENT_ID:-}" ]]; then
  export INFISICAL_UNIVERSAL_AUTH_CLIENT_ID="${INFISICAL_CLIENT_ID}"
fi
if [[ -n "${INFISICAL_CLIENT_SECRET:-}" && -z "${INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET:-}" ]]; then
  export INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET="${INFISICAL_CLIENT_SECRET}"
fi

token="${INFISICAL_TOKEN:-}"
if [[ -z "$token" ]]; then
  client_id="${INFISICAL_UNIVERSAL_AUTH_CLIENT_ID:-}"
  client_secret="${INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET:-}"
  if [[ -z "$client_id" || -z "$client_secret" ]]; then
    echo "compose.sh: set INFISICAL_TOKEN or INFISICAL_CLIENT_ID+INFISICAL_CLIENT_SECRET in .env" >&2
    exit 1
  fi
  token="$(
    infisical login \
      --method=universal-auth \
      --client-id="$client_id" \
      --client-secret="$client_secret" \
      --domain="$domain" \
      --silent \
      --plain
  )" || {
    echo "compose.sh: infisical universal-auth login failed" >&2
    exit 1
  }
fi

export INFISICAL_TOKEN="$token"

# Host-local config must win over Infisical. Paths/UID differ per machine;
# Infisical often carries another host's OPENCODE_APPS_DIR and breaks mounts.
pin_apps="${OPENCODE_APPS_DIR:-}"
pin_wt="${OPENCODE_WORKTREES_DIR:-}"
pin_uid="${OPENCODE_UID:-}"
pin_gid="${OPENCODE_GID:-}"

echo "compose.sh: injecting Infisical secrets (env=${infisical_env}) into docker compose $*" >&2
echo "compose.sh: pinning host OPENCODE_APPS_DIR=${pin_apps} UID:GID=${pin_uid}:${pin_gid}" >&2
exec infisical run \
  --projectId="$project_id" \
  --env="$infisical_env" \
  --domain="$domain" \
  --token="$token" \
  -- env \
    OPENCODE_APPS_DIR="$pin_apps" \
    OPENCODE_WORKTREES_DIR="$pin_wt" \
    OPENCODE_UID="$pin_uid" \
    OPENCODE_GID="$pin_gid" \
    docker compose "$@"

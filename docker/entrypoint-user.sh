#!/usr/bin/env bash
# Second-stage entrypoint: runs as the runtime uid (compose's `user:`
# directive). All root-only setup (chowning volumes, Infisical login, OAuth
# callback proxy, git identity) is done by /usr/local/bin/opencode-entrypoint.sh
# before exec'ing this script via `runuser -u "#${RUNTIME_UID}"`.
set -euo pipefail

# Re-export anything that opencode-serve-guarded.sh / infisical / the CMD
# might rely on (already passed via `env` in the runuser invocation, but
# defensive defaults here).
export HOME="${HOME:-/home/opencode}"
export PATH="${PATH:-/home/opencode/.config/opencode/bin:/home/opencode/.opencode/bin:/home/opencode/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
export OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-/home/opencode/.config/opencode}"
export OPENCODE_OVERRIDE="${OPENCODE_OVERRIDE:-/home/opencode/overrides/opencode.server.json}"

run_cmd() {
  if [[ $# -ge 2 && "$1" == "opencode" && "$2" == "serve" ]]; then
    exec /usr/local/bin/opencode-serve-guarded.sh "$@"
  fi
  exec "$@"
}

# Skip Infisical entirely if disabled or not configured.
if [[ "${INFISICAL_USE_CLI:-}" == "false" || "${INFISICAL_USE_CLI:-}" == "0" || "${INFISICAL_RUNTIME:-}" == "0" ]]; then
  run_cmd "$@"
fi

domain="${INFISICAL_DOMAIN:-${INFISICAL_API_URL:-}}"
project_id="${INFISICAL_PROJECT_ID:-}"

if [[ -z "$project_id" || -z "$domain" ]]; then
  run_cmd "$@"
fi

token="${INFISICAL_TOKEN:-}"
if [[ -z "$token" ]]; then
  client_id="${INFISICAL_CLIENT_ID:-${INFISICAL_UNIVERSAL_AUTH_CLIENT_ID:-}}"
  client_secret="${INFISICAL_CLIENT_SECRET:-${INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET:-}}"
  if [[ -n "$client_id" && -n "$client_secret" ]]; then
    token="$(
      infisical login \
        --method=universal-auth \
        --client-id="$client_id" \
        --client-secret="$client_secret" \
        --domain="$domain" \
        --silent \
        --plain
    )" || {
      echo "opencode-entrypoint-user: infisical universal-auth login failed" >&2
      exit 1
    }
  else
    run_cmd "$@"
  fi
fi

export INFISICAL_TOKEN="$token"

# Infisical injects secrets then runs CMD; wrap serve the same way.
if [[ $# -ge 2 && "$1" == "opencode" && "$2" == "serve" ]]; then
  exec infisical run \
    --projectId="$project_id" \
    --env="${INFISICAL_ENV:-dev}" \
    --domain="$domain" \
    -- /usr/local/bin/opencode-serve-guarded.sh "$@"
fi

exec infisical run \
  --projectId="$project_id" \
  --env="${INFISICAL_ENV:-dev}" \
  --domain="$domain" \
  -- "$@"
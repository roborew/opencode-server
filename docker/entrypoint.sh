#!/usr/bin/env bash
# Infisical-first runtime env (deployed), with local compose .env fallback (development).
set -euo pipefail

export OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-/root/.config/opencode}"
export OPENCODE_OVERRIDE="${OPENCODE_OVERRIDE:-/root/overrides/opencode.server.json}"
export MILVUS_ADDRESS="${MILVUS_ADDRESS:-http://milvus-standalone:19530}"
export PATH="/root/.config/opencode/bin:/root/.opencode/bin:/root/.local/bin:${PATH}"

# Keep XDG inside the container (/var/opencode-xdg) so Docker MCP/sessions never
# share ~/.local/share/opencode with Desktop (that collision breaks claude-context).
# Host worktrees are bind-mounted onto $XDG_DATA_HOME/opencode/worktree and again
# at OPENCODE_WORKTREES_DIR (same-path) so checkouts live on the Mac.
VOLUME_DATA="${OPENCODE_VOLUME_DATA:-/var/lib/opencode-data}"
CONTAINER_XDG="${OPENCODE_CONTAINER_XDG:-/var/opencode-xdg}"
CONTAINER_DATA="${CONTAINER_XDG}/opencode"
CONTAINER_WT="${CONTAINER_DATA}/worktree"

link_volume_into_opencode_dir() {
  local opencode_dir="$1"
  local name f
  mkdir -p "$opencode_dir"
  for name in storage snapshot log repos tool-output .pnpm-store \
    auth.json mcp-auth.json account.json; do
    if [[ -e "${VOLUME_DATA}/${name}" ]]; then
      rm -rf "${opencode_dir}/${name}"
      ln -sfn "${VOLUME_DATA}/${name}" "${opencode_dir}/${name}"
    fi
  done
  for f in "${VOLUME_DATA}"/opencode.db "${VOLUME_DATA}"/opencode.db-wal "${VOLUME_DATA}"/opencode.db-shm; do
    [[ -e "$f" ]] || continue
    name="$(basename "$f")"
    rm -rf "${opencode_dir}/${name}"
    ln -sfn "$f" "${opencode_dir}/${name}"
  done
}

setup_container_data_layout() {
  local host_wt="${OPENCODE_WORKTREES_DIR:-}"

  export XDG_DATA_HOME="$CONTAINER_XDG"
  mkdir -p "$CONTAINER_DATA" "$VOLUME_DATA" "$CONTAINER_WT"
  if [[ -n "$host_wt" ]]; then
    host_wt="${host_wt%/}"
    mkdir -p "$host_wt"

    # Migrate worktrees off old volume / legacy locations onto the host mount (once).
    if [[ -d "${VOLUME_DATA}/worktree" && ! -L "${VOLUME_DATA}/worktree" ]]; then
      if [[ -n "$(ls -A "${VOLUME_DATA}/worktree" 2>/dev/null)" ]]; then
        echo "opencode-entrypoint: migrating volume worktrees → ${host_wt}" >&2
        cp -a "${VOLUME_DATA}/worktree/." "$host_wt/" 2>/dev/null || true
      fi
    fi
    if [[ -d /root/.local/share/opencode/worktree && ! -L /root/.local/share/opencode/worktree ]]; then
      if [[ -n "$(ls -A /root/.local/share/opencode/worktree 2>/dev/null)" ]]; then
        echo "opencode-entrypoint: migrating legacy /root worktrees → ${host_wt}" >&2
        cp -a /root/.local/share/opencode/worktree/. "$host_wt/" 2>/dev/null || true
      fi
    fi
  fi

  link_volume_into_opencode_dir "$CONTAINER_DATA"

  echo "opencode-entrypoint: XDG_DATA_HOME=${XDG_DATA_HOME}" >&2
  echo "opencode-entrypoint: worktrees=${CONTAINER_WT} host=${host_wt:-none} volume=${VOLUME_DATA}" >&2
}

setup_container_data_layout

# Deployment plugins (e.g. localhost → host.docker.internal URL rewrite)
install_override_plugins() {
  local src="/root/overrides/plugins"
  local dest="${OPENCODE_CONFIG_DIR}/plugins"
  if [[ ! -d "$src" ]]; then
    return 0
  fi
  mkdir -p "$dest"
  cp -f "$src"/*.js "$dest"/ 2>/dev/null || true
  rm -f "${dest}/dedupe-worktree-sandboxes.js"
  if compgen -G "$dest"/*.js >/dev/null; then
    echo "opencode-entrypoint: installed plugins from ${src} → ${dest}" >&2
  fi
}

install_override_plugins

# Apply deployment overrides into cloned opencode.json (OPENCODE_CONFIG env alone does not deep-merge MCP)
python3 /usr/local/bin/merge-config.py
unset OPENCODE_CONFIG

# gh CLI token auth when GH_TOKEN is set (no mounted ~/.config/gh)
if [[ -n "${GH_TOKEN:-}" ]]; then
  echo "${GH_TOKEN}" | gh auth login --with-token 2>/dev/null || true
fi

# CodeRabbit CLI token auth when CODERABBIT_API_KEY is set
if [[ -n "${CODERABBIT_API_KEY:-}" ]]; then
  coderabbit auth login --api-key "${CODERABBIT_API_KEY}" 2>/dev/null || true
fi

# MCP OAuth listens on 127.0.0.1:19876 inside the container. Host browsers (and
# SSH -L tunnels) hit the published eth0 port, so bridge eth IP → loopback.
start_oauth_callback_proxy() {
  local port="${OPENCODE_OAUTH_CALLBACK_PORT:-19876}"
  local eth_ip
  eth_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "$eth_ip" ]]; then
    echo "opencode-entrypoint: warn: no eth IP; MCP OAuth host callback proxy disabled" >&2
    return 0
  fi
  if ! command -v socat >/dev/null 2>&1; then
    echo "opencode-entrypoint: warn: socat missing; MCP OAuth host callback proxy disabled" >&2
    return 0
  fi
  setsid socat "TCP-LISTEN:${port},bind=${eth_ip},fork,reuseaddr" "TCP:127.0.0.1:${port}" \
    >/dev/null 2>&1 &
  echo "opencode-entrypoint: MCP OAuth callback proxy ${eth_ip}:${port} → 127.0.0.1:${port}" >&2
}

start_oauth_callback_proxy

# Rewrite git worktree metadata to host paths for Tower / local Git.
# Background so a slow apps scan never blocks serve startup.
if [[ -n "${OPENCODE_WORKTREES_DIR:-}${OPENCODE_APPS_DIR:-}" && -f /usr/local/bin/rewrite-worktree-gitdirs.py ]]; then
  export OPENCODE_CONTAINER_WORKTREE="$CONTAINER_WT"
  setsid python3 /usr/local/bin/rewrite-worktree-gitdirs.py >/dev/null 2>&1 &
fi

# Workspace create/delete needs this flag (otherwise startSync is a no-op and
# create times out waiting for workspace.status).
export OPENCODE_EXPERIMENTAL_WORKSPACES="${OPENCODE_EXPERIMENTAL_WORKSPACES:-true}"
export OPENCODE_CONTAINER_WORKTREE="$CONTAINER_WT"

run_cmd() {
  if [[ $# -ge 2 && "$1" == "opencode" && "$2" == "serve" ]]; then
    exec /usr/local/bin/opencode-serve-guarded.sh "$@"
  fi
  exec "$@"
}

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
      echo "opencode-entrypoint: infisical universal-auth login failed" >&2
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

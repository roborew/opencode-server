#!/usr/bin/env bash
# Infisical-first runtime env (deployed), with local compose .env fallback (development).
set -euo pipefail

export OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-/root/.config/opencode}"
export OPENCODE_OVERRIDE="${OPENCODE_OVERRIDE:-/root/overrides/opencode.server.json}"
export MILVUS_ADDRESS="${MILVUS_ADDRESS:-http://milvus-standalone:19530}"
export PATH="/root/.config/opencode/bin:/root/.opencode/bin:/root/.local/bin:${PATH}"

# Sessions/auth/db stay on the named volume. When OPENCODE_WORKTREES_DIR is set,
# XDG_DATA_HOME is derived so OpenCode creates worktrees at that host path
# ($XDG_DATA_HOME/opencode/worktree == OPENCODE_WORKTREES_DIR). Same-path binds
# make git metadata use host paths natively (Tower / local Git).
VOLUME_DATA="${OPENCODE_VOLUME_DATA:-/var/lib/opencode-data}"
FALLBACK_XDG="${OPENCODE_CONTAINER_XDG:-/var/opencode-xdg}"

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
  local opencode_dir

  mkdir -p "$VOLUME_DATA"

  if [[ -n "$host_wt" ]]; then
    host_wt="${host_wt%/}"
    if [[ "$(basename "$host_wt")" != "worktree" || "$(basename "$(dirname "$host_wt")")" != "opencode" ]]; then
      echo "opencode-entrypoint: error: OPENCODE_WORKTREES_DIR must end with /opencode/worktree (got: ${host_wt})" >&2
      exit 1
    fi
    export XDG_DATA_HOME="$(dirname "$(dirname "$host_wt")")"
    opencode_dir="${XDG_DATA_HOME}/opencode"
    mkdir -p "$host_wt" "$opencode_dir"

    # Migrate worktrees off old locations onto the host mount (once).
    if [[ -d "${VOLUME_DATA}/worktree" && ! -L "${VOLUME_DATA}/worktree" ]]; then
      if [[ -n "$(ls -A "${VOLUME_DATA}/worktree" 2>/dev/null)" ]]; then
        echo "opencode-entrypoint: migrating volume worktrees → ${host_wt}" >&2
        cp -a "${VOLUME_DATA}/worktree/." "$host_wt/" 2>/dev/null || true
      fi
    fi
    if [[ -d /var/opencode-xdg/opencode/worktree && ! -L /var/opencode-xdg/opencode/worktree ]]; then
      if [[ -n "$(ls -A /var/opencode-xdg/opencode/worktree 2>/dev/null)" ]]; then
        echo "opencode-entrypoint: migrating /var/opencode-xdg worktrees → ${host_wt}" >&2
        cp -a /var/opencode-xdg/opencode/worktree/. "$host_wt/" 2>/dev/null || true
      fi
    fi
    if [[ -d /root/.local/share/opencode/worktree && ! -L /root/.local/share/opencode/worktree ]]; then
      if [[ -n "$(ls -A /root/.local/share/opencode/worktree 2>/dev/null)" ]]; then
        echo "opencode-entrypoint: migrating legacy /root worktrees → ${host_wt}" >&2
        cp -a /root/.local/share/opencode/worktree/. "$host_wt/" 2>/dev/null || true
      fi
    fi
  else
    export XDG_DATA_HOME="$FALLBACK_XDG"
    opencode_dir="${XDG_DATA_HOME}/opencode"
    mkdir -p "${opencode_dir}/worktree"
  fi

  link_volume_into_opencode_dir "$opencode_dir"

  echo "opencode-entrypoint: XDG_DATA_HOME=${XDG_DATA_HOME}" >&2
  echo "opencode-entrypoint: worktrees=${OPENCODE_WORKTREES_DIR:-${opencode_dir}/worktree} volume=${VOLUME_DATA}" >&2
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
  # Drop legacy dedupe plugin if a previous image left it in the config dir
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
# Bind the container eth IP only — not 0.0.0.0 — so OpenCode can still bind loopback.
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
  # Survive entrypoint `exec` (otherwise bash may SIGHUP the child).
  setsid socat "TCP-LISTEN:${port},bind=${eth_ip},fork,reuseaddr" "TCP:127.0.0.1:${port}" \
    >/dev/null 2>&1 &
  echo "opencode-entrypoint: MCP OAuth callback proxy ${eth_ip}:${port} → 127.0.0.1:${port}" >&2
}

start_oauth_callback_proxy

run_cmd() {
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

exec infisical run \
  --projectId="$project_id" \
  --env="${INFISICAL_ENV:-dev}" \
  --domain="$domain" \
  -- "$@"

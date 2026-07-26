#!/usr/bin/env bash
# Root-first entrypoint: chown volumes to OPENCODE_UID:GID, then drop privileges
# and run the rest as the host user (bind-mount parity on Mac/Linux).
set -euo pipefail

OPENCODE_UID="${OPENCODE_UID:-1000}"
OPENCODE_GID="${OPENCODE_GID:-1000}"

# --- root phase: fix ownership, then re-exec as the runtime user -------------
if [[ "$(id -u)" -eq 0 ]]; then
  fix_as_root() {
    local path="$1"
    mkdir -p "$path" 2>/dev/null || true
    [[ -e "$path" ]] || return 0
    chown -R "${OPENCODE_UID}:${OPENCODE_GID}" "$path" 2>/dev/null || true
  }
  # Named volume only — safe to recurse.
  fix_as_root /var/lib/opencode-data
  fix_as_root /home/opencode
  # XDG dir itself (not -R): worktree is a host bind mount and can be huge;
  # recursive chown there blocks startup for minutes.
  mkdir -p /var/opencode-xdg/opencode /var/opencode-xdg/sandboxes
  chown "${OPENCODE_UID}:${OPENCODE_GID}" \
    /var/opencode-xdg /var/opencode-xdg/opencode /var/opencode-xdg/sandboxes \
    2>/dev/null || true
  # Do not chown OPENCODE_WORKTREES_DIR / OPENCODE_APPS_DIR — host-owned binds.

  # macOS host GIDs (e.g. staff=20) may not exist in the Ubuntu image's
  # group database, and `runuser -g "#N"` is unreliable. Ensure the GID
  # exists, then drop with setpriv (no /etc/passwd entry required).
  if ! getent group "${OPENCODE_GID}" >/dev/null 2>&1; then
    groupadd -o -g "${OPENCODE_GID}" "hostgid${OPENCODE_GID}" 2>/dev/null || true
  fi
  echo "opencode-entrypoint: dropping to uid=${OPENCODE_UID} gid=${OPENCODE_GID}" >&2
  if command -v setpriv >/dev/null 2>&1; then
    exec setpriv --reuid="${OPENCODE_UID}" --regid="${OPENCODE_GID}" --clear-groups -- "$0" "$@"
  fi
  gname="$(getent group "${OPENCODE_GID}" | cut -d: -f1 || true)"
  if [[ -n "$gname" ]]; then
    exec runuser -u "#${OPENCODE_UID}" -g "$gname" -- "$0" "$@"
  fi
  exec runuser -u "#${OPENCODE_UID}" -- "$0" "$@"
fi

# --- runtime user (OPENCODE_UID) from here -----------------------------------
export OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-/home/opencode/.config/opencode}"
export OPENCODE_OVERRIDE="${OPENCODE_OVERRIDE:-/home/opencode/overrides/opencode.server.json}"
export MILVUS_ADDRESS="${MILVUS_ADDRESS:-http://milvus-standalone:19530}"
export PATH="/home/opencode/.config/opencode/bin:/home/opencode/.opencode/bin:/home/opencode/.local/bin:${PATH}"
export HOME="/home/opencode"

# Keep XDG inside the container (/var/opencode-xdg) so Docker MCP/sessions never
# share ~/.local/share/opencode with Desktop (that collision breaks claude-context).
# Host worktrees are bind-mounted onto $XDG_DATA_HOME/opencode/worktree and again
# at OPENCODE_WORKTREES_DIR (same-path) so checkouts live on the Mac.
VOLUME_DATA="${OPENCODE_VOLUME_DATA:-/var/lib/opencode-data}"
CONTAINER_XDG="${OPENCODE_CONTAINER_XDG:-/var/opencode-xdg}"
CONTAINER_DATA="${CONTAINER_XDG}/opencode"
CONTAINER_WT="${CONTAINER_DATA}/worktree"

# Always back Docker OpenCode state with the named volume so
# `docker compose down -v` actually wipes DB/auth/sessions.
# Previously we only linked when the volume already had files; OpenCode then
# created opencode.db on the container layer and "fresh volume" left it intact.
link_volume_into_opencode_dir() {
  local opencode_dir="$1"
  local name dest vol

  mkdir -p "$opencode_dir" "$VOLUME_DATA"

  _migrate_xdg_to_volume() {
    dest="$1"
    vol="$2"
    if [[ -e "$dest" && ! -L "$dest" ]]; then
      if [[ ! -e "$vol" ]]; then
        mv "$dest" "$vol"
      else
        rm -rf "$dest"
      fi
    fi
  }

  for name in storage snapshot log repos tool-output .pnpm-store; do
    mkdir -p "${VOLUME_DATA}/${name}"
    _migrate_xdg_to_volume "${opencode_dir}/${name}" "${VOLUME_DATA}/${name}"
    rm -rf "${opencode_dir}/${name}"
    ln -sfn "${VOLUME_DATA}/${name}" "${opencode_dir}/${name}"
  done

  for name in auth.json mcp-auth.json account.json; do
    _migrate_xdg_to_volume "${opencode_dir}/${name}" "${VOLUME_DATA}/${name}"
    rm -rf "${opencode_dir}/${name}"
    ln -sfn "${VOLUME_DATA}/${name}" "${opencode_dir}/${name}"
  done

  # Pre-link db + wal/shm so SQLite creates them on the volume (via symlink).
  for name in opencode.db opencode.db-wal opencode.db-shm; do
    _migrate_xdg_to_volume "${opencode_dir}/${name}" "${VOLUME_DATA}/${name}"
    rm -rf "${opencode_dir}/${name}"
    ln -sfn "${VOLUME_DATA}/${name}" "${opencode_dir}/${name}"
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
    # Legacy /root path — only readable when root; only created in older
    # images that ran as root. Skip if we can't read it.
    if [[ -r /root/.local/share/opencode/worktree ]] && [[ ! -L /root/.local/share/opencode/worktree ]]; then
      if [[ -n "$(ls -A /root/.local/share/opencode/worktree 2>/dev/null)" ]]; then
        echo "opencode-entrypoint: migrating legacy /root worktrees → ${host_wt}" >&2
        cp -a /root/.local/share/opencode/worktree/. "$host_wt/" 2>/dev/null || true
      fi
    fi
  fi

  link_volume_into_opencode_dir "$CONTAINER_DATA"

  # Sibling sandbox state (JSON) when OPENCODE_SANDBOX_ENABLED=1
  mkdir -p "${CONTAINER_XDG}/sandboxes"

  echo "opencode-entrypoint: XDG_DATA_HOME=${XDG_DATA_HOME}" >&2
  echo "opencode-entrypoint: worktrees=${CONTAINER_WT} host=${host_wt:-none} volume=${VOLUME_DATA}" >&2
}

# Deployment plugins (e.g. localhost → host.docker.internal URL rewrite)
install_override_plugins() {
  local src="/home/opencode/overrides/plugins"
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

setup_container_data_layout

install_override_plugins

# Apply deployment overrides into cloned opencode.json (OPENCODE_CONFIG env alone does not deep-merge MCP)
python3 /usr/local/bin/merge-config.py
unset OPENCODE_CONFIG

# gh CLI token auth when GH_TOKEN is set (no mounted ~/.config/gh).
mkdir -p /home/opencode/.config/gh
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

# Git author/committer for agent commits (GIT_USER_* or GIT_AUTHOR_* from .env / Infisical).
# Also re-applied in opencode-serve-guarded.sh after Infisical inject.
# shellcheck source=/dev/null
source /usr/local/bin/configure-git-identity.sh
configure_git_identity

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
    # Login as the runtime user; session lands under HOME=/home/opencode.
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

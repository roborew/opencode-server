#!/bin/sh
# code-index entrypoint: configure codebase-memory-mcp, then serve it over
# Streamable HTTP (/mcp) through mcp-proxy, with a mandatory bearer token.
set -eu

die() { echo "code-index: $*" >&2; exit 1; }

# Bearer token: required, never logged, kept out of process arguments.
[ -n "${CODE_INDEX_TOKEN:-}" ] || die "CODE_INDEX_TOKEN is not set"
[ "${#CODE_INDEX_TOKEN}" -ge 32 ] || die "CODE_INDEX_TOKEN must be at least 32 characters"
MCP_PROXY_AUTH_TOKEN="$CODE_INDEX_TOKEN"
export MCP_PROXY_AUTH_TOKEN
unset CODE_INDEX_TOKEN

: "${CBM_CACHE_DIR:=/var/lib/code-index}"
export CBM_CACHE_DIR
[ -w "$CBM_CACHE_DIR" ] || die "cache dir ${CBM_CACHE_DIR} is not writable by uid $(id -u)"

# Settings persist in the cache volume; reapply on every start so the image
# defines them, not whatever an earlier run left behind.
codebase-memory-mcp config set ui_enabled false >/dev/null   # no extra listener on :9749
codebase-memory-mcp config set auto_index false >/dev/null   # index on request (ADR 0017)

port=8080   # fixed: the image HEALTHCHECK probes it
# Host authorities other services use to reach us (DNS-rebinding guard).
set -- --allowed-host "code-index:${port}" --allowed-host code-index
for h in ${CODE_INDEX_ALLOWED_HOSTS:-}; do
  set -- "$@" --allowed-host "$h"
done

# Refresh changed projects and prune removed worktrees (ADR 0017). It waits one
# interval before its first cycle, so the proxy is up by then.
python3 -I /usr/local/lib/code-index/refresh.py &

exec mcp-proxy \
  --host 0.0.0.0 --port "$port" \
  --initialization-timeout 60 \
  --pass-environment \
  "$@" \
  codebase-memory-mcp

#!/usr/bin/env bash
# Host DNS + project deep links after project sync.
# Does not write OpenCode Desktop Application Support state.
# shellcheck source=opencode-api.sh
set -euo pipefail

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=opencode-api.sh
source "${SCRIPT_LIB_DIR}/opencode-api.sh"

OPENCODE_FQDN="${OPENCODE_FQDN:-opencode.local}"

# Map FQDN → 127.0.0.1 on the Docker host so browsers/clients on that host can
# use the same hostname as Twingate remotes (http://OPENCODE_FQDN:PORT).
ensure_hosts_entry() {
  local host="${OPENCODE_FQDN}"
  local line="127.0.0.1 ${host}"

  echo
  echo "Host DNS (${host})"
  echo "  Why: Twingate remotes resolve ${host} via the connector."
  echo "  On the Docker host, that name often fails in apps even when"
  echo "  Twingate is connected. Mapping ${host} → 127.0.0.1 uses the published"
  echo "  Docker port while keeping the same URL as remotes: $(opencode_public_url)"

  if grep -Eq "^[[:space:]]*127\\.0\\.0\\.1[[:space:]].*[[:space:]]${host}([[:space:]]|\$)" /etc/hosts \
    || grep -Eq "^[[:space:]]*127\\.0\\.0\\.1[[:space:]]+${host}([[:space:]]|\$)" /etc/hosts; then
    echo "  [ok]   /etc/hosts already maps ${host} → 127.0.0.1"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "  [dry-run] would append: ${line}"
    return 0
  fi

  if [[ "${YES:-0}" != "1" ]]; then
    read -r -p "  Add hosts entry now (requires sudo)? [Y/n] " confirm
    if [[ "${confirm}" =~ ^[Nn]$ ]]; then
      echo "  [skip] hosts entry — add manually: sudo sh -c 'echo ${line} >> /etc/hosts'"
      return 0
    fi
  fi

  if echo "${line}" | sudo tee -a /etc/hosts >/dev/null; then
    echo "  [ok]   appended to /etc/hosts: ${line}"
  else
    echo "  [fail] could not update /etc/hosts (sudo denied?)" >&2
    echo "         → sudo sh -c 'echo ${line} >> /etc/hosts'" >&2
    return 1
  fi
}

# Print deep links so any web client can open registered projects without
# typing paths. Does not touch OpenCode.app.
print_project_open_links() {
  local -a dirs=("$@")
  local url
  url="$(opencode_public_url)"

  echo
  echo "Open projects in the web UI"
  echo "  Server: ${url}"
  echo "  Use host paths under OPENCODE_APPS_DIR (same-path mount)."
  if [[ ${#dirs[@]} -eq 0 ]]; then
    echo "  (no projects in desired set)"
    return 0
  fi

  python3 - "$url" "${dirs[@]}" <<'PY'
import base64, sys
url = sys.argv[1].rstrip("/")
for d in sys.argv[2:]:
    token = base64.b64encode(d.encode()).decode()
    print(f"  {url}/{token}")
PY
}

run_client_bootstrap() {
  local -a dirs=("$@")
  ensure_hosts_entry || true
  print_project_open_links "${dirs[@]}"
}

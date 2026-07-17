#!/usr/bin/env bash
# Post-compose setup: preflight + amend project set + host DNS / session cleanup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/opencode-api.sh
source "${SCRIPT_DIR}/lib/opencode-api.sh"
# shellcheck source=lib/preflight.sh
source "${SCRIPT_DIR}/lib/preflight.sh"
# shellcheck source=lib/select.sh
source "${SCRIPT_DIR}/lib/select.sh"
# shellcheck source=lib/client-bootstrap.sh
source "${SCRIPT_DIR}/lib/client-bootstrap.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/setup.sh [command] [options]

Commands:
  (default)           Preflight, then amend project set + client bootstrap
  preflight           Run preflight checks only
  projects local      Amend local /workspace/apps project set (register/deregister)
  projects github     Clone org repos, then amend project set
  bootstrap           Hosts entry + host-path session cleanup + print open links

Options:
  --skip-preflight    Skip preflight before project setup
  --force             Continue project setup after preflight failures
  --all               Desired set = all discovered projects (no prompt)
  --dry-run           Show actions without changing the server
  --yes               Skip confirmation prompts
  --host URL          OpenCode API base URL (default http://127.0.0.1:PORT)
  --json              JSON preflight summary
  --include-archived  Include archived GitHub repos (github mode)
  --skip-bootstrap    Skip hosts/session cleanup after sync
  -h, --help          Show this help

Each projects run (unless --skip-bootstrap):
  1) You choose the desired project set (re-run amends: add/remove)
  2) Registers missing repos; deregisters removed ones (deletes their sessions)
  3) /etc/hosts → OPENCODE_FQDN (sudo) so the Docker host can use the FQDN
  4) Cleans stray /Users/... sessions on the Docker server
  5) Prints web deep links for each /workspace project
     (does not touch OpenCode.app — attach that client later yourself)

Examples:
  ./scripts/setup.sh
  ./scripts/setup.sh projects local
  ./scripts/setup.sh projects local --all --yes
  ./scripts/setup.sh bootstrap --yes
EOF
}

SKIP_PREFLIGHT=0
SKIP_BOOTSTRAP=0
FORCE=0
SELECT_ALL=0
DRY_RUN=0
YES=0
INCLUDE_ARCHIVED=0
COMMAND=""
PROJECT_MODE=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      preflight) COMMAND="preflight"; shift ;;
      bootstrap) COMMAND="bootstrap"; shift ;;
      projects)
        COMMAND="projects"
        PROJECT_MODE="${2:-}"
        [[ -n "$PROJECT_MODE" ]] && shift
        shift
        ;;
      --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
      --skip-bootstrap) SKIP_BOOTSTRAP=1; shift ;;
      --force) FORCE=1; shift ;;
      --all) SELECT_ALL=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --yes) YES=1; shift ;;
      --host) OPENCODE_HOST="$2"; shift 2 ;;
      --json) PREFLIGHT_JSON_MODE=1; shift ;;
      --include-archived) INCLUDE_ARCHIVED=1; shift ;;
      -h|--help) usage; exit 0 ;;
      local|github)
        if [[ -z "$COMMAND" ]]; then
          COMMAND="projects"
          PROJECT_MODE="$1"
        fi
        shift
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

workspace_projects_from_server() {
  list_registered_workspace_projects
}

prompt_project_mode() {
  if [[ -n "$PROJECT_MODE" ]]; then
    return
  fi
  echo
  echo "Project setup mode:"
  echo "  1) local  — amend git repos from mounted /workspace/apps"
  echo "  2) github — clone repos from GH_ORG, then amend project set"
  read -r -p "Choose [1/2] (default 1): " choice
  case "${choice:-1}" in
    1|local|l) PROJECT_MODE="local" ;;
    2|github|g) PROJECT_MODE="github" ;;
    *)
      echo "Invalid choice." >&2
      exit 1
      ;;
  esac
}

# Sets DESIRED_DIRS to absolute /workspace paths for the chosen set.
prompt_desired_local_set() {
  local -a roots=()
  while IFS= read -r root; do
    [[ -n "$root" ]] && roots+=("$root")
  done < <(discover_local_git_roots)

  if [[ ${#roots[@]} -eq 0 ]]; then
    echo "No git repositories found under ${WORKSPACE_ROOT}." >&2
    exit 1
  fi

  local -a display=() registered_rels=()
  local root
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    registered_rels+=("$(relative_workspace_path "$root")")
  done < <(list_registered_workspace_projects)

  for root in "${roots[@]}"; do
    display+=("$(relative_workspace_path "$root")")
  done

  PRESELECTED_ITEMS=("${registered_rels[@]}")
  if ! select_items "Desired projects (amend set):" "${display[@]}"; then
    exit 1
  fi

  DESIRED_DIRS=()
  local rel
  for rel in "${SELECTED_ITEMS[@]}"; do
    DESIRED_DIRS+=("${WORKSPACE_ROOT}/${rel}")
  done
}

run_projects_local() {
  if ! container_running; then
    echo "Container ${CONTAINER_NAME} is not running." >&2
    exit 1
  fi
  load_env || true

  echo
  echo "Discovering git repos under ${WORKSPACE_ROOT}..."
  local -a DESIRED_DIRS=()
  prompt_desired_local_set
  sync_projects "${DESIRED_DIRS[@]}"
}

run_projects_github() {
  if ! container_running; then
    echo "Container ${CONTAINER_NAME} is not running." >&2
    exit 1
  fi
  load_env || true

  if [[ -z "${GH_TOKEN:-}" || -z "${GH_ORG:-}" ]]; then
    echo "GH_TOKEN and GH_ORG are required for github mode." >&2
    exit 1
  fi

  echo
  echo "Listing repos in org ${GH_ORG}..."
  local json
  json="$(docker_exec gh repo list "$GH_ORG" --limit 1000 --json name,url,isArchived 2>/dev/null)" || {
    echo "Failed to list repos for org ${GH_ORG}." >&2
    exit 1
  }

  local -a names=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && names+=("$name")
  done < <(echo "$json" | python3 -c "
import json, sys
include_archived = sys.argv[1] == '1'
data = json.load(sys.stdin)
for r in sorted(data, key=lambda x: x['name'].lower()):
    if r.get('isArchived') and not include_archived:
        continue
    print(r['name'])
" "$INCLUDE_ARCHIVED")

  if [[ ${#names[@]} -eq 0 ]]; then
    echo "No repositories found in ${GH_ORG}." >&2
    exit 1
  fi

  local -a registered_names=()
  local wt
  while IFS= read -r wt; do
    [[ -n "$wt" ]] && registered_names+=("$(basename "$wt")")
  done < <(list_registered_workspace_projects)

  PRESELECTED_ITEMS=("${registered_names[@]}")
  if ! select_items "Desired repos (clone if needed, amend set):" "${names[@]}"; then
    exit 1
  fi

  local -a desired=()
  local name target
  for name in "${SELECTED_ITEMS[@]}"; do
    target="${WORKSPACE_ROOT}/${name}"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[dry-run] would ensure clone ${GH_ORG}/${name} -> ${target}"
      desired+=("$target")
      continue
    fi
    if docker_exec test -d "${target}/.git" 2>/dev/null; then
      echo "Updating ${name}..."
      docker_exec git -C "$target" fetch --prune 2>/dev/null || true
    else
      echo "Cloning ${name}..."
      docker_exec gh repo clone "${GH_ORG}/${name}" "$target"
    fi
    desired+=("$target")
  done

  sync_projects "${desired[@]}"
}

_path_in_list() {
  local needle="$1"
  shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

# Sync server (+ hosts / session cleanup) to exactly the desired /workspace dirs.
sync_projects() {
  local -a desired=("$@")
  local -a current=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && current+=("$line")
  done < <(list_registered_workspace_projects)

  local -a to_add=() to_remove=()
  local d
  for d in "${desired[@]}"; do
    _path_in_list "$d" "${current[@]}" || to_add+=("$d")
  done
  for d in "${current[@]}"; do
    _path_in_list "$d" "${desired[@]}" || to_remove+=("$d")
  done

  local keep_count=$(( ${#desired[@]} - ${#to_add[@]} ))
  if (( keep_count < 0 )); then keep_count=0; fi

  echo
  echo "Project sync plan:"
  echo "  keep:   ${keep_count}"
  echo "  add:    ${#to_add[@]}"
  echo "  remove: ${#to_remove[@]}"
  if [[ ${#to_add[@]} -gt 0 ]]; then
    local x
    for x in "${to_add[@]}"; do echo "    + ${x}"; done
  fi
  if [[ ${#to_remove[@]} -gt 0 ]]; then
    local x
    for x in "${to_remove[@]}"; do echo "    - ${x}"; done
  fi

  if [[ ${#to_add[@]} -eq 0 && ${#to_remove[@]} -eq 0 ]]; then
    echo "  (no server changes — will still run hosts/session cleanup)"
  elif [[ "$YES" != "1" && "$DRY_RUN" != "1" ]]; then
    read -r -p "Apply sync? [Y/n] " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
      echo "Aborted."
      exit 0
    fi
  fi

  local result ok_add=0 skip_add=0 fail_add=0 ok_rm=0 fail_rm=0

  if [[ ${#to_remove[@]} -gt 0 ]]; then
    echo
    echo "Deregistering..."
    for d in "${to_remove[@]}"; do
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "  [dry-run] deregister ${d}"
        continue
      fi
      if result="$(deregister_project "$d" 2>&1)"; then
        echo "  removed sessions for ${d}"
        ok_rm=$((ok_rm + 1))
      else
        echo "  failed deregister ${d}: ${result}" >&2
        fail_rm=$((fail_rm + 1))
      fi
    done
  fi

  if [[ ${#to_add[@]} -gt 0 ]]; then
    echo
    echo "Registering..."
    for d in "${to_add[@]}"; do
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "  [dry-run] register ${d}"
        continue
      fi
      if result="$(register_project "$d" "$(basename "$d")" 2>&1)"; then
        case "$result" in
          ok)   echo "  registered ${d}"; ok_add=$((ok_add + 1)) ;;
          skip) echo "  skipped ${d}"; skip_add=$((skip_add + 1)) ;;
          *)    echo "  ${d}: ${result}" ;;
        esac
      else
        echo "  failed ${d}" >&2
        fail_add=$((fail_add + 1))
      fi
    done
  fi

  echo
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "Dry run complete."
  else
    echo "Sync done: +${ok_add} registered (${skip_add} skip), -${ok_rm} deregistered, fails add=${fail_add} rm=${fail_rm}."
    echo
    echo "Projects on server:"
    list_projects_json | python3 -m json.tool 2>/dev/null || list_projects_json
  fi

  if [[ "$SKIP_BOOTSTRAP" == "1" ]]; then
    echo
    echo "Skipped client bootstrap (--skip-bootstrap)."
    return
  fi

  run_client_bootstrap "${desired[@]}"
}

run_bootstrap_only() {
  load_env || true
  if [[ "$SKIP_PREFLIGHT" != "1" ]]; then
    wait_for_health 5 || echo "Warning: OpenCode API not reachable; session cleanup may fail." >&2
  fi
  local -a dirs=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && dirs+=("$line")
  done < <(workspace_projects_from_server)
  if [[ ${#dirs[@]} -eq 0 ]]; then
    echo "No /workspace projects registered yet. Run: ./scripts/setup.sh projects local" >&2
    exit 1
  fi
  echo "Bootstrapping ${#dirs[@]} registered /workspace project(s)..."
  run_client_bootstrap "${dirs[@]}"
}

main() {
  parse_args "$@"

  cd "$REPO_ROOT"

  case "${COMMAND:-}" in
    preflight)
      run_preflight
      exit $?
      ;;
    bootstrap)
      run_bootstrap_only
      ;;
    projects)
      if [[ "$PROJECT_MODE" != "local" && "$PROJECT_MODE" != "github" ]]; then
        echo "projects requires local or github mode." >&2
        usage >&2
        exit 1
      fi
      if [[ "$SKIP_PREFLIGHT" != "1" ]]; then
        run_preflight || [[ "$FORCE" == "1" ]] || exit 1
      fi
      if [[ "$PROJECT_MODE" == "local" ]]; then
        run_projects_local
      else
        run_projects_github
      fi
      ;;
    "")
      if [[ "$SKIP_PREFLIGHT" != "1" ]]; then
        run_preflight || [[ "$FORCE" == "1" ]] || exit 1
      fi
      prompt_project_mode
      if [[ "$PROJECT_MODE" == "local" ]]; then
        run_projects_local
      else
        run_projects_github
      fi
      ;;
    *)
      echo "Unknown command: ${COMMAND}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"

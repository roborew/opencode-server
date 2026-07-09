#!/usr/bin/env bash
# Post-compose setup: preflight + project registration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/opencode-api.sh
source "${SCRIPT_DIR}/lib/opencode-api.sh"
# shellcheck source=lib/preflight.sh
source "${SCRIPT_DIR}/lib/preflight.sh"
# shellcheck source=lib/select.sh
source "${SCRIPT_DIR}/lib/select.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/setup.sh [command] [options]

Commands:
  (default)           Run preflight, then interactive project setup
  preflight           Run preflight checks only
  projects local      Register git repos from mounted /workspace/apps
  projects github     Clone org repos from GH_ORG, then register

Options:
  --skip-preflight    Skip preflight before project setup
  --force             Continue project setup after preflight failures
  --all               Select all discovered projects/repos
  --dry-run           Show actions without registering/cloning
  --yes               Skip confirmation prompts
  --host URL          OpenCode base URL (default http://127.0.0.1:OPENCODE_PUBLISH_PORT)
  --json              JSON preflight summary
  --include-archived  Include archived GitHub repos (github mode)
  -h, --help          Show this help

Examples:
  ./scripts/setup.sh
  ./scripts/setup.sh preflight
  ./scripts/setup.sh projects local --all
  ./scripts/setup.sh projects github --all --force
EOF
}

SKIP_PREFLIGHT=0
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
      projects)
        COMMAND="projects"
        PROJECT_MODE="${2:-}"
        [[ -n "$PROJECT_MODE" ]] && shift
        shift
        ;;
      --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
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

prompt_project_mode() {
  if [[ -n "$PROJECT_MODE" ]]; then
    return
  fi
  echo
  echo "Project setup mode:"
  echo "  1) local  — register git repos from mounted /workspace/apps"
  echo "  2) github — clone repos from GH_ORG, then register"
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

run_projects_local() {
  if ! container_running; then
    echo "Container ${CONTAINER_NAME} is not running." >&2
    exit 1
  fi
  load_env || true

  echo
  echo "Discovering git repos under ${WORKSPACE_ROOT}..."
  local -a roots=()
  while IFS= read -r root; do
    [[ -n "$root" ]] && roots+=("$root")
  done < <(discover_local_git_roots)

  if [[ ${#roots[@]} -eq 0 ]]; then
    echo "No git repositories found under ${WORKSPACE_ROOT}." >&2
    exit 1
  fi

  local -a display=()
  local root rel
  for root in "${roots[@]}"; do
    rel="$(relative_workspace_path "$root")"
    display+=("$rel")
  done

  if ! select_items "Select repos to register:" "${display[@]}"; then
    exit 1
  fi

  local -a to_register=()
  for rel in "${SELECTED_ITEMS[@]}"; do
    to_register+=("${WORKSPACE_ROOT}/${rel}")
  done

  register_projects "${to_register[@]}"
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

  if ! select_items "Select repos to clone and register:" "${names[@]}"; then
    exit 1
  fi

  local -a to_register=()
  local name target
  for name in "${SELECTED_ITEMS[@]}"; do
    target="${WORKSPACE_ROOT}/${name}"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[dry-run] would clone/update ${GH_ORG}/${name} -> ${target}"
      to_register+=("$target")
      continue
    fi
    if docker_exec test -d "${target}/.git" 2>/dev/null; then
      echo "Updating ${name}..."
      docker_exec git -C "$target" fetch --prune 2>/dev/null || true
    else
      echo "Cloning ${name}..."
      docker_exec gh repo clone "${GH_ORG}/${name}" "$target"
    fi
    to_register+=("$target")
  done

  register_projects "${to_register[@]}"
}

register_projects() {
  local -a dirs=("$@")
  if [[ ${#dirs[@]} -eq 0 ]]; then
    echo "Nothing to register." >&2
    exit 1
  fi

  if [[ "$YES" != "1" && "$DRY_RUN" != "1" ]]; then
    echo
    echo "Will register ${#dirs[@]} project(s) with OpenCode server."
    read -r -p "Continue? [Y/n] " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
      echo "Aborted."
      exit 0
    fi
  fi

  local dir title result ok=0 skip=0 fail=0
  echo
  for dir in "${dirs[@]}"; do
    title="$(basename "$dir")"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[dry-run] register ${dir}"
      continue
    fi
    if result="$(register_project "$dir" "$title" 2>&1)"; then
      case "$result" in
        ok)   echo "  registered ${dir}"; ok=$((ok + 1)) ;;
        skip) echo "  skipped (already registered) ${dir}"; skip=$((skip + 1)) ;;
        *)    echo "  ${dir}: ${result}" ;;
      esac
    else
      echo "  failed ${dir}" >&2
      fail=$((fail + 1))
    fi
  done

  echo
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "Dry run complete."
    return
  fi
  echo "Done: ${ok} registered, ${skip} skipped, ${fail} failed."
  echo
  echo "Projects on server:"
  list_projects_json | python3 -m json.tool 2>/dev/null || list_projects_json
}

main() {
  parse_args "$@"

  cd "$REPO_ROOT"

  case "${COMMAND:-}" in
    preflight)
      run_preflight
      exit $?
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

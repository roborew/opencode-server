#!/usr/bin/env bash
# Focused regression coverage for setup's branch, project sync, and repo-env flow.
# Functions and variables below are consumed by sourced scripts / test doubles.
# shellcheck disable=SC1091,SC2034,SC2329
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

fail() {
  echo "    $*" >&2
  return 1
}

assert_file_exists() {
  [[ -e "$1" ]] || fail "expected file to exist: $1"
}

assert_file_missing() {
  [[ ! -e "$1" ]] || fail "expected file not to exist: $1"
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: ${needle}"$'\n'"actual: ${haystack}"
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: ${needle}"$'\n'"actual: ${haystack}"
}

run_test() {
  local name="$1"
  shift
  if [[ -n "${TEST_FILTER:-}" && "$name" != *"${TEST_FILTER}"* ]]; then
    return 0
  fi
  echo "TEST ${name}"
  if ( "$@" ); then
    PASS=$((PASS + 1))
    echo "  PASS"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL"
  fi
}

test_main_is_the_default_work_branch() {
  export SETUP_TEST_NO_MAIN=1
  # shellcheck source=../scripts/setup.sh
  source "${REPO_ROOT}/scripts/setup.sh"
  unset OPENCODE_WORK_BRANCH
  OPENCODE_UID=1000
  OPENCODE_GID=1000
  local calls="${TMP_ROOT}/git-calls"
  : >"$calls"
  docker_exec_git() {
    shift # repo path; the real helper passes it to git -C
    printf '%s\n' "$*" >>"$calls"
    case "$*" in
      "rev-parse --is-inside-work-tree") return 0 ;;
      "fetch --prune origin") return 0 ;;
      "show-ref --verify --quiet refs/remotes/origin/main") return 0 ;;
      "branch --show-current") echo "main"; return 0 ;;
      "merge --ff-only origin/main") return 0 ;;
      *) return 1 ;;
    esac
  }
  local output
  output="$(ensure_work_branch "/home/robin/apps/example" 2>&1)" || return 1
  assert_contains "$output" "on main" || return 1
  assert_not_contains "$output" "develop" || return 1
  assert_not_contains "$(cat "$calls")" "develop" || return 1
}

 test_github_clone_uses_the_remote_default_branch() {
  export SETUP_TEST_NO_MAIN=1
  # shellcheck source=../scripts/setup.sh
  source "${REPO_ROOT}/scripts/setup.sh"
  local calls="${TMP_ROOT}/clone-calls"
  : >"$calls"
  docker_exec_user() {
    printf '%s\n' "$*" >>"$calls"
    return 0
  }
  clone_github_repo "example-org" "example" "/home/robin/apps/example" || return 1
  local logged
  logged="$(cat "$calls")"
  assert_contains "$logged" "gh repo clone example-org/example /home/robin/apps/example" || return 1
  assert_not_contains "$logged" " -b " || return 1
  assert_not_contains "$logged" "develop" || return 1
}

test_registration_resolves_location_before_creating_a_session() {
  # shellcheck source=../scripts/lib/opencode-api.sh
  source "${REPO_ROOT}/scripts/lib/opencode-api.sh"
  WORKSPACE_ROOT="/home/robin/apps"
  local target="/home/robin/apps/example"
  RESOLVED_MARKER="${TMP_ROOT}/location-resolved"
  rm -f "$RESOLVED_MARKER"
  list_projects_json() {
    if [[ -f "$RESOLVED_MARKER" ]]; then
      printf '[{"canonical":"%s"}]\n' "$target"
    else
      echo '[]'
    fi
  }
  api_get() {
    case "$1" in
      /api/location\?location%5Bdirectory%5D=*)
        : >"$RESOLVED_MARKER"
        printf '{"directory":"%s","project":{"id":"project-1","canonical":"%s"}}\n' "$target" "$target"
        return 0
        ;;
      *) return 1 ;;
    esac
  }
  api_post() {
    [[ "$1" == "/api/session" ]] || return 1
    printf '{"data":{"id":"ses_1","location":{"directory":"%s"}}}\n' "$target"
  }
  local output
  output="$(register_project "$target" "example" 2>&1)" || return 1
  assert_file_exists "$RESOLVED_MARKER" || return 1
  assert_contains "$output" "ok" || return 1
}

test_registration_rejects_a_session_created_in_the_parent_directory() {
  # shellcheck source=../scripts/lib/opencode-api.sh
  source "${REPO_ROOT}/scripts/lib/opencode-api.sh"
  WORKSPACE_ROOT="/home/robin/apps"
  local target="/home/robin/apps/example"
  list_projects_json() { echo '[]'; }
  api_get() {
    case "$1" in
      /api/location\?location%5Bdirectory%5D=*)
        printf '{"directory":"%s","project":{"id":"project-1","canonical":"%s"}}\n' "$target" "$target"
        return 0
        ;;
      *) return 1 ;;
    esac
  }
  api_post() {
    printf '{"data":{"id":"ses_1","location":{"directory":"/home/robin/apps"}}}\n'
  }
  if register_project "$target" "example" >/dev/null 2>&1; then
    fail "registration succeeded even though the session landed in OPENCODE_APPS_DIR"
    return 1
  fi
}

test_archive_marks_only_the_selected_project_in_sqlite() {
  # shellcheck source=../scripts/lib/opencode-api.sh
  source "${REPO_ROOT}/scripts/lib/opencode-api.sh"
  WORKSPACE_ROOT="/home/robin/apps"
  local db_dir="${TMP_ROOT}/archive-db"
  mkdir -p "${db_dir}/opencode"
  CONTAINER_XDG_DATA_HOME="$db_dir"
  python3 -c '
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE project (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, time_archived INTEGER)")
con.execute("INSERT INTO project VALUES (?, ?, NULL)", ("remove", "/home/robin/apps/example"))
con.execute("INSERT INTO project VALUES (?, ?, NULL)", ("keep", "/home/robin/apps/other"))
con.commit()
' "${db_dir}/opencode/opencode.db"
  docker_exec() { "$@"; }
  archive_project "/home/robin/apps/example" >/dev/null || return 1
  python3 -c '
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
rows = dict(con.execute("SELECT id, time_archived IS NOT NULL FROM project"))
assert rows == {"remove": 1, "keep": 0}, rows
' "${db_dir}/opencode/opencode.db" || return 1
}

test_deregistration_archives_the_project_as_well_as_deleting_sessions() {
  # shellcheck source=../scripts/lib/opencode-api.sh
  source "${REPO_ROOT}/scripts/lib/opencode-api.sh"
  WORKSPACE_ROOT="/home/robin/apps"
  local archived="${TMP_ROOT}/project-archived"
  rm -f "$archived"
  list_sessions_for_directory() {
    printf '[{"id":"ses_1","location":{"directory":"%s"}}]\n' "$1"
  }
  api_delete() { return 0; }
  archive_project() { : >"$archived"; }
  deregister_project "/home/robin/apps/example" >/dev/null || return 1
  assert_file_exists "$archived" || return 1
}

test_repo_env_defaults_to_skip_without_blocking_setup() {
  # shellcheck source=../scripts/lib/repo-env.sh
  source "${REPO_ROOT}/scripts/lib/repo-env.sh"
  local repo="${TMP_ROOT}/env-skip"
  local pasted="${TMP_ROOT}/env-pasted"
  mkdir -p "$repo"
  rm -f "$pasted"
  YES=0
  DRY_RUN=0
  can_paste_interactively() { return 0; }
  read_env_paste_to_file() { : >"$pasted"; }
  ensure_repo_env_interactive "$repo" <<< $'\n' >/dev/null || return 1
  assert_file_missing "$pasted" || return 1
}

test_repo_env_allows_an_explicit_paste() {
  # shellcheck source=../scripts/lib/repo-env.sh
  source "${REPO_ROOT}/scripts/lib/repo-env.sh"
  local repo="${TMP_ROOT}/env-yes"
  local pasted="${TMP_ROOT}/env-yes-pasted"
  mkdir -p "$repo"
  rm -f "$pasted"
  YES=0
  DRY_RUN=0
  can_paste_interactively() { return 0; }
  read_env_paste_to_file() { : >"$pasted"; }
  ensure_repo_env_interactive "$repo" <<< $'y\n' >/dev/null || return 1
  assert_file_exists "$pasted" || return 1
}

test_repo_env_is_not_requested_when_sandbox_is_off() {
  # shellcheck source=../scripts/lib/repo-env.sh
  source "${REPO_ROOT}/scripts/lib/repo-env.sh"
  local repo="${TMP_ROOT}/env-off"
  local checked="${TMP_ROOT}/env-off-checked"
  mkdir -p "$repo"
  rm -f "$checked"
  OPENCODE_SANDBOX_MODE=off
  OPENCODE_SANDBOX_ENABLED=0
  DRY_RUN=0
  YES=0
  ensure_repo_env_interactive() { : >"$checked"; }
  local output
  output="$(ensure_repos_env "$repo")" || return 1
  assert_file_missing "$checked" || return 1
  assert_contains "$output" "not required" || return 1
}

run_test "main is the default work branch" test_main_is_the_default_work_branch
run_test "GitHub clones use the remote default branch" test_github_clone_uses_the_remote_default_branch
run_test "registration resolves the v2 location first" test_registration_resolves_location_before_creating_a_session
run_test "registration rejects parent-directory sessions" test_registration_rejects_a_session_created_in_the_parent_directory
run_test "archive updates only the selected SQLite project" test_archive_marks_only_the_selected_project_in_sqlite
run_test "deregistration archives the project" test_deregistration_archives_the_project_as_well_as_deleting_sessions
run_test "repo env paste defaults to skip" test_repo_env_defaults_to_skip_without_blocking_setup
run_test "repo env paste remains available explicitly" test_repo_env_allows_an_explicit_paste
run_test "sandbox-off setup does not request repo env files" test_repo_env_is_not_requested_when_sandbox_is_off

echo
printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))

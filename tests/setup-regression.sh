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
  assert_contains "$logged" "--no-checkout" || return 1
  assert_not_contains "$logged" " -b " || return 1
  assert_not_contains "$logged" "develop" || return 1
}

test_fresh_clone_populates_the_worktree() {
  export SETUP_TEST_NO_MAIN=1
  # shellcheck source=../scripts/setup.sh
  source "${REPO_ROOT}/scripts/setup.sh"
  unset OPENCODE_WORK_BRANCH
  OPENCODE_UID=1000
  OPENCODE_GID=1000
  local calls="${TMP_ROOT}/fresh-clone-calls"
  : >"$calls"
  # `--no-checkout` leaves HEAD on the remote default with an empty index, so
  # `branch --show-current` already says main and only an explicit checkout
  # populates the worktree. The local branch does not exist yet, so setup must
  # create it from the verified remote-tracking ref (never a same-named tag).
  docker_exec_git() {
    shift
    printf '%s\n' "$*" >>"$calls"
    case "$*" in
      "rev-parse --is-inside-work-tree") return 0 ;;
      "fetch --prune origin") return 0 ;;
      "show-ref --verify --quiet refs/remotes/origin/main") return 0 ;;
      "branch --show-current") echo "main"; return 0 ;;
      "checkout -f -b main --track refs/remotes/origin/main") return 0 ;;
      "merge --ff-only origin/main") return 0 ;;
      *) return 1 ;;
    esac
  }
  local output
  output="$(ensure_work_branch "/home/robin/apps/example" 1 2>&1)" || return 1
  assert_contains "$output" "on main" || return 1
  assert_contains "$(cat "$calls")" "checkout -f -b main --track refs/remotes/origin/main" || return 1
}

test_fresh_clone_checkout_failure_is_reported() {
  export SETUP_TEST_NO_MAIN=1
  # shellcheck source=../scripts/setup.sh
  source "${REPO_ROOT}/scripts/setup.sh"
  unset OPENCODE_WORK_BRANCH
  OPENCODE_UID=1000
  OPENCODE_GID=1000
  docker_exec_git() {
    shift
    case "$*" in
      "rev-parse --is-inside-work-tree") return 0 ;;
      "fetch --prune origin") return 0 ;;
      "show-ref --verify --quiet refs/remotes/origin/main") return 0 ;;
      "branch --show-current") echo "main"; return 0 ;;
      *) return 1 ;;
    esac
  }
  # An unpopulated worktree must not be registered as an empty project.
  if ensure_work_branch "/home/robin/apps/example" 1 >/dev/null 2>&1; then
    fail "a failed fresh-clone checkout must report failure"
    return 1
  fi
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
      # Include the id: the resolved project is verified by id when the server
      # supplies one, so a path-only entry would not prove the right project.
      printf '[{"id":"project-1","canonical":"%s"}]\n' "$target"
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
    [[ -f "$RESOLVED_MARKER" ]] || { echo "api_post ran before location resolution" >&2; return 1; }
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
  local location_marker="${TMP_ROOT}/mismatch-resolved"
  local deleted_sessions="${TMP_ROOT}/mismatch-deleted"
  rm -f "$location_marker" "$deleted_sessions"
  # Before resolution the target is absent; after it the target *is* registered,
  # so the only reason registration can fail is the session-directory check.
  list_projects_json() {
    if [[ -f "$location_marker" ]]; then
      printf '[{"canonical":"%s"}]\n' "$target"
    else
      echo '[]'
    fi
  }
  api_get() {
    case "$1" in
      /api/location\?location%5Bdirectory%5D=*)
        : >"$location_marker"
        printf '{"directory":"%s","project":{"id":"project-1","canonical":"%s"}}\n' "$target" "$target"
        return 0
        ;;
      *) return 1 ;;
    esac
  }
  api_post() {
    printf '{"data":{"id":"ses_1","location":{"directory":"/home/robin/apps"}}}\n'
  }
  api_delete() {
    printf '%s\n' "$1" >>"$deleted_sessions"
    return 0
  }
  local output
  if output="$(register_project "$target" "example" 2>&1)"; then
    fail "registration succeeded even though the session landed in OPENCODE_APPS_DIR"
    return 1
  fi
  assert_contains "$output" "seed session landed in /home/robin/apps instead of ${target}" || return 1
  # Exactly one DELETE, for the misplaced session only.
  [[ "$(cat "$deleted_sessions" 2>/dev/null || true)" == "/api/session/ses_1" ]] \
    || fail "expected exactly one DELETE for /api/session/ses_1, got: $(cat "$deleted_sessions" 2>/dev/null || true)"
}

test_registration_retries_a_missing_seed() {
  # shellcheck source=../scripts/lib/opencode-api.sh
  source "${REPO_ROOT}/scripts/lib/opencode-api.sh"
  WORKSPACE_ROOT="/home/robin/apps"
  local target="/home/robin/apps/example"
  local posted="${TMP_ROOT}/seed-posted"
  rm -f "$posted"
  # Location resolution persists the project, so an earlier failed seed leaves it
  # registered without a session. That must be retryable, not reported as skip.
  list_projects_json() { printf '[{"id":"project-1","canonical":"%s"}]\n' "$target"; }
  session_directories() { printf '\n'; }
  api_get() {
    printf '{"directory":"%s","project":{"id":"project-1","canonical":"%s"}}\n' "$target" "$target"
  }
  api_post() {
    [[ "$1" == "/api/session" ]] || return 1
    : >"$posted"
    printf '{"data":{"id":"ses_2","location":{"directory":"%s"}}}\n' "$target"
  }
  local output
  output="$(register_project "$target" "example" 2>&1)" || return 1
  assert_file_exists "$posted" || return 1
  assert_contains "$output" "ok" || return 1
}

test_api_delete_treats_an_absent_session_as_deleted() {
  # shellcheck source=../scripts/lib/opencode-api.sh
  source "${REPO_ROOT}/scripts/lib/opencode-api.sh"
  OPENCODE_SERVER_PASSWORD="test"
  # A parent session deletion also removes its children, so a follow-up DELETE
  # gets 404. That must count as deleted; anything else must not.
  curl() { printf '404'; return 0; }
  api_delete "/api/session/ses_child" >/dev/null 2>&1 || { fail "404 should count as deleted"; return 1; }
  curl() { printf '500'; return 0; }
  if api_delete "/api/session/ses_child" >/dev/null 2>&1; then
    fail "500 should not count as deleted"
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
  # Pin a local API target so the archive guard allows the test even when the
  # invoking shell exports a remote OPENCODE_HOST.
  OPENCODE_HOST="http://127.0.0.1:4097"
  OPENCODE_PUBLISH_PORT=4097
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

test_session_scope_respects_nested_projects() {
  # shellcheck source=../scripts/lib/opencode-api.sh
  source "${REPO_ROOT}/scripts/lib/opencode-api.sh"
  local parent="/home/robin/apps/parent"
  local child="/home/robin/apps/parent/child"
  local out
  # A registered parent must not claim its child project's own sessions.
  out="$(printf '%s\n' "$child" | dir_has_session "$child" "$parent"$'\n'"$child")"
  [[ "$out" == "yes" ]] || { fail "child session excluded by its parent project (got '${out}')"; return 1; }
  # A nested project's sessions stay out of its parent's scope.
  out="$(printf '%s\n' "$child" | dir_has_session "$parent" "$parent"$'\n'"$child")"
  [[ "$out" == "no" ]] || { fail "nested project session leaked into the parent (got '${out}')"; return 1; }
  # A plain subdirectory session belongs to the project.
  out="$(printf '%s\n' "$parent/src" | dir_has_session "$parent" "$parent")"
  [[ "$out" == "yes" ]] || { fail "subdirectory session not attributed to its project (got '${out}')"; return 1; }
}

test_removal_refuses_an_unreadable_project_list() {
  # shellcheck source=../scripts/lib/opencode-api.sh
  source "${REPO_ROOT}/scripts/lib/opencode-api.sh"
  list_sessions_json() { printf '[{"id":"ses_1","location":{"directory":"/home/robin/apps/example"}}]'; }
  # Without the project list, nested projects cannot be told apart from this one.
  api_get() { return 1; }
  if list_sessions_for_directory "/home/robin/apps/example" >/dev/null 2>&1; then
    fail "session selection must fail when /api/project cannot be read"
    return 1
  fi
}

test_removal_verification_flags_an_invalid_list() {
  # shellcheck source=../scripts/lib/opencode-api.sh
  source "${REPO_ROOT}/scripts/lib/opencode-api.sh"
  api_get() { printf 'null'; }
  local out
  out="$(project_presence "/home/robin/apps/example")"
  [[ "$out" == "invalid" ]] || { fail "a non-array response must be invalid (got '${out}')"; return 1; }
  api_get() { printf '[]'; }
  out="$(project_presence "/home/robin/apps/example")"
  [[ "$out" == "absent" ]] || { fail "an empty array must mean absent (got '${out}')"; return 1; }
}

test_deregistration_archives_the_project_as_well_as_deleting_sessions() {
  # shellcheck source=../scripts/lib/opencode-api.sh
  source "${REPO_ROOT}/scripts/lib/opencode-api.sh"
  WORKSPACE_ROOT="/home/robin/apps"
  local deleted="${TMP_ROOT}/sessions-deleted"
  local archived="${TMP_ROOT}/project-archived"
  rm -f "$deleted" "$archived"
  OPENCODE_HOST="http://127.0.0.1:4097"
  OPENCODE_PUBLISH_PORT=4097
  list_sessions_for_directory() {
    printf '[{"id":"ses_1","location":{"directory":"%s"}}]\n' "$1"
  }
  api_delete() {
    printf '%s\n' "$1" >>"$deleted"
    return 0
  }
  # Archival must only happen after the expected session was deleted.
  archive_project() {
    if [[ "$(cat "$deleted" 2>/dev/null || true)" != "/api/session/ses_1" ]]; then
      echo "archive ran before the expected session was deleted" >&2
      return 1
    fi
    : >"$archived"
  }
  # Post-archive verification must see a readable project list without the
  # removed project.
  api_get() { echo '[]'; }
  deregister_project "/home/robin/apps/example" >/dev/null || return 1
  assert_file_exists "$archived" || return 1
  [[ "$(cat "$deleted")" == "/api/session/ses_1" ]] \
    || fail "expected exactly one DELETE for /api/session/ses_1, got: $(cat "$deleted")"
}

test_deregistration_refuses_a_non_local_api_host() {
  # shellcheck source=../scripts/lib/opencode-api.sh
  source "${REPO_ROOT}/scripts/lib/opencode-api.sh"
  WORKSPACE_ROOT="/home/robin/apps"
  local touched="${TMP_ROOT}/remote-host-touched"
  rm -f "$touched"
  # --host points elsewhere: deleting sessions there while archiving the local
  # DB would edit two different servers, so nothing may be touched.
  OPENCODE_HOST="http://other-server:4097"
  OPENCODE_PUBLISH_PORT=4097
  list_sessions_for_directory() { : >"$touched"; echo '[]'; }
  api_delete() { : >"$touched"; return 0; }
  archive_project() { : >"$touched"; return 0; }
  docker_exec() { : >"$touched"; return 0; }
  local output
  if output="$(deregister_project "/home/robin/apps/example" 2>&1)"; then
    fail "deregistration succeeded against a non-local --host"
    return 1
  fi
  assert_contains "$output" "refusing to delete sessions or archive projects" || return 1
  assert_file_missing "$touched" || return 1
}

test_local_selection_drops_stale_absolute_registrations() {
  export SETUP_TEST_NO_MAIN=1
  # shellcheck source=../scripts/setup.sh
  source "${REPO_ROOT}/scripts/setup.sh"
  WORKSPACE_ROOT="/home/robin/01_REPOS/apps"
  local -a DESIRED_DIRS=()
  discover_local_git_roots() {
    printf '%s\n' \
      "${WORKSPACE_ROOT}/blocshed" \
      "${WORKSPACE_ROOT}/fatebox" \
      "${WORKSPACE_ROOT}/rekalled"
  }
  list_registered_workspace_projects() {
    # A default-location project and the malformed canonical path it produced on
    # the previous run are both stale. Neither appears in the discovered picker.
    printf '%s\n' \
      "${WORKSPACE_ROOT}" \
      "${WORKSPACE_ROOT}home/robin/01_REPOS/apps" \
      "${WORKSPACE_ROOT}/blocshed" \
      "${WORKSPACE_ROOT}/fatebox" \
      "${WORKSPACE_ROOT}/rekalled"
  }

  # Enter means keep the currently registered projects that are actually in the
  # picker. It must not feed an unseen absolute path back into path construction.
  prompt_desired_local_set <<< $'\n' >/dev/null 2>&1 || return 1
  local actual expected
  actual="$(printf '%s\n' "${DESIRED_DIRS[@]}")"
  expected="$(printf '%s\n' \
    "${WORKSPACE_ROOT}/blocshed" \
    "${WORKSPACE_ROOT}/fatebox" \
    "${WORKSPACE_ROOT}/rekalled")"
  [[ "$actual" == "$expected" ]] || {
    fail "stale registrations contaminated the desired set"$'\n'"expected: ${expected}"$'\n'"actual: ${actual}"
    return 1
  }
}


test_local_desired_paths_reject_absolute_selection_items() {
  export SETUP_TEST_NO_MAIN=1
  # shellcheck source=../scripts/setup.sh
  source "${REPO_ROOT}/scripts/setup.sh"
  WORKSPACE_ROOT="/home/robin/01_REPOS/apps"
  local -a DESIRED_DIRS=()
  discover_local_git_roots() {
    printf '%s\n' \
      "${WORKSPACE_ROOT}/blocshed" \
      "${WORKSPACE_ROOT}/fatebox" \
      "${WORKSPACE_ROOT}/rekalled"
  }
  list_registered_workspace_projects() {
    printf '%s\n' \
      "${WORKSPACE_ROOT}/blocshed" \
      "${WORKSPACE_ROOT}/fatebox" \
      "${WORKSPACE_ROOT}/rekalled"
  }
  # Exercise the path-construction boundary independently of the picker: even
  # an invalid absolute value must never become APPS_DIR + absolute path.
  select_items() {
    SELECTED_ITEMS=(
      "blocshed"
      "fatebox"
      "rekalled"
      "$WORKSPACE_ROOT"
    )
  }
  prompt_desired_local_set >/dev/null 2>&1 || return 1
  local actual expected
  actual="$(printf '%s\n' "${DESIRED_DIRS[@]}")"
  expected="$(printf '%s\n' \
    "${WORKSPACE_ROOT}/blocshed" \
    "${WORKSPACE_ROOT}/fatebox" \
    "${WORKSPACE_ROOT}/rekalled")"
  [[ "$actual" == "$expected" ]] || {
    fail "an absolute selection produced an invalid desired path"$'\n'"expected: ${expected}"$'\n'"actual: ${actual}"
    return 1
  }
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

test_repo_env_paste_accepts_a_crlf_terminator() {
  # shellcheck source=../scripts/lib/repo-env.sh
  source "${REPO_ROOT}/scripts/lib/repo-env.sh"
  local target="${TMP_ROOT}/env-paste-crlf"
  rm -f "$target"
  printf 'EXAMPLE_KEY=value\r\n.\r\nSENTINEL_KEY=leak\r\n' | read_env_paste_to_file "$target" >/dev/null || return 1
  assert_file_exists "$target" || return 1
  local content
  content="$(cat "$target")"
  assert_contains "$content" "EXAMPLE_KEY=value" || return 1
  assert_not_contains "$content" "SENTINEL_KEY" || return 1
  [[ "$content" != *"."* ]] || { fail "terminator was written into ${target}"; return 1; }
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
run_test "fresh clone populates the worktree" test_fresh_clone_populates_the_worktree
run_test "fresh clone checkout failure is reported" test_fresh_clone_checkout_failure_is_reported
run_test "GitHub clones use the remote default branch" test_github_clone_uses_the_remote_default_branch
run_test "registration resolves the v2 location first" test_registration_resolves_location_before_creating_a_session
run_test "registration rejects parent-directory sessions" test_registration_rejects_a_session_created_in_the_parent_directory
run_test "registration retries a missing seed" test_registration_retries_a_missing_seed
run_test "session delete treats 404 as deleted" test_api_delete_treats_an_absent_session_as_deleted
run_test "archive updates only the selected SQLite project" test_archive_marks_only_the_selected_project_in_sqlite
run_test "session scope respects nested projects" test_session_scope_respects_nested_projects
run_test "removal refuses an unreadable project list" test_removal_refuses_an_unreadable_project_list
run_test "removal verification flags an invalid list" test_removal_verification_flags_an_invalid_list
run_test "deregistration archives the project" test_deregistration_archives_the_project_as_well_as_deleting_sessions
run_test "deregistration refuses a non-local API host" test_deregistration_refuses_a_non_local_api_host
run_test "local selection drops stale absolute registrations" test_local_selection_drops_stale_absolute_registrations
run_test "local desired paths reject absolute selections" test_local_desired_paths_reject_absolute_selection_items

run_test "repo env paste defaults to skip" test_repo_env_defaults_to_skip_without_blocking_setup
run_test "repo env paste remains available explicitly" test_repo_env_allows_an_explicit_paste
run_test "repo env paste accepts a CRLF terminator" test_repo_env_paste_accepts_a_crlf_terminator
run_test "sandbox-off setup does not request repo env files" test_repo_env_is_not_requested_when_sandbox_is_off

echo
printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( PASS + FAIL == 0 )); then
  if [[ -n "${TEST_FILTER:-}" ]]; then
    echo "No tests matched TEST_FILTER='${TEST_FILTER}'." >&2
  else
    echo "No tests ran." >&2
  fi
  exit 1
fi
(( FAIL == 0 ))

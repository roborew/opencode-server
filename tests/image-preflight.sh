#!/usr/bin/env bash
# Image-content + deployment-contract tests for the oc-sandbox mountpoint
# preflight companion (opencode-config-v2 PR #4 / Rekalled #41).
#
# Covers, in order:
#   - static guards on docker-compose.yml: the opencode service mounts no
#     docker.sock, requests no privileged mode and sets no compose `user:`
#     (the entrypoint privilege drop owns the runtime identity)
#   - static guard on docker-compose.sandbox.yml: the optional overlay keeps
#     exactly the documented socket control-plane mount and still grants no
#     privileges
#   - unit tests of docker/assert-worktree-ownership.sh (the startup guard
#     that fails loudly when the runtime uid/gid stops matching the worktree
#     owner)
#   - deployment contract: the Docker CLI, Compose and Buildx pins are
#     forwarded from docker-compose.yml into the image build
#   - image test: builds the Dockerfile `server-tools` stage and, inside a
#     container run as the invoking uid/gid with NO Docker socket, asserts
#     the pinned docker CLI, compose plugin and buildx plugin are installed,
#     the compose model renders the preflight fixture client-side (DOCKER_HOST
#     points at a dead endpoint), the uid/gid round-trips through a mounted
#     worktree-shaped path, and git is present
#
# No Docker daemon is required for the static and unit tests; checks whose
# prerequisites are missing record a visible SKIP (never a PASS), and the
# image test does the same when no daemon is available, e.g. on runners
# without Docker. Inside the test container no daemon is ever contacted.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
SKIP=0

fail() {
  echo "    $*" >&2
  # Each test runs in a subshell (run_test), so exit stops the failed test
  # without killing the suite — later checks can't mask an earlier failure.
  exit 1
}

skip() {
  echo "    SKIP: $*" >&2
  # Distinct subshell exit status: run_test records a visible SKIP instead
  # of a PASS when a check's prerequisites are missing.
  exit 200
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: ${needle}"$'\n'"actual: ${haystack}"
}

run_test() {
  local name="$1"
  shift
  if [[ -n "${TEST_FILTER:-}" && "$name" != *"${TEST_FILTER}"* ]]; then
    return 0
  fi
  echo "TEST ${name}"
  local status=0
  ( "$@" ) || status=$?
  if (( status == 0 )); then
    PASS=$((PASS + 1))
    echo "  PASS"
  elif (( status == 200 )); then
    SKIP=$((SKIP + 1))
    echo "  SKIP"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL"
  fi
}

docker_compose_available() {
  command -v docker >/dev/null 2>&1 && command -v jq >/dev/null 2>&1
}

# Render the repo compose files in an isolated directory (stub .env so the
# service-level env_file resolves; CI has no secrets) and echo the JSON.
render_compose() {
  local files="$1" compose_args=()
  local dir="$TMP_ROOT/render-$$"
  mkdir -p "$dir"
  cp "${REPO_ROOT}/docker-compose.yml" "${REPO_ROOT}/docker-compose.sandbox.yml" "$dir/"
  # Stub every var the base file interpolates without a default.
  printf 'OPENCODE_SERVER_PASSWORD=test-only\n' >"$dir/.env"
  local f
  for f in $files; do compose_args+=(-f "$dir/$f"); done
  (cd "$dir" && docker compose -p "imgpreflight$$" "${compose_args[@]}" config --format json)
}

test_base_compose_grants_no_daemon_access() {
  docker_compose_available || skip "docker/jq not on host - cannot render the compose contract"
  local model
  model="$(render_compose docker-compose.yml)" \
    || fail "docker compose config failed to render the base file"
  # Reject socket mounts by source OR target: /run/docker.sock:/var/run/docker.sock
  # must not slip through a source-only check.
  jq -e '
    ([.services.opencode.volumes[]?
       | select(((.source // "") | test("docker[.]sock$"))
             or ((.target // "") | test("docker[.]sock$")))
      ]
      | length) == 0
    and (.services.opencode.privileged // false | not)
    and (.services.opencode.user == null)
  ' <<<"$model" >/dev/null \
    || fail "base compose: opencode service must mount no docker.sock (any source/target), request no privileged mode and set no user:"$'\n'"$(jq -c '.services.opencode | {volumes, privileged, user}' <<<"$model")"
}

test_sandbox_overlay_is_socket_control_plane_only() {
  docker_compose_available || skip "docker/jq not on host - cannot render the compose contract"
  local model
  model="$(render_compose 'docker-compose.yml docker-compose.sandbox.yml')" \
    || fail "docker compose config failed to render base+sandbox overlay"
  # The overlay documents exactly one socket mount (the sibling control
  # plane, by target); it must stay, and nothing may gain privileges or a
  # user: override. Any socket bind beyond that single control-plane mount
  # is rejected by the source-or-target check.
  jq -e '
    ([.services.opencode.volumes[]?
       | select(((.source // "") | test("docker[.]sock$"))
             or ((.target // "") | test("docker[.]sock$")))] as $socks
      | ($socks | length) == 1
      and ($socks[0].source == "/var/run/docker.sock")
      and ($socks[0].target == "/var/run/docker.sock"))
    and (.services.opencode.privileged // false | not)
    and (.services.opencode.user == null)
  ' <<<"$model" >/dev/null \
    || fail "sandbox overlay: expected exactly the documented docker.sock control-plane mount and no privileges/user:"$'\n'"$(jq -c '.services.opencode | {volumes, privileged, user}' <<<"$model")"
}

test_ownership_guard_passes_when_owner_matches() {
  local owned
  owned="${TMP_ROOT}/wt-owned"
  mkdir -p "$owned"
  OPENCODE_WORKTREES_DIR="$owned" bash "${REPO_ROOT}/docker/assert-worktree-ownership.sh" \
    || fail "guard failed on a worktree root owned by the invoking user"
}

test_ownership_guard_noops_without_a_worktree_root() {
  local out
  out="$(env -u OPENCODE_WORKTREES_DIR bash "${REPO_ROOT}/docker/assert-worktree-ownership.sh" 2>&1)" \
    || fail "guard should be a no-op when OPENCODE_WORKTREES_DIR is unset"
  [[ -z "$out" ]] || fail "guard should be silent when OPENCODE_WORKTREES_DIR is unset, got: ${out}"
  OPENCODE_WORKTREES_DIR="${TMP_ROOT}/does-not-exist-yet" \
    bash "${REPO_ROOT}/docker/assert-worktree-ownership.sh" \
    || fail "guard should be a no-op when the worktree root does not exist yet"
}

test_ownership_guard_fails_loudly_on_foreign_owner() {
  # A genuinely foreign-owned path: /var is root-owned for non-root users; a
  # root runner (uid 0 owns /var) instead gets a fixture chowned to 1:1 —
  # as root the chown is permitted, so the failure path is always exercised.
  local foreign="${TMP_ROOT}/foreign-owned"
  if [[ "$(id -u)" == "0" ]]; then
    mkdir -p "$foreign" && chown 1:1 "$foreign" \
      || fail "root runner: could not create a foreign-owned fixture"
  else
    foreign=/var # root-owned on every supported host (macOS + Ubuntu runners)
  fi
  local out status
  out="$(OPENCODE_WORKTREES_DIR="$foreign" bash "${REPO_ROOT}/docker/assert-worktree-ownership.sh" 2>&1)"
  status=$?
  [[ $status -ne 0 ]] || fail "guard passed although $foreign is not owned by $(id -u):$(id -g)"
  assert_contains "$out" "assert-worktree-ownership:" \
    || fail "guard failure is not attributable (no assert-worktree-ownership: prefix)"$'\n'"actual: ${out}"
  assert_contains "$out" "OPENCODE_UID" \
    || fail "guard failure does not point at the OPENCODE_UID/OPENCODE_GID fix"$'\n'"actual: ${out}"
}

test_entrypoint_wires_the_ownership_guard() {
  grep -q 'source /usr/local/bin/assert-worktree-ownership.sh' "${REPO_ROOT}/docker/entrypoint.sh" \
    || fail "entrypoint.sh does not source assert-worktree-ownership.sh"
  grep -q '^\s*assert_worktree_root_ownership$' "${REPO_ROOT}/docker/entrypoint.sh" \
    || fail "entrypoint.sh does not call assert_worktree_root_ownership"
  # The authoritative re-check must run after the Infisical inject (which may
  # define OPENCODE_WORKTREES_DIR) — same placement as the git-identity re-apply.
  grep -q 'source /usr/local/bin/assert-worktree-ownership.sh' "${REPO_ROOT}/docker/opencode-serve-guarded.sh" \
    || fail "opencode-serve-guarded.sh does not source assert-worktree-ownership.sh (post-Infisical check)"
  grep -q '^\s*assert_worktree_root_ownership$' "${REPO_ROOT}/docker/opencode-serve-guarded.sh" \
    || fail "opencode-serve-guarded.sh does not call assert_worktree_root_ownership (post-Infisical check)"
  grep -q 'COPY docker/assert-worktree-ownership.sh' "${REPO_ROOT}/Dockerfile" \
    || fail "Dockerfile does not COPY assert-worktree-ownership.sh"
}

pinned_arg() {
  sed -n "s/^ARG $1=//p" "${REPO_ROOT}/Dockerfile" | head -n1
}

test_docker_tool_pins_are_forwarded_to_the_image_build() {
  docker_compose_available || skip "docker/jq not on host - cannot render the compose contract"
  local cli_version compose_version buildx_version model
  cli_version="$(pinned_arg DOCKER_CLI_VERSION)"
  compose_version="$(pinned_arg DOCKER_COMPOSE_VERSION)"
  buildx_version="$(pinned_arg DOCKER_BUILDX_VERSION)"
  [[ -n "$cli_version" && -n "$compose_version" && -n "$buildx_version" ]] \
    || fail "DOCKER_CLI_VERSION/DOCKER_COMPOSE_VERSION/DOCKER_BUILDX_VERSION not pinned in the Dockerfile"
  model="$(render_compose docker-compose.yml)" \
    || fail "docker compose config failed to render the build arguments"
  jq -e \
    --arg cli "$cli_version" \
    --arg compose "$compose_version" \
    --arg buildx "$buildx_version" \
    '.services.opencode.build.args
      | .DOCKER_CLI_VERSION == $cli
      and .DOCKER_COMPOSE_VERSION == $compose
      and .DOCKER_BUILDX_VERSION == $buildx' \
    <<<"$model" >/dev/null \
    || fail "compose does not forward the Docker CLI/Compose/Buildx pins from the Dockerfile:"$'\n'"$(jq -c '.services.opencode.build.args | {DOCKER_CLI_VERSION, DOCKER_COMPOSE_VERSION, DOCKER_BUILDX_VERSION}' <<<"$model")"
}

test_image_ships_the_preflight_toolchain() {
  docker info >/dev/null 2>&1 || skip "no Docker daemon on the host - cannot build server-tools"
  local cli_version compose_version buildx_version
  cli_version="$(pinned_arg DOCKER_CLI_VERSION)"
  compose_version="$(pinned_arg DOCKER_COMPOSE_VERSION)"
  buildx_version="$(pinned_arg DOCKER_BUILDX_VERSION)"
  [[ -n "$cli_version" && -n "$compose_version" && -n "$buildx_version" ]] \
    || fail "DOCKER_CLI_VERSION/DOCKER_COMPOSE_VERSION/DOCKER_BUILDX_VERSION not pinned in the Dockerfile"

  local tag="opencode-server-tools:preflight-test"
  echo "    building --target server-tools (first build can take a few minutes; layer cache speeds up reruns)"
  docker build -q -t "$tag" --target server-tools "$REPO_ROOT" >/dev/null \
    || { fail "docker build --target server-tools failed"; return 1; }

  local work="${TMP_ROOT}/container-work"
  mkdir -p "${work}/wt-shape"
  cp -R "${REPO_ROOT}/tests/fixtures/preflight-compose" "${work}/preflight-compose"

  # Run as the invoking uid/gid, no docker.sock mounted, DOCKER_HOST dead
  # inside — the render must succeed purely client-side.
  local out
  out="$(docker run --rm \
    -u "$(id -u):$(id -g)" \
    -e EXPECTED_UID="$(id -u)" -e EXPECTED_GID="$(id -g)" \
    -e PINNED_DOCKER_CLI="$cli_version" -e PINNED_COMPOSE="$compose_version" \
    -e PINNED_BUILDX="$buildx_version" \
    -v "${work}:/work" -v "${REPO_ROOT}/tests:/tests:ro" -w /work \
    "$tag" bash /tests/container-preflight-assertions.sh 2>&1)" \
    || { echo "$out" >&2; fail "in-container preflight assertions failed"; return 1; }
  echo "$out"

  # Bind parity: what the container created is owned by the host user.
  local owner
  # shellcheck disable=SC2012
  # (ls -nd is the portable numeric-owner stat; find -printf is GNU-only)
  owner="$(ls -nd "${work}/wt-shape/created-by-test" | awk '{print $3":"$4}')" \
    || fail "container did not create ${work}/wt-shape/created-by-test on the host bind"
  [[ "$owner" == "$(id -u):$(id -g)" ]] \
    || fail "${work}/wt-shape/created-by-test owned by ${owner}, expected $(id -u):$(id -g)"
}

run_test "base compose grants the opencode service no daemon access" test_base_compose_grants_no_daemon_access
run_test "sandbox overlay stays a socket control plane with no privileges" test_sandbox_overlay_is_socket_control_plane_only
run_test "ownership guard passes when the worktree owner matches" test_ownership_guard_passes_when_owner_matches
run_test "ownership guard is a no-op without a worktree root" test_ownership_guard_noops_without_a_worktree_root
run_test "ownership guard fails loudly on a foreign-owned worktree root" test_ownership_guard_fails_loudly_on_foreign_owner
run_test "entrypoint wires the ownership guard" test_entrypoint_wires_the_ownership_guard
run_test "docker tool pins are forwarded to the image build" test_docker_tool_pins_are_forwarded_to_the_image_build
run_test "image ships the client-side preflight toolchain" test_image_ships_the_preflight_toolchain

echo
printf 'Result: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if (( PASS + FAIL + SKIP == 0 )); then
  if [[ -n "${TEST_FILTER:-}" ]]; then
    echo "No tests matched TEST_FILTER='${TEST_FILTER}'." >&2
  else
    echo "No tests ran." >&2
  fi
  exit 1
fi
(( FAIL == 0 ))

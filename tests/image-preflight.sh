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
#   - code-index: pinned binary + hash-locked bridge + non-root (static),
#     the entrypoint token guard (unit), and an image test that checks auth,
#     tools/list, read-only indexing and search inside the built container
#   - retirement guard: no Milvus / claude-context references in runtime
#     files and no Milvus-stack service in the rendered compose model
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
  mkdir -p "$dir/docker" && cp -R "${REPO_ROOT}/docker/code-index" "$dir/docker/"
  # Stub every var the base file interpolates without a default.
  printf 'OPENCODE_SERVER_PASSWORD=test-only\nCODE_INDEX_TOKEN=test-only-token-test-only-token-00\n' >"$dir/.env"
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
  # This check verifies the Dockerfile defaults, so do not let operator
  # overrides exported in the calling environment change the rendered values.
  unset DOCKER_CLI_VERSION DOCKER_COMPOSE_VERSION DOCKER_BUILDX_VERSION
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

# The Milvus / claude-context stack was retired (ADR 0017 in opencode-config-v2):
# no runtime file may bring it back, and the rendered model has no such service.
test_retired_milvus_stack_stays_removed() {
  local hits
  hits="$(cd "$REPO_ROOT" && grep -rniE 'milvus|claude-context|etcd|minio|EMBEDDING_PROVIDER' \
    docker-compose.yml docker-compose.sandbox.yml .env.example docker/ overrides/opencode.server.json scripts/ 2>/dev/null || true)"
  [[ -z "$hits" ]] || fail "retired Milvus/claude-context references remain:"$'\n'"$hits"
  docker_compose_available || skip "docker/jq not on host - static grep passed, compose render skipped"
  local model
  model="$(render_compose docker-compose.yml)" \
    || fail "docker compose config failed to render the base file"
  jq -e '[.services | keys[] | select(test("milvus|etcd|minio"))] | length == 0' <<<"$model" >/dev/null \
    || fail "rendered compose still defines a Milvus-stack service: $(jq -c '.services | keys' <<<"$model")"
}

CODE_INDEX_DIR="${REPO_ROOT}/docker/code-index"

# The code-index image pins its binary (version + per-arch SHA-256), installs the
# bridge only from a hash-locked lock file, and runs as a non-root user.
test_code_index_image_pins_are_strict() {
  local df="${CODE_INDEX_DIR}/Dockerfile" req="${CODE_INDEX_DIR}/requirements.txt"
  [[ -f "$df" && -f "$req" ]] || fail "docker/code-index/Dockerfile or requirements.txt missing"
  grep -qE '^ARG CBM_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$df" || fail "CBM_VERSION is not pinned to an exact release"
  grep -qE '^ARG CBM_SHA256_AMD64=[0-9a-f]{64}$' "$df" || fail "no amd64 SHA-256 pin"
  grep -qE '^ARG CBM_SHA256_ARM64=[0-9a-f]{64}$' "$df" || fail "no arm64 SHA-256 pin"
  grep -q 'sha256sum -c' "$df" || fail "the downloaded tarball is not checksum-verified"
  grep -q -- '--require-hashes' "$df" || fail "pip install does not use --require-hashes"
  grep -qE '^USER cbm$' "$df" || fail "image does not switch to the non-root cbm user"
  grep -qE '^mcp-proxy==[0-9]+\.[0-9]+\.[0-9]+ ' "$req" || fail "mcp-proxy is not pinned in requirements.txt"
  local pins hashed
  pins="$(grep -cE '^[A-Za-z0-9_.-]+==' "$req")"
  hashed="$(awk '/^[A-Za-z0-9_.-]+==/{p=$1} /--hash=sha256:/{if(p){h[p]=1}} END{print length(h)}' "$req")"
  [[ "$pins" -gt 0 && "$pins" == "$hashed" ]] || fail "every requirement needs a --hash (pins=${pins}, hashed=${hashed})"
}

# The entrypoint refuses to start without a usable bearer token, before it runs
# anything else.
test_code_index_entrypoint_requires_a_token() {
  local ep="${CODE_INDEX_DIR}/entrypoint.sh" out
  out="$(env -i PATH=/usr/bin:/bin sh "$ep" 2>&1)" && fail "entrypoint started without CODE_INDEX_TOKEN"
  assert_contains "$out" "CODE_INDEX_TOKEN is not set"
  out="$(env -i PATH=/usr/bin:/bin CODE_INDEX_TOKEN=short sh "$ep" 2>&1)" && fail "entrypoint accepted a short token"
  assert_contains "$out" "at least 32 characters"
}

# Build the image and, with code mounted read-only and the root filesystem
# read-only, check auth, the tool surface, indexing and search end to end.
test_code_index_image_serves_authenticated_mcp() {
  docker info >/dev/null 2>&1 || skip "no Docker daemon on the host - cannot build code-index"
  local tag="code-index:preflight-test" name="code-index-preflight-$$"
  echo "    building docker/code-index (first build can take a minute)"
  docker build -q -t "$tag" "$CODE_INDEX_DIR" >/dev/null || fail "docker build docker/code-index failed"

  # A real git repo at the same path inside and out, as in production.
  local repo="${TMP_ROOT}/code-index-repo"
  cp -R "${REPO_ROOT}/tests/fixtures/code-index-repo" "$repo"
  if ! { git -C "$repo" init -q && git -C "$repo" add -A \
    && git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm fixture; }; then
    fail "could not create the fixture git repo"
  fi
  chmod -R a+rX "$repo"

  local token
  token="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  docker run -d --name "$name" --read-only --tmpfs /tmp \
    -e CODE_INDEX_TOKEN="$token" \
    -v "${repo}:${repo}:ro" -v "${REPO_ROOT}/tests/code-index-smoke.py:/smoke.py:ro" \
    "$tag" >/dev/null || fail "code-index container did not start"
  # Runs in run_test's subshell, so this EXIT trap only cleans up the container;
  # the suite-level trap still removes TMP_ROOT.
  # shellcheck disable=SC2064  # expand now: the trap must remove this container
  trap "docker rm -f '$name' >/dev/null 2>&1" EXIT

  local health="" i
  for i in $(seq 1 60); do
    health="$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || true)"
    [[ "$health" == healthy || "$health" == unhealthy ]] && break
    sleep 1
  done
  [[ "$health" == healthy ]] || fail "code-index not healthy after ${i}s (${health}):"$'\n'"$(docker logs "$name" 2>&1 | tail -20)"

  local out
  out="$(docker exec "$name" python3 -I /smoke.py "$repo" compute_invoice_total 2>&1)" \
    || fail "in-container MCP checks failed:"$'\n'"$out"
  printf '    %s\n' "${out//$'\n'/$'\n'    }"
  [[ "$(docker exec "$name" id -u)" != 0 ]] || fail "code-index runs as root"
  docker logs "$name" 2>&1 | grep -qF "$token" && fail "the bearer token appears in container logs"
  [[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "indexing wrote into the read-only repo"
  docker rm -f "$name" >/dev/null
}

# SC 4 / SC 5c: the refresh loop picks up a host edit to an indexed repo and
# prunes a removed worktree (its parent dir is still mounted). Short interval.
test_code_index_refreshes_edits_and_prunes_removed_worktrees() {
  docker info >/dev/null 2>&1 || skip "no Docker daemon on the host - cannot build code-index"
  local tag="code-index:preflight-test" name="code-index-refresh-$$"
  docker build -q -t "$tag" "$CODE_INDEX_DIR" >/dev/null || fail "docker build docker/code-index failed"

  local worktrees="${TMP_ROOT}/refresh-worktrees" repo
  repo="${worktrees}/slice-1-billing"
  mkdir -p "$worktrees"
  cp -R "${REPO_ROOT}/tests/fixtures/code-index-repo" "$repo"
  if ! { git -C "$repo" init -q && git -C "$repo" add -A \
    && git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm fixture; }; then
    fail "could not create the fixture git repo"
  fi
  chmod -R a+rwX "$worktrees"

  local token
  token="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  docker run -d --name "$name" --read-only --tmpfs /tmp \
    -e CODE_INDEX_TOKEN="$token" -e CODE_INDEX_REFRESH_SECONDS=3 \
    -v "${worktrees}:${worktrees}:ro" -v "${REPO_ROOT}/tests/code-index-smoke.py:/smoke.py:ro" \
    "$tag" >/dev/null || fail "code-index container did not start"
  # shellcheck disable=SC2064  # expand now: the trap must remove this container
  trap "docker rm -f '$name' >/dev/null 2>&1" EXIT
  local i
  for i in $(seq 1 60); do
    [[ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null)" == healthy ]] && break
    sleep 1
  done
  docker exec "$name" python3 -I /smoke.py "$repo" compute_invoice_total >/dev/null 2>&1 \
    || fail "initial index failed:"$'\n'"$(docker logs "$name" 2>&1 | tail -20)"

  # An uncommitted host edit must become searchable without anyone re-indexing.
  printf '\n\ndef compute_refund_total(lines):\n    return -compute_invoice_total(lines)\n' >>"${repo}/billing.py"
  local found=""
  for i in $(seq 1 30); do
    if docker exec "$name" python3 -I /smoke.py find "$repo" compute_refund_total >/dev/null 2>&1; then
      found=1; break
    fi
    sleep 1
  done
  [[ -n "$found" ]] || fail "host edit not indexed within 30s:"$'\n'"$(docker logs "$name" 2>&1 | tail -20)"
  echo "    edit searchable after ~${i}s"
  docker logs "$name" 2>&1 | grep -q "refreshed " || fail "refresh loop did not log the re-index"

  # Removing the worktree drops its project within a cycle or two.
  rm -rf "$repo"
  local gone=""
  for i in $(seq 1 20); do
    if ! docker exec "$name" python3 -I /smoke.py projects 2>/dev/null | grep -qxF "$repo"; then
      gone=1; break
    fi
    sleep 1
  done
  [[ -n "$gone" ]] || fail "removed worktree still indexed after 20s:"$'\n'"$(docker logs "$name" 2>&1 | tail -20)"
  echo "    removed worktree pruned after ~${i}s"
  docker logs "$name" 2>&1 | grep -qF "$token" && fail "the bearer token appears in container logs"
  docker rm -f "$name" >/dev/null
}

# Compose contract for code-index: internal-only (no published port, only on an
# internal network shared with opencode), read-only code and root filesystem,
# bounded memory, no capabilities, and the bearer from the environment.
test_code_index_compose_contract() {
  local override="${REPO_ROOT}/overrides/opencode.server.json"
  python3 - "$override" <<'PYCHECK' || fail "overrides/opencode.server.json: code-index entry is not the expected remote MCP"
import json, sys
s = json.load(open(sys.argv[1]))["mcp"]["servers"]["code-index"]
assert s["type"] == "remote" and s["url"] == "http://code-index:8080/mcp" and s["oauth"] is False, s
assert s["headers"]["Authorization"] == "Bearer {env:CODE_INDEX_TOKEN}", "token must come from the env placeholder"
PYCHECK
  docker_compose_available || skip "docker/jq not on host - override checked, compose render skipped"
  local model
  model="$(render_compose docker-compose.yml)" || fail "docker compose config failed to render the base file"
  jq -e '
    .services["code-index"] as $ci
    | ($ci.ports // [] | length) == 0
    and ($ci.networks | keys) == ["code-index-net"]
    and .networks["code-index-net"].internal == true
    and (.services.opencode.networks | has("code-index-net"))
    and $ci.read_only == true
    and ($ci.cap_drop | index("ALL")) != null
    and ($ci.mem_limit | tostring | length) > 0
    and ($ci.environment.CODE_INDEX_TOKEN | length) > 0
    and ([$ci.volumes[] | select(.type == "bind") | .read_only == true] | all)
    and ([$ci.volumes[] | select(.type == "bind")] | length) == 2
    and ([$ci.volumes[] | select(.type == "volume") | .target] == ["/var/lib/code-index"])
    and (.services.opencode.environment.CODE_INDEX_TOKEN | length) > 0
  ' <<<"$model" >/dev/null \
    || fail "code-index compose contract broken:"$'\n'"$(jq -c '{ci: .services["code-index"] | {ports, networks, read_only, cap_drop, mem_limit, volumes}, net: .networks["code-index-net"]}' <<<"$model")"
}

run_test "base compose grants the opencode service no daemon access" test_base_compose_grants_no_daemon_access
run_test "sandbox overlay stays a socket control plane with no privileges" test_sandbox_overlay_is_socket_control_plane_only
run_test "ownership guard passes when the worktree owner matches" test_ownership_guard_passes_when_owner_matches
run_test "ownership guard is a no-op without a worktree root" test_ownership_guard_noops_without_a_worktree_root
run_test "ownership guard fails loudly on a foreign-owned worktree root" test_ownership_guard_fails_loudly_on_foreign_owner
run_test "entrypoint wires the ownership guard" test_entrypoint_wires_the_ownership_guard
run_test "docker tool pins are forwarded to the image build" test_docker_tool_pins_are_forwarded_to_the_image_build
run_test "image ships the client-side preflight toolchain" test_image_ships_the_preflight_toolchain
run_test "retired Milvus stack stays removed" test_retired_milvus_stack_stays_removed
run_test "code-index image pins are strict" test_code_index_image_pins_are_strict
run_test "code-index entrypoint requires a token" test_code_index_entrypoint_requires_a_token
run_test "code-index image serves authenticated MCP" test_code_index_image_serves_authenticated_mcp
run_test "code-index refreshes edits and prunes removed worktrees" test_code_index_refreshes_edits_and_prunes_removed_worktrees
run_test "code-index compose contract" test_code_index_compose_contract

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

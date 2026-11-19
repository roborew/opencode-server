#!/usr/bin/env bash
# Runs INSIDE the opencode-server image, as the invoking uid/gid and WITHOUT
# any Docker socket, asserting everything the oc-sandbox mountpoint preflight
# (opencode-config-v2) requires from the image:
#   1. `docker compose version` succeeds and reports a compose plugin
#   2. this fixture compose.yml renders: `config --profiles` lists the
#      declared profile; `--profile test config --format json` emits valid
#      JSON whose service volumes include the bind (absolute source) and the
#      sourceless nested anonymous volume — with DOCKER_HOST pointing at a
#      dead endpoint, proving the render is client-side only
#   3. the runtime uid/gid can create a directory in a mounted
#      worktree-shaped fixture path and stat it back with the same ownership
#   4. git is present for the preflight's missing-tracked-file check
# Exit 0 = all assertions pass. Invoked by tests/image-preflight.sh.
set -euo pipefail

EXPECTED_UID="${EXPECTED_UID:?EXPECTED_UID not set}"
EXPECTED_GID="${EXPECTED_GID:?EXPECTED_GID not set}"
PINNED_DOCKER_CLI="${PINNED_DOCKER_CLI:?PINNED_DOCKER_CLI not set}"
PINNED_COMPOSE="${PINNED_COMPOSE:?PINNED_COMPOSE not set}"
FX_DIR="${FX_DIR:-/work/preflight-compose}"
WT_FX="${WT_FX:-/work/wt-shape}"

step() { echo "[container] $*"; }
die() { echo "[container] FAIL: $*" >&2; exit 1; }

# Some CLIs probe $HOME even in read-only flows; keep them off the image user's
# home (which is owned by the build uid, not the invoking uid).
export HOME=/tmp/preflight-home
mkdir -p "$HOME"

step "runtime identity is the invoking uid/gid"
[[ "$(id -u)" == "$EXPECTED_UID" ]] || die "uid is $(id -u), expected ${EXPECTED_UID}"
[[ "$(id -g)" == "$EXPECTED_GID" ]] || die "gid is $(id -g), expected ${EXPECTED_GID}"

step "docker CLI in PATH, dockerd absent (CLI-only image)"
command -v docker >/dev/null || die "docker CLI not in PATH"
if command -v dockerd >/dev/null 2>&1; then
  die "dockerd is present — the image must ship the CLI only, never a daemon"
fi

step "pinned versions"
docker --version | grep -q "Docker version ${PINNED_DOCKER_CLI}," \
  || die "unpinned/unexpected docker CLI: $(docker --version)"
docker compose version | grep -q "Docker Compose version v${PINNED_COMPOSE}" \
  || die "unpinned/unexpected compose plugin: $(docker compose version)"

step "compose render is client-side (dead DOCKER_HOST)"
# The preflight never contacts a daemon; a dead endpoint must not matter.
export DOCKER_HOST=tcp://127.0.0.1:1
cd "$FX_DIR"
profiles="$(docker compose config --profiles)" || die "config --profiles failed"
grep -qx test <<<"$profiles" || die "declared profile 'test' missing from: ${profiles}"

model="$(docker compose --profile test config --format json)" \
  || die "config --format json failed"
jq -e --arg fx "$FX_DIR" '
  ([.services.app.volumes[]
     | select(.type == "bind" and .target == "/repo/apps/api")] | length) == 1
  and ([.services.app.volumes[]
     | select(.type == "bind" and .target == "/repo/apps/api")]
     | .[0].source == ($fx + "/apps/api"))
  and ([.services.app.volumes[]
     | select(.type == "volume" and .target == "/repo/apps/api/.venv")] | length) == 1
  and ([.services.app.volumes[]
     | select(.type == "volume" and .target == "/repo/apps/api/.venv")]
     | .[0].source == null or .[0].source == "")
' <<<"$model" >/dev/null \
  || die "rendered model lacks the absolute bind source or the sourceless nested anonymous volume: ${model}"

step "worktree-shaped mount: mkdir + stat ownership round-trip"
created="${WT_FX}/created-by-test"
mkdir -p "$created" || die "cannot create ${created} as $(id -u):$(id -g)"
# shellcheck disable=SC2012
# (ls -nd is the portable numeric-owner stat; find -printf is GNU-only)
owner="$(ls -nd "$created" | awk '{print $3":"$4}')"
[[ "$owner" == "${EXPECTED_UID}:${EXPECTED_GID}" ]] \
  || die "${created} is owned by ${owner}, expected ${EXPECTED_UID}:${EXPECTED_GID}"

step "git for the missing-tracked-file check"
git --version >/dev/null || die "git not in PATH"
# Ubuntu 24.04 (pinned base image) ships git 2.43.x from its archive.
git --version | grep -q "git version 2\.43\." \
  || die "unexpected git version: $(git --version)"
git init -q /tmp/git-fx
cd /tmp/git-fx
touch tracked-file
git add tracked-file
[[ "$(git ls-files)" == "tracked-file" ]] \
  || die "git ls-files output: $(git ls-files)"

echo "[container] all assertions passed"

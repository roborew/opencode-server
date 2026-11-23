# Spec: BuildKit-enabled sandbox image builds

Status: **Approved — implemented in source; Ubuntu deployment acceptance pending**

## Objective

Make slice sandbox image builds work from the deployed `opencode-server` container when app Dockerfiles use BuildKit features such as `RUN --mount`.

The investigated failure is client-side: the container has Docker CLI `29.10.0` and Compose `5.8.0`, but no `docker-buildx` plugin. Compose therefore falls back to the classic builder and fails with `the --mount option requires BuildKit` before the test container starts. The Ubuntu host already has a healthy BuildKit builder, but host Buildx does not supply the plugin to the container's Docker CLI.

This change will install and pin Buildx in the server image, preserve the existing `OC_SANDBOX_BACKEND=docker` execution path, and add regression and deployment verification. Success means the sandbox can build the images and execute the tests; an application test may still legitimately return RED.

### In scope

- Pin `docker-buildx-plugin` alongside the Docker CLI and Compose plugin.
- Install it in the Dockerfile's `server-tools` stage so both the final image and image-preflight tests receive it.
- Mirror the Buildx build argument in `docker-compose.yml`, consistent with the existing CLI and Compose pins.
- Assert the installed Buildx version in the existing image-preflight suite.
- Document the requirement and the container-side failure mode.
- Rebuild/recreate only the `opencode` service on the Ubuntu deployment and verify a real BuildKit build through the mounted socket.

### Out of scope

- Installing or upgrading Buildx on the Ubuntu host.
- Changing Sysbox, `sysbox-runc`, Docker daemon, time-namespace, or `OC_SANDBOX_BACKEND` configuration.
- Implementing the planned Sysbox sidecar.
- Changing application Dockerfiles, compose contracts, app repositories, worktrees, or slice records.
- Fixing application test failures uncovered after the image build succeeds.
- Using `docker cp` as the permanent fix; a binary copied into a running container is ephemeral and is not part of this change.

## Tech Stack

- Docker image based on `ubuntu:24.04`.
- Docker CLI `29.10.0` from the Ubuntu Noble Docker apt repository.
- Docker Compose plugin `5.8.0` from the same repository.
- Docker Buildx plugin `0.39.1`, pinned with `DOCKER_BUILDX_VERSION` and installed as `docker-buildx-plugin="0.39.1-1~ubuntu.24.04~noble"` by default.
- Bash regression tests using the repository's existing `run_test`, `PASS`/`FAIL`/`SKIP`, and fail-closed assertion style.
- Existing `oc-sandbox` docker backend; no plugin or TypeScript changes are required.

If `0.39.1` is unavailable for a supported build architecture, the build must fail visibly and the pin must be deliberately updated; installation must not silently select another version.

## Commands

Run from the repository root.

```bash
# Shell syntax checks for the changed test scripts
bash -n tests/image-preflight.sh tests/container-preflight-assertions.sh

# Focused image/preflight regression coverage
TEST_FILTER="image ships" ./tests/image-preflight.sh

# Full image and deployment-contract regression suite
./tests/image-preflight.sh

# Broader existing setup regression suite
./tests/setup-regression.sh
```

Ubuntu deployment, using the Infisical-aware wrapper required by this repository:

```bash
./scripts/compose.sh build --no-cache opencode && ./scripts/compose.sh up -d opencode

docker exec opencode-server docker buildx version
docker exec opencode-server docker compose version
docker inspect opencode-server --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{end}} oom={{.State.OOMKilled}}'
```

End-to-end BuildKit check inside the deployed container, without touching an app worktree:

```bash
docker exec opencode-server sh -lc 'mkdir -p /tmp/bxcheck && cd /tmp/bxcheck && printf "FROM python:3.13-slim\nRUN --mount=type=cache,target=/tmp/c true\n" > Dockerfile && printf "services:\n  t:\n    build: .\n" > compose.yml && docker compose -p bxcheck build'
```

Expected: exit `0`, BuildKit build output, and no `falling back to the classic builder` warning. Clean up only this throwaway project:

```bash
docker exec opencode-server sh -lc 'cd /tmp/bxcheck && docker compose -p bxcheck down --rmi local && rm -rf /tmp/bxcheck'
```

After these checks pass, resume the blocked slice through its normal OpenCode flow and verify that `api-test` builds and runs. Do not interpret an application assertion failure as a remaining BuildKit/environment failure.

## Project Structure

- `Dockerfile` — Buildx version argument, package installation, and build-time version assertion in `server-tools`.
- `docker-compose.yml` — matching `DOCKER_BUILDX_VERSION` build argument and default.
- `tests/image-preflight.sh` — reads the Buildx pin and passes it into the in-container assertions.
- `tests/container-preflight-assertions.sh` — requires and verifies `docker buildx version`; existing no-socket/client-only assertions remain intact.
- `docs/sandbox.md` — documents Buildx in the pinned server toolchain and its sandbox build consumer.
- `docs/troubleshooting.md` — records the classic-builder/`RUN --mount` symptom and the image rebuild remedy.
- `docs/sandbox-buildx-spec.md` — this specification.

## Code Style

Follow the existing multiline Dockerfile `RUN`, apt pin, Bash variable, and failure-message conventions. The intended shape is:

```dockerfile
ARG DOCKER_CLI_VERSION=29.10.0
ARG DOCKER_COMPOSE_VERSION=5.8.0
ARG DOCKER_BUILDX_VERSION=0.39.1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    docker-ce-cli="5:${DOCKER_CLI_VERSION}-1~ubuntu.24.04~noble" \
    docker-compose-plugin="${DOCKER_COMPOSE_VERSION}-1~ubuntu.24.04~noble" \
    docker-buildx-plugin="${DOCKER_BUILDX_VERSION}-1~ubuntu.24.04~noble" \
    && docker --version \
    && docker compose version \
    && docker buildx version \
    && rm -rf /var/lib/apt/lists/*
```

The corresponding test assertion should make a missing or unexpected plugin fail with actionable output, for example:

```bash
docker buildx version | grep -q "github.com/docker/buildx v${PINNED_BUILDX}" \
  || die "unpinned/unexpected buildx plugin: $(docker buildx version 2>&1)"
```

Keep comments focused on why the server CLI needs Buildx even though the daemon is remote. Do not add environment workarounds such as `DOCKER_BUILDKIT=1`; they do not install the missing plugin.

## Testing Strategy

1. **Regression-first:** add the Buildx argument and in-container version assertion so the unmodified image fails the new check because `docker buildx` is absent.
2. **Image content:** build the `server-tools` target and run the existing assertions as the invoking uid/gid, with no Docker socket. `docker buildx version` must report exactly the pinned version. Existing checks must continue to prove that `dockerd` is absent and Compose model rendering is client-side.
3. **Deployment contract:** retain all base/overlay assertions for no unintended socket, privilege, or `user:` grants. Rendered Compose configuration must expose the Buildx build argument with the expected default.
4. **Real build verification:** on the Ubuntu deployment, run the throwaway Compose build containing `RUN --mount`. This is the test that proves the container CLI and host daemon now use BuildKit together; the no-socket image test alone cannot prove it.
5. **Sandbox acceptance:** rerun the blocked slice's `sandbox_test` for `api-test`. The image-build warning/error must be gone and the test process must execute. Record the resulting RED/GREEN evidence normally.
6. **Regression breadth:** run the complete `tests/image-preflight.sh` and `tests/setup-regression.sh`. A locally unavailable Docker daemon must remain a visible `SKIP` where the existing suite defines one, never a claimed PASS; Ubuntu end-to-end acceptance cannot be marked complete from a SKIP.

## Boundaries

### Always do

- Use `./scripts/compose.sh` for deployment commands so Infisical secrets are injected.
- Keep Buildx pinned and verify the exact installed version.
- Preserve the CLI-only image boundary: no `dockerd`, no new socket in the base compose file, no `privileged:`, and no compose `user:` override.
- Keep test projects and cleanup limited to the dedicated `bxcheck` name/path.
- Report source validation separately from Ubuntu deployment acceptance.
- Update the sandbox/troubleshooting documentation with the behavior change.

### Ask first

- Changing the proposed Buildx pin or supporting a different apt repository/version scheme.
- Changing backend selection, Sysbox configuration, compose socket mounts, or app-owned files.
- Adding another package or changing CI configuration.
- Resuming, deleting, or otherwise mutating a blocked slice's application work.

### Never do

- Run `docker compose down -v`, `./scripts/wipe-opencode-data.sh`, or bare `docker compose` for the deployment.
- Install packages on the host as a substitute for fixing the container image.
- Copy a host Buildx binary into the running container as the permanent solution.
- Read, print, or commit `.env` contents or other secrets.
- Remove or weaken existing assertions to make the suite pass.
- Claim sandboxes are fixed merely because `docker buildx version` succeeds; the `RUN --mount` Compose build is required.

## Success Criteria

- [x] `Dockerfile` installs `docker-buildx-plugin` using a deliberate `DOCKER_BUILDX_VERSION` pin and fails the image build if `docker buildx version` is unavailable.
- [x] `docker-compose.yml` forwards the same Buildx build argument/default pattern used for the other Docker tools.
- [x] The image-preflight suite verifies the exact Buildx version and all pre-existing checks still pass, with any unavailable prerequisite reported as SKIP rather than PASS.
- [x] Documentation identifies Buildx as required server-image tooling and explains why installing it only on the host is insufficient.
- [ ] After Ubuntu image rebuild/recreate, `docker exec opencode-server docker buildx version` reports `v0.39.1` (or a separately approved pin), and the server remains running and healthy.
- [x] The throwaway in-container Compose build using `RUN --mount` exits `0` without the classic-builder fallback warning.
- [ ] The blocked slice's `api-test` image builds and its test command starts; there is no `the --mount option requires BuildKit` failure. A subsequent application RED/GREEN result is valid sandbox evidence, not an environment blocker.
- [x] No volumes, app repositories, worktrees, backend settings, Sysbox settings, or secrets are changed.

### Validation record

- `TEST_FILTER='docker tool pins' ./tests/image-preflight.sh` — passed after the RED contract failure was confirmed.
- `./tests/image-preflight.sh` — 8 passed, 0 failed, 0 skipped; the built `server-tools` image reported Buildx `v0.39.1`.
- `./tests/setup-regression.sh` — 20 passed, 0 failed.
- In-container throwaway Compose project using `RUN --mount` — BuildKit built the image successfully with no classic-builder fallback warning; throwaway project and image were removed.
- Ubuntu deployment rebuild/recreate and the blocked slice's `api-test` run remain to be performed against the deployed host.

## Rollback

If the rebuilt server fails its health check or the new package introduces a regression, revert only the Buildx-related source edits and run:

```bash
./scripts/compose.sh build --no-cache opencode && ./scripts/compose.sh up -d opencode
```

Alternatively, recreate `opencode` from the previously recorded known-good image without deleting volumes. Do not roll back by wiping server data or modifying the host's Docker/Sysbox configuration.

## Open Questions

None. The report identifies the failing client, the missing plugin, an available Noble package version, and the required acceptance path. Approval of this spec includes approval of Buildx `0.39.1` as the initial pin and of the scoped Ubuntu image rebuild/recreate during implementation.

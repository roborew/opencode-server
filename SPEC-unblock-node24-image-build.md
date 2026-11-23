# Spec: Unblock the Node 24 OpenCode Server Image Build

Status: **Implemented — awaiting review**

Source prompt: [`prompt-fix-node24-image-build.md`](prompt-fix-node24-image-build.md)

## 1. Objective

Restore a reproducible, working `docker build .` for the full `opencode-server` image so configuration updates, OpenCode upgrades, disaster recovery, and fresh deployments can rebuild the image again.

The immediate failure is the global installation of `@zilliz/claude-context-mcp@latest`: its `tree-sitter@0.21.1` dependency compiles from source and fails against recent Node 24 V8 headers. The operator does not use server-side Claude Context, so this change selects **Option A: remove the unused preinstall and explicitly disable the MCP server**, rather than carrying a fragile native dependency override or reverting Node.

Success means:

- The complete final image builds without `--target`.
- Node remains on an exactly pinned Node 24 release.
- The built server starts and answers on the delete-guard proxy port.
- Claude Context is disabled in the effective server configuration and its missing binary cannot be invoked.
- The `server-tools` stage and all existing setup/image regression contracts remain intact.
- Documentation accurately describes the server-side capability as disabled.
- One focused PR is opened against current `main` and is not merged or deployed.

### Selected decision and rationale

| Alternative                                              | Decision                 | Reason                                                                                         |
| -------------------------------------------------------- | ------------------------ | ---------------------------------------------------------------------------------------------- |
| Remove the Claude Context preinstall and disable the MCP | **Selected**             | Removes the broken native build and matches current operator usage.                            |
| Pin a newer Claude Context release                       | Rejected for this change | Latest stable MCP/core is `0.1.16`; core `0.1.17-rc.0` still depends on `tree-sitter@^0.21.1`. |
| Override the transitive tree-sitter version              | Rejected for this change | Requires proving core/runtime compatibility beyond merely compiling the native module.         |
| Revert to Node 22                                        | Rejected                 | Current `opencode-config-v2` declares `engines.node: ">=24"`.                                  |

Re-enabling server-side Claude Context later requires reverting this change and choosing a Node-24-compatible release, or otherwise implementing and validating a separate repair. That is explicitly out of scope.

## 2. Tech Stack

- Docker / Dockerfile multi-stage build
- Ubuntu `24.04` base image
- Node.js **`24.22.2`**, downloaded from the official versioned nodejs.org artifact
- npm, used by the cloned config repository's `npm ci`
- OpenCode CLI **`2.3.0`** (unchanged)
- Python 3 for entrypoint/config helpers
- Bash regression tests in `tests/`
- OpenCode JSONC configuration plus the deployment-owned JSON override

Pinned Docker CLI, Docker Compose plugin, Infisical, yq, and OpenCode versions are existing contracts and must not be changed.

## 3. Commands

Run from the repository root.

### Prepare the work

```bash
git fetch origin
git switch -c fix/unblock-image-build origin/main
git --no-optional-locks status --short --branch
```

If the branch already exists, resume it instead of recreating it. Do not discard existing work.

### Build the complete final image

```bash
docker build --progress=plain -t opencode-server:node24-fix .
```

This intentionally has no `--target`; it includes the config-repository clone, `npm ci`, and OpenCode installer.

### Run existing regression suites

```bash
./tests/image-preflight.sh
bash tests/setup-regression.sh
```

Required results on the implementation machine:

- `image-preflight.sh`: **7 passed, 0 failed**, with no required check hidden by a SKIP.
- `setup-regression.sh`: **20 passed, 0 failed**.

### Smoke-test the final image

```bash
SMOKE_XDG="$(mktemp -d)"
docker run --rm -d --name opencode-build-smoke \
  -e OPENCODE_UID="$(id -u)" \
  -e OPENCODE_GID="$(id -g)" \
  -e INFISICAL_USE_CLI=false \
  -v "${SMOKE_XDG}:/var/opencode-xdg" \
  opencode-server:node24-fix
sleep 20
docker exec opencode-build-smoke curl -sS -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:4097/api/info
docker exec opencode-build-smoke node --version
docker exec opencode-build-smoke docker compose version
docker exec opencode-build-smoke sh -c '! command -v claude-context-mcp'
docker exec opencode-build-smoke python3 -c \
  'import json; p="/home/opencode/.config/opencode/opencode.jsonc"; c=json.load(open(p)); assert c["mcp"]["servers"]["claude-context"]["disabled"] is True'
docker rm -f opencode-build-smoke
rm -rf "${SMOKE_XDG}"
```

The API status must be `200` or `401`; Node must report `v24.22.2`. The Compose version command must succeed, the Claude Context binary lookup must fail, and the effective-config assertion must pass. If the smoke container exits early, inspect `docker logs opencode-build-smoke` before changing code.

### Open the PR

```bash
git --no-optional-locks status --short
git --no-pager diff --check
git --no-pager diff
gh pr create --base main
```

The PR body must identify Option A, list the exact Node pin, include the Claude Context override change, record all build/test/smoke results, and state the re-enablement trade-off. Do not merge the PR or recreate the deployed service as part of this work.

## 4. Project Structure

| Path                                 | Role in this change                                                                                |
| ------------------------------------ | -------------------------------------------------------------------------------------------------- |
| `Dockerfile`                         | Pin Node exactly; remove the broken MCP preinstall and stale comments; preserve both build stages. |
| `docker-compose.yml`                 | Expose `NODE_VERSION` as a Compose build arg without changing existing pins or runtime wiring.     |
| `overrides/opencode.server.json`     | Explicitly disable the registered `claude-context` MCP server.                                     |
| `docker/merge-config.py`             | Existing deep-merge behavior; reference only, no change expected.                                  |
| `docker/entrypoint.sh`               | Applies the override before startup; reference only, no change expected.                           |
| `tests/image-preflight.sh`           | Existing seven-test stage/image contract; must remain unchanged and green.                         |
| `tests/setup-regression.sh`          | Existing twenty-test setup regression suite; must remain unchanged and green.                      |
| `docs/integrations.md`               | Explain that server-side Claude Context is disabled and absent from the image.                     |
| `docs/access.md`                     | Remove assumptions that the Docker server currently runs Claude Context.                           |
| `docs/troubleshooting.md`            | Keep only troubleshooting applicable to the disabled server-side integration or host-side use.     |
| `docs/environment.md`                | Document `NODE_VERSION` and its deliberate-bump/rebuild behavior.                                  |
| `README.md`, `AGENTS.md`             | Update only statements made false by removing the server-side MCP; avoid unrelated edits.          |
| `SPEC-unblock-node24-image-build.md` | Approved source of truth for this change.                                                          |

The external `opencode-config-v2` repository is read for verification only. Its current `opencode.jsonc` does not define `claude-context`; the deployment override owns that entry.

## 5. Implementation Requirements and Code Style

### Dockerfile

- Introduce `ARG NODE_VERSION=24.22.2` in `server-tools` beside the other pinned tool versions.
- Replace all `latest-v24.x` downloads and version discovery with:
  `https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz`.
- Preserve architecture selection, extraction location, PATH behavior, and `node --version` / `npm --version` build output.
- Delete `RUN npm install -g @zilliz/claude-context-mcp@latest` completely. Do not replace it with another version or an npm override.
- Remove or rewrite every comment that claims native dependencies need no Node 24 rebuild or refers to a now-removed Claude Context preinstall, including the stage-boundary comments.
- Keep `FROM server-tools` as the final-stage boundary. Do not move the OpenCode install or config clone into `server-tools`.
- Do not change the Docker CLI, Compose plugin, OpenCode, Infisical, or yq pins.

Dockerfiles follow the existing continued-`RUN` style, explicit failure behavior, pinned versions, and comments that explain non-obvious constraints rather than restating commands.

### Compose and configuration

Add the matching Compose build arg without changing unrelated values:

```dockerfile
# docker-compose.yml build.args entry
NODE_VERSION: ${NODE_VERSION:-24.22.2}
```

Keep the full Claude Context override so its intended state is discoverable, but make `disabled` explicit:

```json
"claude-context": {
  "disabled": true,
  "type": "local",
  "command": ["claude-context-mcp"],
  "timeout": { "execution": 120000 },
  "environment": {
    "OPENAI_API_KEY": "{env:OPENAI_API_KEY}",
    "MILVUS_ADDRESS": "{env:MILVUS_ADDRESS}",
    "MILVUS_TOKEN": "{env:MILVUS_TOKEN}",
    "EMBEDDING_PROVIDER": "{env:EMBEDDING_PROVIDER}"
  }
}
```

The environment placeholders may remain: disabled prevents the command from starting, while retaining the definition makes a future deliberate repair understandable. Do not remove or disable the Milvus services in this PR; they are independent optional infrastructure.

Use existing two-space JSON indentation and concise configuration comments. Do not add dependencies, generated lockfiles, or a new test framework.

## 6. Testing Strategy

This is an infrastructure build regression; the **full final-stage build and final-image smoke test are the primary acceptance tests**. Existing shell suites guard unrelated setup and image contracts and must not be weakened or rewritten to accommodate this change.

| Level                     | What it proves                                                                                                                          | Required evidence                                               |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| Static diff review        | No `@zilliz/claude-context-mcp@latest`, no `latest-v24.x`, and no stale preinstall claims remain in active build instructions/comments. | `git diff --check` and reviewed focused diff.                   |
| `server-tools` regression | The preflight target still builds independently; Docker CLI/Compose and ownership contracts remain intact.                              | 7 passed, 0 failed.                                             |
| Setup regression          | Project-selection and setup behavior is untouched.                                                                                      | 20 passed, 0 failed.                                            |
| Full image build          | The original tree-sitter failure is gone and all later layers still succeed.                                                            | Successful tagged `docker build`, with no `--target`.           |
| Runtime smoke             | Entrypoint, merge, upstream server, delete guard, Node, and Compose work in the produced image.                                         | HTTP 200/401; Node `v24.22.2`; Compose version succeeds.        |
| Option-A behavior         | The removed binary cannot accidentally back an enabled MCP registration.                                                                | Binary absent and effective merged config has `disabled: true`. |

A later unrelated network or upstream failure must be reported with its exact output; it must not be hidden by skipping the full build or claiming success from the `server-tools` target alone.

No new permanent tests are required for this focused PR. The two existing suite totals should therefore remain unchanged.

## 7. Boundaries

### Always

- Read and follow `AGENTS.md`; it takes precedence over operator-facing documentation for agent behavior.
- Start from freshly fetched `origin/main` (currently `a65e5ed`) and keep the PR focused on this fix.
- Preserve `server-tools`, the Docker CLI/Compose pins, the worktree ownership guard, and their tests.
- Run every required validation command and put truthful evidence in the PR body.
- Keep the deployed stack and named volumes untouched; local build/smoke containers only.
- Update documentation that describes the removed runtime behavior.

### Ask first

- Choosing Option B or otherwise reinstalling/enabling Claude Context.
- Changing Node away from `24.22.2`, changing any other pinned tool version, or adding dependencies.
- Modifying the external config repository, Rekalled, the Sysbox box image, or merged PR #5 contracts.
- Removing Milvus, changing Compose profiles, deploying the rebuilt image, or wiping/recreating persistent state.
- Adding a new permanent test suite or changing existing test expectations.

### Never

- Never run `docker compose down -v` or otherwise delete `opencode-data`.
- Never use bare `docker compose` for secret-injected stack operations; use `./scripts/compose.sh` if a stack operation is separately approved.
- Never use `@latest`, `latest-vXX.x`, or another moving target for the Node/MCP artifacts.
- Never remove `FROM server-tools`, bypass the final-stage build, disable tests, or hide a SKIP/failure.
- Never modify host `~/.config/opencode`, mount it into the container, commit secrets, merge the PR, or deploy automatically.

## 8. Success Criteria

1. On a branch based on current `origin/main`, `docker build --progress=plain -t opencode-server:node24-fix .` completes successfully with no target restriction.
2. The Dockerfile and Compose build args resolve Node to exactly `24.22.2`; no `latest-v24.x` reference remains.
3. The global Claude Context MCP install layer is absent, and `claude-context-mcp` is not present in the built image.
4. `overrides/opencode.server.json` retains the server definition with `"disabled": true`; the effective merged config confirms that value at runtime.
5. Node/npm remain available for the config repo and OpenCode, and the final image serves HTTP `200` or `401` on `127.0.0.1:4097/api/info`.
6. `docker compose version` succeeds inside the built image, proving the preflight toolchain survives.
7. `./tests/image-preflight.sh` reports **7 passed, 0 failed** and no hidden required SKIP.
8. `bash tests/setup-regression.sh` reports **20 passed, 0 failed**.
9. Documentation no longer says this server image enables or contains Claude Context; `NODE_VERSION` update/rebuild behavior is documented.
10. The PR contains only the fix, its pinning/documentation truthing, and this spec; its body includes validation evidence and the re-enablement trade-off. It remains unmerged and undeployed.

## 9. Open Questions

None. Option A, the Node 24 pin, validation requirements, and non-deployment boundary are defined above.

Implementation planning must wait for explicit approval of this spec.

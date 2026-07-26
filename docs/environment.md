# Environment variables

## Local development (Infisical-first)

**Supported start path:** [`./scripts/compose.sh`](../scripts/compose.sh) (wraps `infisical run -- docker compose …`). Prefer that over bare `docker compose` so Compose interpolation (e.g. `TWINGATE_*`) gets secrets from Infisical at start.

### Host Infisical CLI

Required for `./scripts/compose.sh`. Install once on the machine that runs Compose:

| OS | Install |
| -- | ------- |
| macOS | `brew install infisical/get-cli/infisical` |
| Ubuntu / Debian | `curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' \| sudo -E bash` then `sudo apt-get update && sudo apt-get install -y infisical` |

Official docs: [Infisical CLI install](https://infisical.com/docs/cli/overview). Linux apt repos use `artifacts-cli.infisical.com` (not the old Cloudsmith URL).

| Where | What |
| ----- | ---- |
| Host `.env` | Infisical bootstrap (`INFISICAL_*`) + non-secret local config (paths, ports, `COMPOSE_PROFILES`, `OPENCODE_UID`/`GID`) |
| Infisical project | Runtime secrets: `TWINGATE_*`, `OPENCODE_SERVER_PASSWORD`, API keys, `GH_*`, git identity, etc. |

Do **not** bake secrets into the Docker image. Do **not** permanently `infisical export` / env-pull into `.env` for this stack.

| Variable | Purpose |
| -------- | ------- |
| `OPENCODE_SERVER_PASSWORD` | HTTP basic auth (store in Infisical; optional host copy for preflight auth checks) |
| `OPENCODE_SERVER_USERNAME` | Basic auth username (default `opencode`) |
| `OPENCODE_UID`, `OPENCODE_GID` | Host UID/GID the container drops to after startup (bind-mount file ownership). `compose.sh` / setup/preflight auto-fills from the logged-in user; leave unset unless you need a pin |
| `OPENCODE_USERNAME` | Optional host username; setup resolves UID/GID via `id -u`/`id -g` when numeric IDs are unset |
| `TWINGATE_*` | Connector credentials — store in Infisical; injected into Compose via `./scripts/compose.sh` |
| `OPENAI_API_KEY` | Claude Context embeddings (Infisical) |
| `OPENROUTER_API_KEY` | Model provider (Infisical; or persisted auth volume) |
| `GH_TOKEN`, `GH_ORG`, `GH_PROJECT` | GitHub CLI / project board workflows |
| `GIT_USER_NAME`, `GIT_USER_EMAIL` | Git author/committer for agent commits in the container |
| `CODERABBIT_API_KEY` | CodeRabbit CLI agent reviews |
| `MILVUS_TOKEN` | Milvus auth (default `local` for standalone) |
| `CONFIG_REPO`, `CONFIG_REF` | GitHub config clone at build time |
| `COMPOSE_PROFILES` | Default `milvus` starts etcd/minio/milvus; clear to run OpenCode without the vector stack |
| `OPENCODE_PUBLISH_PORT` | Host port for OpenCode (default `4097`; avoid `4096` — Kilo) |
| `OPENCODE_OAUTH_CALLBACK_PUBLISH` | Host bind for MCP OAuth callback (default `127.0.0.1:19876`) |
| `OPENCODE_APPS_DIR` | Host path for git repos — same-path bind (default `${HOME}/projects`; absolute path required) |
| `OPENCODE_WORKTREES_DIR` | Host worktree dir ending in `/opencode/worktree` (default `~/.local/share/opencode/worktree`) |
| `MILVUS_PUBLISH_PORT` | Host port for Milvus gRPC (empty = not published) |
| `MILVUS_HEALTH_PUBLISH_PORT` | Host port for Milvus health endpoint |
| `MINIO_API_PUBLISH_PORT` | Host port for MinIO API |
| `MINIO_CONSOLE_PUBLISH_PORT` | Host port for MinIO console |
| `DOCKER_HOST_INTERNAL` | Hostname containers use to reach the Docker host (default `host.docker.internal`) |
| `LOCALHOST_REWRITE` | Rewrite loopback URLs to `DOCKER_HOST_INTERNAL` before tools run (default `1`; set `0` to disable) |

See [`.env.example`](../.env.example) for the full template, including sandbox and Infisical keys.

### Preflight vs Infisical-only host `.env`

Host preflight reads **host** `.env`. If `OPENCODE_SERVER_PASSWORD` exists only in Infisical, the password / health-auth check may fail even when the container is fine (entrypoint injects the password inside). Prefer verifying with container logs or an authenticated curl using the Infisical password, or keep a host copy of that one value for preflight.

## Deployed environments (Infisical)

Two injection points (both runtime — never build-time):

1. **Compose start** — `./scripts/compose.sh` runs `infisical run -- docker compose …` so host-side interpolation (Twingate connector, etc.) sees project secrets.
2. **opencode container** — the image includes the Infisical CLI; the entrypoint wraps `opencode serve` with `infisical run` when bootstrap is configured.

- If `INFISICAL_PROJECT_ID` + `INFISICAL_DOMAIN` (or `INFISICAL_API_URL`) + auth are set → secrets inject at runtime.
- Otherwise → uses compose `.env` values directly (local fallback).

**Infisical bootstrap** (set on the host / platform; secrets live in Infisical):

| Variable | Description |
| -------- | ----------- |
| `INFISICAL_PROJECT_ID` | Infisical project ID |
| `INFISICAL_ENV` | Environment slug (`dev`, `staging`, `prod`) |
| `INFISICAL_DOMAIN` or `INFISICAL_API_URL` | e.g. `https://eu.infisical.com` |
| `INFISICAL_CLIENT_ID` + `INFISICAL_CLIENT_SECRET` | Universal Auth machine identity |
| `INFISICAL_TOKEN` | Alternative to client id/secret |

Store in Infisical: `TWINGATE_*`, `OPENCODE_SERVER_PASSWORD`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GH_*`, `GIT_USER_NAME`, `GIT_USER_EMAIL`, `CODERABBIT_API_KEY`, etc.

Set `INFISICAL_USE_CLI=false` to force local `.env` only for the **opencode** entrypoint (Compose wrapper still needs Infisical when you use `compose.sh`).

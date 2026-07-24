# Environment variables

## Local development

All runtime secrets go in `.env` (gitignored). Compose loads it via `env_file: .env`.

| Variable | Purpose |
| -------- | ------- |
| `OPENCODE_SERVER_PASSWORD` | HTTP basic auth for the server |
| `OPENCODE_SERVER_USERNAME` | Basic auth username (default `opencode`) |
| `TWINGATE_*` | Connector credentials |
| `OPENAI_API_KEY` | Claude Context embeddings |
| `OPENROUTER_API_KEY` | Model provider (if not in persisted auth volume) |
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

## Deployed environments (Infisical)

The image includes the Infisical CLI. The entrypoint wraps the server with Infisical when configured:

- If `INFISICAL_PROJECT_ID` + `INFISICAL_DOMAIN` (or `INFISICAL_API_URL`) + auth are set → `infisical run` injects secrets at runtime.
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

Set `INFISICAL_USE_CLI=false` to force local `.env` only.

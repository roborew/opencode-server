# OpenCode + Twingate + Milvus (unified stack)

Self-contained Docker Compose stack for a headless OpenCode server, Twingate remote access, and Milvus-backed `claude-context` indexing.

**Build and run only from this directory.** Agents, skills, and `opencode.json` are cloned from [github.com/roborew/opencode](https://github.com/roborew/opencode) at image build time. Your local `~/.config/opencode` checkout is never modified.

## What's in the stack

| Service | Role |
|---------|------|
| `opencode-server` | `opencode serve` on `0.0.0.0:4096` |
| `twingate-connector` | Proxies remote clients to `opencode-server:4096` |
| `milvus-standalone` + etcd + minio | Vector store for `claude-context` MCP |

## Prerequisites

- Docker Desktop (or Docker Engine + Compose v2)
- Twingate connector tokens ([Admin Console](https://www.twingate.com/docs/deploy-connector-with-docker-compose))
- Stop legacy stacks before starting (container name / port conflicts):

```bash
cd ../twingate && docker compose down
cd ../milvus && docker compose down
```

## Quick start (local `.env`)

1. Copy env template and fill in secrets:

```bash
cp .env.example .env
# Edit .env — at minimum: OPENCODE_SERVER_PASSWORD, TWINGATE_*, OPENAI_API_KEY
```

2. Reuse existing Milvus data (optional):

```bash
# In .env (default in .env.example)
DOCKER_VOLUME_DIRECTORY=../milvus
```

3. Build and start:

```bash
docker compose up -d --build
```

4. Verify:

```bash
# Milvus health (when MILVUS_HEALTH_PUBLISH_PORT is set in .env)
curl -sf http://localhost:9091/healthz

# OpenCode (when OPENCODE_PUBLISH_PORT is set in .env)
curl -sf -u "opencode:YOUR_PASSWORD" http://localhost:4096/global/health

# Or via Twingate resource (see below)
```

## Environment variables

### Local development

All runtime secrets go in `.env` (gitignored). Compose loads it via `env_file: .env`.

| Variable | Purpose |
|----------|---------|
| `OPENCODE_SERVER_PASSWORD` | HTTP basic auth for the server |
| `OPENCODE_SERVER_USERNAME` | Basic auth username (default `opencode`) |
| `TWINGATE_*` | Connector credentials |
| `OPENAI_API_KEY` | Claude Context embeddings |
| `OPENROUTER_API_KEY` | Model provider (if not in persisted auth volume) |
| `GH_TOKEN`, `GH_ORG`, `GH_PROJECT` | GitHub CLI / project board workflows |
| `MILVUS_TOKEN` | Milvus auth (default `local` for standalone) |
| `CONFIG_REPO`, `CONFIG_REF` | GitHub config clone at build time |
| `OPENCODE_PUBLISH_PORT` | Host port for OpenCode (default `4096`; bind e.g. `127.0.0.1:4096` to limit exposure) |
| `MILVUS_PUBLISH_PORT` | Host port for Milvus gRPC (empty = not published) |
| `MILVUS_HEALTH_PUBLISH_PORT` | Host port for Milvus health endpoint |
| `MINIO_API_PUBLISH_PORT` | Host port for MinIO API |
| `MINIO_CONSOLE_PUBLISH_PORT` | Host port for MinIO console |

### Deployed environments (Infisical)

The image includes the Infisical CLI. The entrypoint mirrors [fidget-web/docker/docker-entrypoint.sh](https://github.com/roborew/fidget/blob/main/fidget-web/docker/docker-entrypoint.sh):

- If `INFISICAL_PROJECT_ID` + `INFISICAL_DOMAIN` (or `INFISICAL_API_URL`) + auth are set → `infisical run` injects secrets at runtime.
- Otherwise → uses compose `.env` values directly (local fallback).

**Infisical bootstrap** (set on the host / platform; secrets live in Infisical):

| Variable | Description |
|----------|-------------|
| `INFISICAL_PROJECT_ID` | Infisical project ID |
| `INFISICAL_ENV` | Environment slug (`dev`, `staging`, `prod`) |
| `INFISICAL_DOMAIN` or `INFISICAL_API_URL` | e.g. `https://eu.infisical.com` |
| `INFISICAL_CLIENT_ID` + `INFISICAL_CLIENT_SECRET` | Universal Auth machine identity |
| `INFISICAL_TOKEN` | Alternative to client id/secret |

Store in Infisical: `TWINGATE_*`, `OPENCODE_SERVER_PASSWORD`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GH_*`, etc.

Set `INFISICAL_USE_CLI=false` to force local `.env` only.

## Twingate resource

In the Twingate Admin Console:

1. Use the remote network for this connector.
2. Add a **Resource** with address: `opencode-server:4096`
3. Assign to your user/group.

From any machine on the Twingate network:

```bash
# OpenAPI spec
open http://opencode-server:4096/doc

# Attach TUI
opencode attach http://opencode-server:4096
# Username: opencode (or OPENCODE_SERVER_USERNAME)
# Password: OPENCODE_SERVER_PASSWORD
```

For Twingate-only access you do not need to reach OpenCode on the host — use the Twingate resource. To limit exposure to localhost, set `OPENCODE_PUBLISH_PORT=127.0.0.1:4096` in `.env`.

## Project workspace

Apps are mounted at `/workspace/apps` (default host path: `~/05_Repos/01_PROJECTS/apps`).

OpenCode registers **git repository roots**, not parent folders:

- Good: `/workspace/apps/fidget/fidget-web`
- Bad: `/workspace/apps/fidget`

List discoverable repos inside the container:

```bash
docker exec opencode-server find /workspace/apps -name .git -type d -prune
```

## Config updates

| Change | Action |
|--------|--------|
| Agents/skills in `roborew/opencode` | Push to GitHub → `docker compose build --no-cache opencode && docker compose up -d` |
| Container MCP/workspace overrides | Edit `overrides/opencode.server.json` → rebuild |
| Local CLI config | Edit `~/.config/opencode` as usual (unaffected by this stack) |

## Local CLI + shared Milvus

When this stack is running, Milvus is published on `localhost:19530`. Your local shell can keep:

```bash
export MILVUS_ADDRESS=http://localhost:19530
export MILVUS_TOKEN=local
```

Local `opencode` and the Docker server can share the same vector index.

## Troubleshooting

| Issue | Check |
|-------|-------|
| Container name conflict | `docker compose down` in `../twingate` and `../milvus` |
| Build fails on `git clone` | Verify `CONFIG_REF` branch exists on GitHub |
| Claude Context fails | `OPENAI_API_KEY` set; Milvus healthy on `milvus-standalone:19530` inside network |
| Twingate can't reach server | Both services on `opencode-net`; resource address is `opencode-server:4096` |
| Provider auth missing | Fresh `opencode-data` volume — set API keys in `.env`/Infisical or migrate auth data |

## Files

```
.
├── Dockerfile
├── docker-compose.yml
├── docker/entrypoint.sh       # Infisical wrapper + merge-config + container defaults
├── docker/merge-config.py     # Deep-merge overrides into cloned opencode.json
├── overrides/opencode.server.json
└── .env.example
```

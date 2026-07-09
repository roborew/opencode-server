# OpenCode + Twingate + Milvus (unified stack)

Self-contained Docker Compose stack for a headless OpenCode server, Twingate remote access, and Milvus-backed `claude-context` indexing.

**Build and run only from this directory.** Agents, skills, and `opencode.json` are cloned from [github.com/roborew/opencode](https://github.com/roborew/opencode) at image build time. Your local `~/.config/opencode` checkout is never modified.

## What's in the stack

| Service | Role |
|---------|------|
| `opencode-server` | `opencode serve` on `0.0.0.0:4097` |
| `twingate-connector` | Proxies remote clients to `opencode.home.internal:4097` |
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

4. Run post-compose setup (preflight + register projects):

```bash
./scripts/setup.sh
# Or checks only:
./scripts/setup.sh preflight
# Register all mounted git repos without prompts:
./scripts/setup.sh projects local --all --yes
```

5. Verify:

```bash
# Milvus health (when MILVUS_HEALTH_PUBLISH_PORT is set in .env)
curl -sf http://localhost:9091/healthz

# OpenCode (when OPENCODE_PUBLISH_PORT is set in .env)
curl -sf -u "opencode:YOUR_PASSWORD" http://localhost:4097/global/health

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
| `OPENCODE_PUBLISH_PORT` | Host port for OpenCode (default `4097`; avoid `4096` — Kilo) |
| `OPENCODE_APPS_DIR` | Host path mounted at `/workspace/apps` (local: `~/05_Repos/01_PROJECTS/apps`; cloud: e.g. `/data/opencode/apps`) |
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

## Twingate resource (Docker-native — laptop or cloud)

**Goal:** Twingate clients reach OpenCode by a **stable Docker DNS name**, wherever the laptop (or droplet) is. No LAN IP. Same resource works on Mac Docker Desktop and DigitalOcean.

### How it works

```text
Phone / remote client
  → Twingate Client
  → Twingate Connector (container on opencode-net)
  → Docker DNS resolves opencode.home.internal
  → opencode-server:4097
```

The connector and OpenCode share `opencode-net`. Docker’s embedded DNS (`127.0.0.11`) resolves service names and aliases. **Do not set `TWINGATE_DNS` to public resolvers** (e.g. `1.1.1.1`) — that bypasses Docker DNS and breaks internal names.

### Admin Console

1. Remote network: this connector’s network  
2. **Standard resource**  
3. **Address:** `opencode.home.internal` (no `http://`, no port in the address field)  
4. **TCP port:** `4097`  
5. Security policy: Default  
6. Assign to your user/group  

### Connect (phone / Mac / anywhere with Twingate)

```text
http://opencode.home.internal:4097
```

```bash
opencode attach http://opencode.home.internal:4097
# Username: opencode (or OPENCODE_SERVER_USERNAME)
# Password: OPENCODE_SERVER_PASSWORD
```

### Verify from the connector (must be 200 with auth)

```bash
docker compose up -d --build opencode twingate-connector

docker run --rm --network container:twingate-connector curlimages/curl:8.7.1 \
  -sf -u "opencode:YOUR_PASSWORD" http://opencode.home.internal:4097/global/health
```

Also resolvable: `opencode-server` and compose service name `opencode` (same IP). Prefer the FQDN alias for Twingate.

### Ports

| Port | Role |
|------|------|
| **4097** | OpenCode (host publish + container listen) — chosen to avoid Kilo/`4096` |
| 4096 | Leave free for Kilo / other tools |

Set `OPENCODE_PUBLISH_PORT=4097` in `.env` (default in compose).

### Localhost on the Mac

```bash
curl -sf -u "opencode:YOUR_PASSWORD" http://127.0.0.1:4097/global/health
```

LAN IP (`http://192.168.1.71:4097`) still works on the home network but is **not** the Twingate resource — it breaks when the laptop leaves that LAN.

## Post-compose setup

After `docker compose up`, run [`scripts/setup.sh`](scripts/setup.sh). It runs in two phases:

1. **Preflight** — env, container health, workspace mount, Milvus, `gh` auth/scopes, providers, enabled MCPs
2. **Projects** — discover repos, multi-select (or `--all`), register with the OpenCode server

```bash
./scripts/setup.sh                    # preflight, then choose local or github mode
./scripts/setup.sh preflight          # checks only
./scripts/setup.sh projects local     # register git roots from mounted /workspace/apps
./scripts/setup.sh projects github    # clone GH_ORG repos into /workspace/apps, then register
./scripts/setup.sh projects local --all --yes --skip-preflight
```

Flags: `--force` (continue after preflight failures), `--dry-run`, `--host URL`, `--json` (preflight summary), `--include-archived` (github mode).

### Preflight

Checks print `[ok]`, `[warn]`, or `[fail]` with fix hints. Failures block project setup unless `--force`.

| Area | What it checks |
|------|----------------|
| Env | `.env`, `OPENCODE_SERVER_PASSWORD`, optional keys |
| Stack | `opencode-server` running, `/global/health`, workspace mount, Milvus |
| GitHub | `gh auth status`, scopes (`repo`, `read:org`), `GH_ORG` access |
| Providers | `OPENROUTER_API_KEY` or connected providers |
| MCPs | `GET /mcp` for each enabled server (claude-context, docs-mcp-server, OAuth MCPs) |

### MCP OAuth (e.g. Cloudflare)

OAuth MCPs in a headless container cannot use “click here” in the web UI. Preflight flags `needs_auth` and prints:

```bash
docker exec -it opencode-server opencode mcp auth <server-name>
docker exec -it opencode-server opencode mcp debug <server-name>
docker exec opencode-server opencode mcp list
```

Tokens persist in the `opencode-data` volume (`mcp-auth.json`). Preflight can offer to run auth interactively.

### Project modes

**Local** — one mount exposes all nested repos; no per-repo volume mounts needed. The script finds `.git` roots under `/workspace/apps` and registers each selected path (e.g. `/workspace/apps/fidget/fidget-web`).

**GitHub** — requires `GH_TOKEN` + `GH_ORG`. Clones into flat `/workspace/apps/<repo>` (cloud: set `OPENCODE_APPS_DIR=/data/opencode/apps` on the host so clones persist). Re-run is idempotent: existing dirs get `git fetch`, already-registered projects are skipped.

OpenCode registers **git repository roots**, not parent folders. Registration creates a seed session per repo so projects appear in the picker for all clients attaching to this server.

## Project workspace

Apps are mounted at `/workspace/apps` (default host path: `~/05_Repos/01_PROJECTS/apps`). Use `./scripts/setup.sh` to register repos — manual registration is only needed if you skip setup.

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
| OpenRouter "missing authentication header" | Set `OPENROUTER_API_KEY` in `.env` (or configure via server UI `/connect`) |
| docs-mcp-server fails | Set `DOCS_MCP_URL` to a host the container can reach (`host.docker.internal` if on this Mac, or LAN IP) |
| Projects not in picker | Run `./scripts/setup.sh projects local` to register git roots |
| MCP needs auth (Cloudflare etc.) | `docker exec -it opencode-server opencode mcp auth <name>` — see Post-compose setup |
| Twingate can't reach server | Resource = `opencode.home.internal`, TCP `4097`; do **not** set `TWINGATE_DNS` to public DNS; connector + OpenCode on `opencode-net` |
| Port conflict with Kilo | OpenCode uses **4097**; leave 4096 for Kilo |
| Provider auth missing | Fresh `opencode-data` volume — set API keys in `.env`/Infisical or migrate auth data |

## Files

```
.
├── Dockerfile
├── docker-compose.yml
├── scripts/
│   ├── setup.sh                 # Post-compose: preflight + project registration
│   └── lib/                     # opencode-api, preflight, select helpers
├── docker/entrypoint.sh       # Infisical wrapper + merge-config + container defaults
├── docker/merge-config.py     # Deep-merge overrides into cloned opencode.json
├── overrides/opencode.server.json
└── .env.example
```

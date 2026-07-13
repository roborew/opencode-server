# OpenCode + Twingate + Milvus (unified stack)

Self-contained Docker Compose stack for a headless OpenCode server, Twingate remote access, and Milvus-backed `claude-context` indexing.

**Build and run only from this directory.** Agents, skills, and `opencode.json` are cloned from [github.com/roborew/opencode-config](https://github.com/roborew/opencode-config) at image build time (`CONFIG_REPO` / `CONFIG_REF`). Your local `~/.config/opencode` checkout is never mounted into the image.

## Claude Context indexing (host vs Docker)

Semantic indexing is optional — OpenCode works without it; it only speeds discovery. **Do not run host and Docker `claude-context` at the same time.** Desktop loading host MCP while attached to this server can spawn dozens of `npx` processes and freeze the UI.

| Mode | Where indexing runs | What to set |
|------|---------------------|-------------|
| **Desktop / CLI → this Docker server** (recommended with this stack) | Container MCP → Milvus (`COMPOSE_PROFILES=milvus`) | Keep host `mcp.claude-context.enabled` **`false`** in `~/.config/opencode/opencode.json`. Server enables it via [`overrides/opencode.server.json`](overrides/opencode.server.json). |
| **Local only** (no Docker server; Desktop/CLI on the host) | Host MCP in `~/.config/opencode` | Set `mcp.claude-context.enabled` to **`true`** in that checkout. See the [config repo README](https://github.com/roborew/opencode-config#claude-context-indexing-host-vs-docker-server). |

```text
Desktop ──HTTP──► opencode-server :4097 ──► claude-context (container) ──► Milvus
                         ▲
                         └── do NOT also enable host claude-context
```

After changing `CONFIG_REPO` / `CONFIG_REF`, rebuild so the image picks up config: `docker compose build --no-cache opencode && docker compose up -d opencode` (never `down -v`). Diagnose freezes with `./scripts/doctor-perf.sh`.

## What's in the stack

| Service                            | Role                                                    |
| ---------------------------------- | ------------------------------------------------------- |
| `opencode-server`                  | `opencode serve` on `0.0.0.0:4097`                      |
| `twingate-connector`               | Proxies remote clients to `opencode.home.internal:4097` |
| `milvus-standalone` + etcd + minio | Vector store for `claude-context` MCP                   |

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

4. Run post-compose setup (preflight + register/amend projects + hosts):

```bash
./scripts/setup.sh
# Or checks only:
./scripts/setup.sh preflight
# Sync all mounted git repos without prompts:
./scripts/setup.sh projects local --all --yes
# Hosts entry + host-path session cleanup only:
./scripts/setup.sh bootstrap --yes
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

| Variable                           | Purpose                                                                                                          |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `OPENCODE_SERVER_PASSWORD`         | HTTP basic auth for the server                                                                                   |
| `OPENCODE_SERVER_USERNAME`         | Basic auth username (default `opencode`)                                                                         |
| `TWINGATE_*`                       | Connector credentials                                                                                            |
| `OPENAI_API_KEY`                   | Claude Context embeddings                                                                                        |
| `OPENROUTER_API_KEY`               | Model provider (if not in persisted auth volume)                                                                 |
| `GH_TOKEN`, `GH_ORG`, `GH_PROJECT` | GitHub CLI / project board workflows (fine-grained PAT preferred — see below)                                    |
| `CODERABBIT_API_KEY`               | CodeRabbit CLI agent reviews (Agentic API key — see below)                                                       |
| `MILVUS_TOKEN`                     | Milvus auth (default `local` for standalone)                                                                     |
| `CONFIG_REPO`, `CONFIG_REF`        | GitHub config clone at build time                                                                                |
| `COMPOSE_PROFILES`                 | Default `milvus` starts etcd/minio/milvus; clear to run OpenCode without the vector stack                        |
| `OPENCODE_PUBLISH_PORT`            | Host port for OpenCode (default `4097`; avoid `4096` — Kilo)                                                     |
| `OPENCODE_OAUTH_CALLBACK_PUBLISH`  | Host bind for MCP OAuth callback (default `127.0.0.1:19876`)                                                     |
| `OPENCODE_APPS_DIR`                | Host path mounted at `/workspace/apps` (default `${HOME}/projects`; e.g. `~/projects` or `/data/opencode/apps`) |
| `OPENCODE_WORKTREES_DIR`           | Host path for workspace worktrees (default `~/.local/share/opencode/worktree`; chats stay on `opencode-data` volume) |
| `MILVUS_PUBLISH_PORT`              | Host port for Milvus gRPC (empty = not published)                                                                |
| `MILVUS_HEALTH_PUBLISH_PORT`       | Host port for Milvus health endpoint                                                                             |
| `MINIO_API_PUBLISH_PORT`           | Host port for MinIO API                                                                                          |
| `MINIO_CONSOLE_PUBLISH_PORT`       | Host port for MinIO console                                                                                      |
| `DOCKER_HOST_INTERNAL`             | Hostname containers use to reach the Docker host (default `host.docker.internal`)                                |
| `LOCALHOST_REWRITE`                | Rewrite loopback URLs to `DOCKER_HOST_INTERNAL` before tools run (default `1`; set `0` to disable)               |

### Deployed environments (Infisical)

The image includes the Infisical CLI. The entrypoint mirrors [fidget-web/docker/docker-entrypoint.sh](https://github.com/roborew/fidget/blob/main/fidget-web/docker/docker-entrypoint.sh):

- If `INFISICAL_PROJECT_ID` + `INFISICAL_DOMAIN` (or `INFISICAL_API_URL`) + auth are set → `infisical run` injects secrets at runtime.
- Otherwise → uses compose `.env` values directly (local fallback).

**Infisical bootstrap** (set on the host / platform; secrets live in Infisical):

| Variable                                          | Description                                 |
| ------------------------------------------------- | ------------------------------------------- |
| `INFISICAL_PROJECT_ID`                            | Infisical project ID                        |
| `INFISICAL_ENV`                                   | Environment slug (`dev`, `staging`, `prod`) |
| `INFISICAL_DOMAIN` or `INFISICAL_API_URL`         | e.g. `https://eu.infisical.com`             |
| `INFISICAL_CLIENT_ID` + `INFISICAL_CLIENT_SECRET` | Universal Auth machine identity             |
| `INFISICAL_TOKEN`                                 | Alternative to client id/secret             |

Store in Infisical: `TWINGATE_*`, `OPENCODE_SERVER_PASSWORD`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GH_*`, `CODERABBIT_API_KEY`, etc.

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

| Port      | Role                                                                              |
| --------- | --------------------------------------------------------------------------------- |
| **4097**  | OpenCode (host publish + container listen) — chosen to avoid Kilo/`4096`          |
| **19876** | MCP OAuth callback (host `127.0.0.1` only by default; socat → container loopback) |
| 4096      | Leave free for Kilo / other tools                                                 |

Set `OPENCODE_PUBLISH_PORT=4097` in `.env` (default in compose). Override publish bind with `OPENCODE_OAUTH_CALLBACK_PUBLISH` if needed.

### Localhost on the Mac

```bash
curl -sf -u "opencode:YOUR_PASSWORD" http://127.0.0.1:4097/global/health
```

`localhost` reaches the same Docker server. Prefer `http://opencode.home.internal:4097` when you want the same hostname as Twingate clients.

LAN IP (`http://192.168.1.71:4097`) still works on the home network but is **not** the Twingate resource — it breaks when the laptop leaves that LAN.

### Same hostname on the Docker host (FQDN → loopback)

**Why a hosts entry?** On the machine that runs the connector, `opencode.home.internal` often does not resolve in normal apps (even with Twingate connected). Remotes work; the host does not. Mapping the name to loopback lets this Mac use the same URL as phones:

```text
127.0.0.1 opencode.home.internal  →  published host port 4097  →  opencode-server
```

Phones still go: Twingate → VIP → connector → same container.

`./scripts/setup.sh` can add this hosts line (sudo). It does **not** configure or modify OpenCode.app — attach that client to the server later yourself.

```bash
./scripts/setup.sh projects local --all --yes
# Or hosts + session cleanup only:
./scripts/setup.sh bootstrap --yes
```

Manual hosts (if you skipped the prompt):

```bash
sudo sh -c 'echo "127.0.0.1 opencode.home.internal" >> /etc/hosts'
```

## Post-compose setup

After `docker compose up`, run [`scripts/setup.sh`](scripts/setup.sh). It runs in phases:

1. **Preflight** — env, container health, workspace mount, Milvus, `gh` auth (fine-grained or classic), providers, enabled MCPs
2. **Projects (amend)** — choose the **desired** set (re-runs show `[on]`/`[off]`); register adds, deregister removes sessions for dropped repos
3. **Host bootstrap** — `/etc/hosts` for `opencode.home.internal`, delete stray `/Users/...` sessions on the server, print web deep links

```bash
./scripts/setup.sh                    # preflight, then amend local/github set + bootstrap
./scripts/setup.sh preflight          # checks only
./scripts/setup.sh projects local     # amend set from mounted /workspace/apps
./scripts/setup.sh projects github    # clone GH_ORG repos, then amend set
./scripts/setup.sh projects local --all --yes --skip-preflight
./scripts/setup.sh bootstrap --yes    # hosts + session cleanup only
```

Re-run `./scripts/setup.sh` (or `projects local`) anytime to add/remove projects; Enter keeps the current set. `--all` makes the desired set every discovered repo.

Flags: `--force` (continue after preflight failures), `--dry-run`, `--host URL`, `--json` (preflight summary), `--include-archived` (github mode), `--skip-bootstrap`.

Setup never touches OpenCode.app or `~/Library/Application Support/ai.opencode.desktop/`.

### GitHub token (fine-grained PAT)

Prefer a **fine-grained personal access token** (`github_pat_*`) for `GH_TOKEN`. Classic tokens use OAuth scopes (`repo`, `read:org`); fine-grained tokens use repository + organization permissions instead, and `gh auth status` will **not** list classic scopes — that is expected.

Create the token at [GitHub → Settings → Developer settings → Fine-grained tokens](https://github.com/settings/personal-access-tokens). Set **Resource owner** to your org (e.g. `RoborewDev`) or grant **All repositories**.

#### Repository permissions

| Permission        | Access                                   | Purpose                                       |
| ----------------- | ---------------------------------------- | --------------------------------------------- |
| Repository access | All repositories (or selected org repos) | Covers current + future repos the stack needs |
| Metadata          | Read-only (required)                     | Baseline search/list access                   |
| Contents          | Read and write                           | Clone, push, branches, releases               |
| Pull requests     | Read and write                           | Open, review, comment, merge PRs              |
| Issues            | Read and write                           | Issues, comments, labels                      |
| Actions           | Read and write                           | Trigger/view workflows, runs, artifacts       |
| Commit statuses   | Read and write                           | Read/report commit build statuses             |
| Administration    | Read-only                                | View repo settings, teams, collaborators      |

#### Organization permissions

| Permission | Access         | Purpose                                                             |
| ---------- | -------------- | ------------------------------------------------------------------- |
| Members    | Read-only      | Org/team visibility — fine-grained equivalent of classic `read:org` |
| Projects   | Read and write | Org project boards (`GH_PROJECT`)                                   |

#### Classic PAT (optional)

If you use a classic token instead: scopes `repo` and `read:org`.

### CodeRabbit CLI

The image includes the [CodeRabbit CLI](https://docs.coderabbit.ai/cli). The entrypoint authenticates headlessly when `CODERABBIT_API_KEY` is set (same pattern as `GH_TOKEN`).

1. Enable the **Usage-based Add-on** in your CodeRabbit org.
2. Generate an **Agentic API key** at CodeRabbit dashboard → API Keys (regular user keys are not supported).
3. Set `CODERABBIT_API_KEY` in `.env` (or Infisical for deployed environments).

Agents should review local changes with structured JSON output:

```bash
docker exec -w /workspace/apps/<repo> opencode-server coderabbit --agent -t uncommitted
```

Limit to a few runs per change set. Preflight checks `coderabbit auth status` when the key is configured.

### Preflight

Checks print `[ok]`, `[warn]`, or `[fail]` with fix hints. Failures block project setup unless `--force`.

| Area       | What it checks                                                                                                                             |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Env        | `.env`, `OPENCODE_SERVER_PASSWORD`, optional keys                                                                                          |
| Stack      | `opencode-server` running, `/global/health`, workspace mount, Milvus                                                                       |
| GitHub     | `gh auth status`; fine-grained (`github_pat_*`) via capability checks, or classic scopes (`repo`, `read:org`); `GH_ORG` + repo list access |
| CodeRabbit | `coderabbit auth status` when `CODERABBIT_API_KEY` is set                                                                                  |
| Providers  | `OPENROUTER_API_KEY` or connected providers                                                                                                |
| MCPs       | `GET /mcp` for each enabled server (claude-context, docs-mcp-server, OAuth MCPs)                                                           |

### MCP OAuth (e.g. Cloudflare)

OpenCode starts a short-lived callback listener on **`127.0.0.1:19876` inside the container**. The image bridges that to the container eth IP via `socat`, and compose publishes **`127.0.0.1:19876` on the host** (loopback-only — not the public internet).

| Where you run the stack               | How the browser reaches the callback                                                                                                  |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **Local Mac**                         | Open the printed authorize URL; Cloudflare redirects to `http://127.0.0.1:19876/...` on the Mac → Docker → container                  |
| **DigitalOcean (or any remote host)** | From your **laptop**, keep an SSH tunnel open, then auth in that same browser session: `ssh -N -L 19876:127.0.0.1:19876 user@droplet` |

```bash
# On the machine (or via docker exec on the droplet):
docker exec -it opencode-server opencode mcp auth <server-name>
docker exec -it opencode-server opencode mcp debug <server-name>
docker exec opencode-server opencode mcp list
```

Tokens persist in the `opencode-data` volume (`mcp-auth.json`). Preflight can offer to run auth interactively.

After a successful `opencode mcp auth`, the long-running `opencode serve` process may still show `needs_auth` until the MCP transport is reconnected. Preflight does this automatically; manually:

```bash
curl -sf -u "opencode:YOUR_PASSWORD" -X POST http://127.0.0.1:4097/mcp/cloudflare-api/disconnect
curl -sf -u "opencode:YOUR_PASSWORD" -X POST http://127.0.0.1:4097/mcp/cloudflare-api/connect
# or: docker compose restart opencode
```

Do **not** set `OPENCODE_OAUTH_CALLBACK_PUBLISH=0.0.0.0:19876` on a public droplet unless you intentionally expose the OAuth callback port.

#### Cloudflare OAuth permissions (recommended)

On the Cloudflare authorize screen, grant **least privilege**: **DNS Write** is the only write most agent work needs; keep everything else **Read**. Prefer specific zones over “all zones” when the UI allows it.

| Scope / permission                                | Access           | Purpose                                                 |
| ------------------------------------------------- | ---------------- | ------------------------------------------------------- |
| **Zone → DNS**                                    | **Edit** (Write) | Create/update/delete DNS records (A, CNAME, TXT, MX, …) |
| Zone → Zone                                       | Read             | List zones / zone metadata                              |
| Account → Account Settings (or Account Resources) | Read             | Discover account ID / list accounts                     |
| Workers Scripts, KV, R2, D1, Pages, Firewall, …   | Read (optional)  | Inspect config without changing it                      |

**Usually skip (unless you explicitly need them):** Billing, User Admin, Account Edit, Workers Scripts Edit, Firewall Edit, Access Edit, SSL/TLS Edit, Cache Purge — those are high-impact writes.

**Add later if needed:**

| Extra permission          | When                                    |
| ------------------------- | --------------------------------------- |
| Workers Scripts Edit      | Deploy or update Workers from the agent |
| Workers KV / D1 / R2 Edit | Mutate storage from the agent           |
| Page Rules / Cache Purge  | Cache or routing changes                |
| Firewall / WAF Edit       | Security rule changes                   |

Re-run `opencode mcp auth cloudflare-api` after changing scopes (or revoke the prior grant in the Cloudflare dashboard).

### Project modes

**Local** — one mount exposes all nested repos; no per-repo volume mounts needed. The script finds `.git` roots under `/workspace/apps` and registers each selected path (e.g. `/workspace/apps/fidget/fidget-web`).

**GitHub** — requires `GH_TOKEN` + `GH_ORG`. Clones into flat `/workspace/apps/<repo>` (cloud: set `OPENCODE_APPS_DIR=/data/opencode/apps` on the host so clones persist). Re-run is idempotent: existing dirs get `git fetch`, already-registered projects are skipped.

OpenCode registers **git repository roots**, not parent folders. Setup treats your selection as the full desired set: missing repos get a seed session; removed ones have their sessions deleted (there is no separate project-delete API). Workspaces remain a separate, optional choice in any client UI.

## Project workspace

Apps are mounted at `/workspace/apps` (set `OPENCODE_APPS_DIR` in `.env`; compose default `${HOME}/projects`). Use `./scripts/setup.sh` to register repos — manual registration is only needed if you skip setup.

- Good: `/workspace/apps/fidget/fidget-web`
- Bad: `/workspace/apps/fidget`

List discoverable repos inside the container:

```bash
docker exec opencode-server find /workspace/apps -name .git -type d -prune
```

### Workspace worktrees (host-visible)

Set `OPENCODE_WORKTREES_DIR` in `.env` to an **absolute** host path (Docker does not expand `~`).

Compose bind-mounts that host directory onto a **container-canonical** path (`/var/opencode-xdg/opencode/worktree`), and again at the same absolute host path. Apps are mounted at `/workspace/apps` and at `$OPENCODE_APPS_DIR`. OpenCode only creates/registers the container worktree path (no duplicate sandboxes). After create, git worktree metadata is rewritten to host paths so local Git (`git worktree list`, Git GUIs, editors) can resolve them on the host; same-path binds keep git working inside the container.

A path proxy on `:4097` rewrites the container path ↔ `$OPENCODE_WORKTREES_DIR` in API/SSE traffic (including URL-encoded `directory=` query params) so the UI always sees the host path.

Chats/sessions stay on the `opencode-data` Docker volume (mounted at `/var/lib/opencode-data`, linked into the XDG data dir).

## Config updates

| Change                              | Action                                                                              |
| ----------------------------------- | ----------------------------------------------------------------------------------- |
| Agents/skills in `roborew/opencode` | Push to GitHub → `docker compose build --no-cache opencode && docker compose up -d` |
| Container MCP/workspace overrides   | Edit `overrides/opencode.server.json` → rebuild                                     |
| Local CLI config                    | Edit `~/.config/opencode` as usual (unaffected by this stack)                       |

## Local CLI + shared Milvus

When this stack is running, Milvus is published on `localhost:19530`. Your local shell can keep:

```bash
export MILVUS_ADDRESS=http://localhost:19530
export MILVUS_TOKEN=local
```

Local `opencode` and the Docker server can share the same vector index.

## Localhost URLs inside Docker

Inside the container, `localhost` / `127.0.0.1` is the **container**, not your Mac or droplet. Shared links like `http://localhost:3000` would otherwise 404 when OpenCode `webfetch` or shell `curl` runs in Docker.

An OpenCode plugin installed at container startup rewrites loopback URLs to `host.docker.internal` (or `DOCKER_HOST_INTERNAL`) before tools execute. External and LAN URLs are unchanged.

| Setting                | Default                | Purpose                                 |
| ---------------------- | ---------------------- | --------------------------------------- |
| `DOCKER_HOST_INTERNAL` | `host.docker.internal` | Target host for rewritten loopback URLs |
| `LOCALHOST_REWRITE`    | `1`                    | Set to `0` to disable rewriting         |

Compose declares `extra_hosts: host.docker.internal:host-gateway` so Linux and DigitalOcean match Docker Desktop.

**Requirements:** The service must be reachable from the container via the Docker host gateway. Docker Desktop on Mac can usually reach host ports bound to `127.0.0.1`. On Linux, bind the service to `0.0.0.0` or publish the port if `host.docker.internal` cannot reach it.

## Troubleshooting

| Issue                                      | Check                                                                                                                                           |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Container name conflict                    | `docker compose down` in `../twingate` and `../milvus`                                                                                          |
| Build fails on `git clone`                 | Verify `CONFIG_REF` branch exists on GitHub                                                                                                     |
| Config changes not in container            | Server config is cloned at **image build** from `CONFIG_REPO`/`CONFIG_REF`. Rebuild: `docker compose build --no-cache opencode && docker compose up -d opencode`. Do **not** `down -v` (drops sessions). Host `~/.config/opencode` is never mounted. |
| Desktop freezes / high host RAM            | Usually host + Docker `claude-context` both on — see [Claude Context indexing](#claude-context-indexing-host-vs-docker). Quit Desktop, `pkill -f claude-context-mcp`, set host `mcp.claude-context.enabled` to `false`. Run `./scripts/doctor-perf.sh` while glitching. |
| Claude Context fails                       | `OPENAI_API_KEY` set; Milvus healthy on `milvus-standalone:19530` inside network; `COMPOSE_PROFILES=milvus`                                                                      |
| Want lighter stack (no Milvus)             | Clear profile: `COMPOSE_PROFILES= docker compose up -d` (etcd/minio/milvus are under the `milvus` profile). Re-enable with `COMPOSE_PROFILES=milvus`. |
| OpenRouter "missing authentication header" | Set `OPENROUTER_API_KEY` in `.env` (or configure via server UI `/connect`)                                                                      |
| docs-mcp-server fails                      | Set `DOCS_MCP_URL` to a host the container can reach (`host.docker.internal` if on this Mac, or LAN IP)                                         |
| localhost link 404 from agent              | Loopback rewrite is on by default; ensure the service is reachable from Docker via `host.docker.internal`; set `LOCALHOST_REWRITE=0` to disable |
| Projects not in picker                     | Run `./scripts/setup.sh projects local`; open via printed deep links or `+` with `/workspace/apps/...`                                          |
| Host cannot resolve opencode.home.internal | `./scripts/setup.sh bootstrap` or add `127.0.0.1 opencode.home.internal` to `/etc/hosts`                                                        |
| MCP needs auth (Cloudflare etc.)           | Publish `127.0.0.1:19876`; on DO use `ssh -L 19876:127.0.0.1:19876`; then `docker exec -it opencode-server opencode mcp auth <name>`            |
| Twingate can't reach server                | Resource = `opencode.home.internal`, TCP `4097`; do **not** set `TWINGATE_DNS` to public DNS; connector + OpenCode on `opencode-net`            |
| Port conflict with Kilo                    | OpenCode uses **4097**; leave 4096 for Kilo                                                                                                     |
| Provider auth missing                      | Fresh `opencode-data` volume — set API keys in `.env`/Infisical or migrate auth data                                                            |
| Sessions missing after compose change      | Ensure `opencode-data` is still the named volume at `/var/lib/opencode-data` — never replace it with a host bind or use `docker compose down -v` |
| Local Git client cannot find worktree      | Recreate the workspace after enabling `OPENCODE_WORKTREES_DIR`; old worktrees used `/root/...` paths                                            |
| Duplicate workspace entries (same name)    | Rebuild image (single container path + path proxy). Confirm absolute `OPENCODE_WORKTREES_DIR`. Hard-refresh the client once after upgrade. |

## Files

```
.
├── Dockerfile
├── docker-compose.yml
├── scripts/
│   ├── setup.sh                 # Post-compose: preflight + project sync + hosts
│   ├── doctor-perf.sh           # Host MCP leak / docker stats / Desktop app-data snapshot
│   └── lib/                     # opencode-api, preflight, select, client-bootstrap helpers
├── docker/entrypoint.sh       # Infisical wrapper + merge-config + container defaults
├── docker/merge-config.py     # Deep-merge overrides into cloned opencode.json
├── docker/plugins/            # OpenCode plugins (localhost → host.docker.internal)
├── overrides/
│   ├── README.md              # Host vs server claude-context (indexing) control
│   └── opencode.server.json   # MCP/workspace overrides merged at container start
├── .env.example
```

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
| `twingate-connector`               | Proxies remote clients to `OPENCODE_FQDN:4097` (default `opencode.local`) |
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
| `GIT_USER_NAME`, `GIT_USER_EMAIL`  | Git author/committer for agent commits in the container (sets `user.*` + `GIT_AUTHOR_*` / `GIT_COMMITTER_*`)     |
| `CODERABBIT_API_KEY`               | CodeRabbit CLI agent reviews (Agentic API key — see below)                                                       |
| `MILVUS_TOKEN`                     | Milvus auth (default `local` for standalone)                                                                     |
| `CONFIG_REPO`, `CONFIG_REF`        | GitHub config clone at build time                                                                                |
| `COMPOSE_PROFILES`                 | Default `milvus` starts etcd/minio/milvus; clear to run OpenCode without the vector stack                        |
| `OPENCODE_PUBLISH_PORT`            | Host port for OpenCode (default `4097`; avoid `4096` — Kilo)                                                     |
| `OPENCODE_OAUTH_CALLBACK_PUBLISH`  | Host bind for MCP OAuth callback (default `127.0.0.1:19876`)                                                     |
| `OPENCODE_APPS_DIR`                | Host path for git repos — same-path bind (default `${HOME}/projects`; absolute path required)                    |
| `OPENCODE_WORKTREES_DIR`           | Host worktree dir ending in `/opencode/worktree` (default `~/.local/share/opencode/worktree`; chats on `opencode-data`) |
| `MILVUS_PUBLISH_PORT`              | Host port for Milvus gRPC (empty = not published)                                                                |
| `MILVUS_HEALTH_PUBLISH_PORT`       | Host port for Milvus health endpoint                                                                             |
| `MINIO_API_PUBLISH_PORT`           | Host port for MinIO API                                                                                          |
| `MINIO_CONSOLE_PUBLISH_PORT`       | Host port for MinIO console                                                                                      |
| `DOCKER_HOST_INTERNAL`             | Hostname containers use to reach the Docker host (default `host.docker.internal`)                                |
| `LOCALHOST_REWRITE`                | Rewrite loopback URLs to `DOCKER_HOST_INTERNAL` before tools run (default `1`; set `0` to disable)               |

### Deployed environments (Infisical)

The image includes the Infisical CLI. The entrypoint wraps the server with Infisical when configured:

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

Store in Infisical: `TWINGATE_*`, `OPENCODE_SERVER_PASSWORD`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GH_*`, `GIT_USER_NAME`, `GIT_USER_EMAIL`, `CODERABBIT_API_KEY`, etc.

Set `INFISICAL_USE_CLI=false` to force local `.env` only.

## Twingate resource (Docker-native — laptop or cloud)

**Goal:** Twingate clients reach OpenCode by a **stable Docker DNS name**, wherever the laptop (or droplet) is. No LAN IP. Same resource works on Docker Desktop or Cloud.

### How it works

```text
Phone / remote client
  → Twingate Client
  → Twingate Connector (container on opencode-net)
  → Docker DNS resolves OPENCODE_FQDN (default opencode.local)
  → opencode-server:4097
```

The connector and OpenCode share `opencode-net`. Docker’s embedded DNS (`127.0.0.11`) resolves service names and aliases. **Do not set `TWINGATE_DNS` to public resolvers** (e.g. `1.1.1.1`) — that bypasses Docker DNS and breaks internal names.

### Admin Console

1. Remote network: this connector’s network
2. **Standard resource**
3. **Address:** your `OPENCODE_FQDN` (default `opencode.local`; no `http://`, no port in the address field)
4. **TCP port:** `4097`
5. Security policy: Default
6. Assign to your user/group

### Connect (phone / Mac / anywhere with Twingate)

```text
http://opencode.local:4097
```

```bash
opencode attach http://opencode.local:4097
# Username: opencode (or OPENCODE_SERVER_USERNAME)
# Password: OPENCODE_SERVER_PASSWORD
```

### Verify from the connector (must be 200 with auth)

```bash
docker compose up -d --build opencode twingate-connector

docker run --rm --network container:twingate-connector curlimages/curl:8.7.1 \
  -sf -u "opencode:YOUR_PASSWORD" http://opencode.local:4097/global/health
```

Also resolvable: `opencode-server` and compose service name `opencode` (same IP). Prefer the FQDN alias for Twingate.

### Ports

| Port      | Role                                                                              |
| --------- | --------------------------------------------------------------------------------- |
| **4097**  | OpenCode (host publish + container listen) — chosen to avoid Kilo/`4096`          |
| **19876** | MCP OAuth callback (host `127.0.0.1` only by default; socat → container loopback) |
| 4096      | Leave free for Kilo / other tools                                                 |

Set `OPENCODE_PUBLISH_PORT=4097` in `.env` (default in compose). Override publish bind with `OPENCODE_OAUTH_CALLBACK_PUBLISH` if needed.

### Localhost on the Docker host

```bash
curl -sf -u "opencode:YOUR_PASSWORD" http://127.0.0.1:4097/global/health
```

`localhost` reaches the same Docker server. Prefer `http://opencode.local:4097` (or your `OPENCODE_FQDN`) when you want the same hostname as Twingate clients.

A raw LAN IP still works on that network but is **not** the Twingate resource — it breaks when the client leaves that LAN.

### Same hostname on the Docker host (FQDN → loopback)

**Why a hosts entry?** On the machine that runs the connector, `OPENCODE_FQDN` often does not resolve in normal apps (even with Twingate connected). Remotes work; the host does not. Mapping the name to loopback lets the Docker host use the same URL as remotes:

```text
127.0.0.1 opencode.local  →  published host port 4097  →  opencode-server
```

Remotes still go: Twingate → VIP → connector → same container.

`./scripts/setup.sh` can add this hosts line (sudo). It does **not** configure or modify OpenCode.app — attach that client to the server later yourself.

```bash
./scripts/setup.sh projects local --all --yes
# Or hosts + session cleanup only:
./scripts/setup.sh bootstrap --yes
```

Manual hosts (if you skipped the prompt):

```bash
sudo sh -c 'echo "127.0.0.1 opencode.local" >> /etc/hosts'
```

## Post-compose setup

After `docker compose up`, run [`scripts/setup.sh`](scripts/setup.sh). It runs in phases:

1. **Preflight** — env, container health, workspace mount, Milvus, `gh` auth (fine-grained or classic), providers, enabled MCPs
2. **Projects (amend)** — choose the **desired** set (re-runs show `[on]`/`[off]`); register adds, deregister removes sessions for dropped repos
3. **Host bootstrap** — `/etc/hosts` for `OPENCODE_FQDN`, delete stray `/Users/...` sessions on the server, print web deep links

```bash
./scripts/setup.sh                    # preflight, then amend local/github set + bootstrap
./scripts/setup.sh preflight          # checks only
./scripts/setup.sh projects local     # amend set from mounted OPENCODE_APPS_DIR
./scripts/setup.sh projects github    # clone GH_ORG repos, then amend set
./scripts/setup.sh projects local --all --yes --skip-preflight
./scripts/setup.sh bootstrap --yes    # hosts + session cleanup only
```

Re-run `./scripts/setup.sh` (or `projects local`) anytime to add/remove projects; Enter keeps the current set. `--all` makes the desired set every discovered repo.

Flags: `--force` (continue after preflight failures), `--dry-run`, `--host URL`, `--json` (preflight summary), `--include-archived` (github mode), `--skip-bootstrap`.

Setup never touches OpenCode.app or `~/Library/Application Support/ai.opencode.desktop/`.

### GitHub token (fine-grained PAT)

Prefer a **fine-grained personal access token** (`github_pat_*`) for `GH_TOKEN`. Classic tokens use OAuth scopes (`repo`, `read:org`); fine-grained tokens use repository + organization permissions instead, and `gh auth status` will **not** list classic scopes — that is expected.

Create the token at [GitHub → Settings → Developer settings → Fine-grained tokens](https://github.com/settings/personal-access-tokens). Set **Resource owner** to your org (e.g. `your-org`) or grant **All repositories**.

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
docker exec -w "$OPENCODE_APPS_DIR/<repo>" opencode-server coderabbit --agent -t uncommitted
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

**Preferred path:** keep OpenCode Desktop closed, run `./scripts/setup.sh` (or `./scripts/setup.sh preflight`), and answer **y** when preflight offers `Authenticate mcp/cloudflare-api`. That writes tokens into the Docker `opencode-data` volume and reconnects the server — Desktop then shows Cloudflare connected. Desktop’s in-app Cloudflare click is unreliable against this Docker server; use setup.

OpenCode starts a short-lived callback listener on **`127.0.0.1:19876` inside the container**. The image bridges that to the container eth IP via `socat`, and compose publishes **`127.0.0.1:19876` on the host** (loopback-only — not the public internet).

| Where you run the stack               | How the browser reaches the callback                                                                                                  |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **Local Docker host**                 | Open the printed authorize URL; Cloudflare redirects to `http://127.0.0.1:19876/...` on that host → Docker → container               |
| **Remote host (e.g. VPS)**            | From your **laptop**, keep an SSH tunnel open, then auth in that same browser session: `ssh -N -L 19876:127.0.0.1:19876 user@host`   |

```bash
# Prefer setup/preflight (sets XDG + clears stuck OAuth state):
./scripts/setup.sh preflight

# Manual equivalent (XDG must match serve — compose sets this; pass -e if unsure):
docker exec -it -e XDG_DATA_HOME=/var/opencode-xdg opencode-server opencode mcp auth <server-name>
docker exec -e XDG_DATA_HOME=/var/opencode-xdg opencode-server opencode mcp debug <server-name>
docker exec -e XDG_DATA_HOME=/var/opencode-xdg opencode-server opencode mcp list
```

Tokens persist in the `opencode-data` volume (`mcp-auth.json` under container `XDG_DATA_HOME=/var/opencode-xdg`). Preflight runs auth with that XDG, clears incomplete PKCE state, and restarts the container if `opencode serve` is already holding `:19876` (otherwise the browser callback hits the wrong process → “Invalid or expired state parameter”).

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

**Usually skip (unless you explicitly need them):** Billing, User Admin, Account Edit, Workers Scripts Edit, Firewall Edit, Access Edit, SSL/TLS Edit, Cache Purge, **Tunnel Create/Edit** (host cloudflared is enough for review URLs) — those are high-impact writes.

**Add later if needed:**

| Extra permission          | When                                    |
| ------------------------- | --------------------------------------- |
| Workers Scripts Edit      | Deploy or update Workers from the agent |
| Workers KV / D1 / R2 Edit | Mutate storage from the agent           |
| Page Rules / Cache Purge  | Cache or routing changes                |
| Firewall / WAF Edit       | Security rule changes                   |

Re-run after changing scopes:

```bash
./scripts/setup.sh mcp-auth cloudflare-api
```

Or revoke the prior grant in the Cloudflare dashboard, then re-auth.

### Project modes

**Local** — one same-path mount exposes all nested repos; no per-repo volume mounts needed. The script finds `.git` roots under `$OPENCODE_APPS_DIR`, ensures each selected repo is on `OPENCODE_WORK_BRANCH` (default `develop`) when that remote branch exists, and registers each selected path (e.g. `/Users/you/projects/my-app/my-app-web`).

**GitHub** — requires `GH_TOKEN` + `GH_ORG`. Lists org repos, you pick which to keep/clone into flat `$OPENCODE_APPS_DIR/<repo>` (cloud: set `OPENCODE_APPS_DIR=/data/opencode/apps` on the host so clones persist). After clone/update, checkouts land on `OPENCODE_WORK_BRANCH` (default `develop`) when that remote branch exists. Re-run is idempotent: existing dirs get `git fetch` + work-branch checkout; already-registered projects are skipped.

OpenCode registers **git repository roots**, not parent folders. Setup treats your selection as the full desired set: missing repos get a seed session; removed ones have their sessions deleted (there is no separate project-delete API). Workspaces remain a separate, optional choice in any client UI.

## Project workspace

Apps are same-path mounted at `$OPENCODE_APPS_DIR` (set in `.env`; compose default `${HOME}/projects`). Use `./scripts/setup.sh` to register repos — manual registration is only needed if you skip setup.

- Good: `/Users/you/projects/my-app/my-app-web`
- Bad: `/Users/you/projects/my-app` (parent folder, not a git root)

List discoverable repos inside the container:

```bash
docker exec opencode-server find "$OPENCODE_APPS_DIR" -name .git -type d -prune
```

### Workspace worktrees (host paths for Desktop / Tower)

Set `OPENCODE_WORKTREES_DIR` in `.env` to an **absolute** host path ending in `/opencode/worktree` (Docker does not expand `~`). Desktop default: `~/.local/share/opencode/worktree`.

Compose bind-mounts that host directory onto `/var/opencode-xdg/opencode/worktree` (OpenCode create path) and again at the same host path so Tower / local Git see checkouts. Apps are same-path mounted at `$OPENCODE_APPS_DIR` only. Server DB/sessions/MCP auth live on the `opencode-data` named volume (not Desktop `~/.local/share`).

After creating a worktree via Desktop, git link files are rewritten to host paths (`$OPENCODE_APPS_DIR` + `$OPENCODE_WORKTREES_DIR`) so Tower / local Git can open them. Verify:

```bash
# gitdir in the main repo must point under OPENCODE_WORKTREES_DIR (not /var/opencode-xdg)
grep -r . "$OPENCODE_APPS_DIR/<repo>/.git/worktrees/"*/gitdir

# worktree .git must point under OPENCODE_APPS_DIR
cat "$OPENCODE_WORKTREES_DIR"/…/<name>/.git

git -C "$OPENCODE_APPS_DIR/<repo>" worktree list
# should list the host worktree path, not "prunable"
```

Chats/sessions stay on the `opencode-data` Docker volume. Wipe server state:

```bash
./scripts/wipe-opencode-data.sh --yes
# Clean E2E / after path migrations (Desktop must be quit):
./scripts/wipe-opencode-data.sh --yes --desktop
```

That removes the named volume (DB/auth). `--desktop` also clears this server’s open-project list in OpenCode Desktop (macOS). It does **not** delete repos or host worktrees.
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

## Optional Sysbox sibling sandboxes (Ubuntu)

**Mac / default:** leave `OPENCODE_SANDBOX_MODE=off` (the `.env.example` default). The stack is unchanged — no `docker.sock` mount, no Sysbox. Agents cannot run nested Compose; that is expected.

**Ubuntu:** install Sysbox, set `OPENCODE_SANDBOX_MODE=auto` (or `on`), run setup, build the sandbox image, restart compose with the sandbox overlay. Agents then use the `sandbox` CLI to create ephemeral Sysbox siblings that run each repo’s own Docker Compose build/test stack.

### Mode flag

| `OPENCODE_SANDBOX_MODE` | Behavior |
| ----------------------- | -------- |
| `off` (default) | Current Mac-safe stack. No socket, no sibling sandboxes. |
| `auto` | Setup probes for `sysbox-runc`. If present → enable; else warn and stay off. |
| `on` | Require Sysbox; setup fails if the probe fails. |

Setup writes `OPENCODE_SANDBOX_ENABLED=0|1` and, when enabling, sets:

```bash
COMPOSE_FILE=docker-compose.yml:docker-compose.sandbox.yml
```

That overlay mounts `/var/run/docker.sock` into OpenCode **only** so the `sandbox` CLI can create/exec/destroy **sibling** containers with `--runtime=sysbox-runc`. Nested app Compose runs inside the sibling’s own Docker daemon — never pass the host socket into app stacks.

### Install Sysbox on the Ubuntu host

Package-based install for a standalone Docker host (not the Kubernetes DaemonSet route). See [Sysbox install-package](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install-package.md) and [distro-compat](https://github.com/nestybox/sysbox/blob/master/docs/distro-compat.md).

**Pre-checks**:

```bash
uname -r              # 5.12+; well-tested 5.15–6.5 LTS
lsb_release -a
docker --version      # note this — see "time-namespace workaround" below
```

**Install** (restarts Docker — drain workloads first):

```bash
# Disruptive: schedule a maintenance window
docker rm $(docker ps -a -q) -f

sudo apt-get install jq wget -y
# Verify current Sysbox CE version on Nestybox downloads before pinning.
# 0.7.0 verified on this host (Ubuntu 24.04 HWE 7.0.0-28, Docker Engine 29.6.2).
wget https://downloads.nestybox.com/sysbox/releases/v0.7.0/sysbox-ce_0.7.0-0.linux_amd64.deb
sha256sum sysbox-ce_0.7.0-0.linux_amd64.deb
# expected: eeff273671467b8fa351ab3d40709759462dc03d9f7b50a1b207b37982ce40a9
sudo apt-get install ./sysbox-ce_0.7.0-0.linux_amd64.deb

sudo systemctl status sysbox -n20    # active, sysbox-runc/mgr/fs 0.7.0
sudo systemctl restart docker        # daemon picks up the sysbox-runc runtime
docker info --format '{{json .Runtimes}}'   # sysbox-runc present alongside runc
```

**Time-namespace workaround (Docker Engine ≥ 29.5.0)**

Docker 29.5.0+ injects a private `time` namespace into every container's OCI spec by default, which sysbox-runc 0.7.0 (and 0.6.x) does not yet handle — the result is:

```
OCI runtime create failed: namespace {"time" ""} does not exist
```

Open issue: [nestybox/sysbox#1011](https://github.com/nestybox/sysbox/issues/1011). Disable the feature flag globally so docker stops emitting the namespace:

```bash
sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
sudo python3 -c 'import json; p="/etc/docker/daemon.json"; d=json.load(open(p)); d.setdefault("features",{})["time-namespaces"]=False; json.dump(d, open(p,"w"), indent=4)'
sudo systemctl restart docker
```

This is a global docker setting, so every container on the host loses Docker's default time-namespace handling (only affects the inner container's view of clocks; clock skew between host and containers remains visible). Restore by removing the `features.time-namespaces` key from `daemon.json` and restarting docker.

**Smoke Sysbox:**

```bash
docker run --runtime=sysbox-runc --rm -it --hostname=sbox-test alpine sh -c 'echo ok; id; uname -a'
# expect: ok; uid=0(root); kernel string matches the host
```

**Caveats**

- **Docker ≥ 29.5.0 + time namespaces:** see the workaround above. Until sysbox ships support, do **not** remove the `features.time-namespaces: false` setting.
- **GPU / NVIDIA:** Sysbox has no official GPU passthrough like `nvidia-container-toolkit` ([nestybox/sysbox#50](https://github.com/nestybox/sysbox/issues/50)). Do not assume CUDA inside sandboxes.
- **Docker + Kubernetes on the same box:** Sysbox sits beside `runc` after install; the disruptive moment is the Docker daemon restart during `.deb` install.

### Enable in this stack

```bash
# .env
OPENCODE_SANDBOX_MODE=auto   # or on

./scripts/setup.sh sandbox
# or: ./scripts/setup.sh preflight

docker compose build opencode
./scripts/sandbox/build-image.sh
docker compose up -d

# Smoke (create → nested compose test → destroy)
./scripts/sandbox/smoke-test.sh
```

### Agent CLI contract

Inside the OpenCode container (when enabled):

```bash
sandbox probe
sandbox create --id feat-slug --worktree /absolute/path/to/repo
sandbox exec --id feat-slug -- docker compose -f docker-compose.test.yml run --rm test
sandbox status --id feat-slug
sandbox destroy --id feat-slug
sandbox expose --id feat-slug --port 3000 --hostname feat-slug.example.com
sandbox unexpose --id feat-slug
```

Exit code `2` / JSON `"reason":"SANDBOX_UNAVAILABLE"` means sandboxes are off — treat as a soft skip unless the stage explicitly requires Compose.

OpenCode config skill: [`docs/opencode-config-docker-sandbox-prompt.md`](docs/opencode-config-docker-sandbox-prompt.md) (also live in `roborew/opencode` as `skills/docker-sandbox`).

### Review URLs (Phase 2) — existing Traefik + host Cloudflare Tunnel

**One host tunnel is enough.** Install **`cloudflared` via apt/CLI on Ubuntu** (preferred over Docker cloudflared). Point that tunnel at Traefik. Then any number of zones/subdomains can CNAME to the tunnel; Traefik routes by `Host()`.

Do **not** add cloudflared to this compose stack. Do **not** create a tunnel per feature branch.

**Host setup (link out):**

1. Confirm Traefik already routes other containers on a shared Docker network.
2. [Install cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) (Linux package).
3. [Create a tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/create-remote-tunnel/) and [run as a service](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/local-management/as-a-service/).
4. [Configure](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/) ingress / public hostname to Traefik.
5. [DNS to tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/routing-to-tunnel/) — apex and/or `*.apex` wildcards; otherwise the agent upserts `{feature}.{apex}` when `OPENCODE_SANDBOX_REVIEW_DNS=on`.

**This stack env (sandbox overlay):**

```bash
OPENCODE_SANDBOX_TRAEFIK_NETWORK=traefik   # must match Traefik’s Docker network
OPENCODE_SANDBOX_TRAEFIK_ENTRYPOINT=websecure
# OPENCODE_SANDBOX_TRAEFIK_CERTRESOLVER=  # optional
OPENCODE_SANDBOX_REVIEW_DNS=on
```

Hostname pattern: **`{feature-slug}.{app-apex-domain}`** (e.g. `blockshed.blockshared.com`). Skill supplies `--hostname`; nested compose must **publish** the app port on the sibling.

```bash
sandbox expose --id blockshed --port 3000 --hostname blockshed.blockshared.com
# → host route helper + Traefik labels; DNS via cloudflare-api MCP when REVIEW_DNS=on
sandbox unexpose --id blockshed
sandbox destroy --id blockshed   # unexpose first
```

**Cloudflare MCP scopes:** Zone **DNS Edit** for review hostnames. Re-auth after changing scopes:

```bash
./scripts/setup.sh mcp-auth cloudflare-api
```

Do not require Tunnel Create/Edit for this workflow (host tunnel is already running).

### App Infisical / `.env` for sandbox builds

OpenCode server Infisical (`infisical run` in the entrypoint) does **not** inject secrets into Sysbox sibling builds. Each app repo needs its own **`.env`** on the mounted path (visible inside the sibling).

**Setup** (`projects local|github`): for each selected repo, if `.env` is missing, offer to **create** it and **paste** vars (Infisical + anything else). Never copy from `.env.example`. Preflight warns when repos lack `.env` or Infisical key names.

```bash
./scripts/setup.sh projects local
# … create .env + paste KEY=value lines, end with a line containing only: .
```

### Phase summary

| Build/test | Web review |
| ---------- | ---------- |
| Sysbox sibling + repo Compose | Route helper + Traefik labels + existing tunnel |
| Needs per-repo `.env` (Infisical) | Hostname `{feature}.{apex}`; DNS optional via MCP |

## Troubleshooting

| Issue                                      | Check                                                                                                                                           |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Container name conflict                    | `docker compose down` in `../twingate` and `../milvus`                                                                                          |
| Build fails on `git clone`                 | Verify `CONFIG_REF` branch exists on GitHub                                                                                                     |
| Config changes not in container            | Server config is cloned at **image build** from `CONFIG_REPO`/`CONFIG_REF`. Rebuild: `docker compose build --no-cache opencode && docker compose up -d opencode`. Do **not** `down -v` (drops sessions). Host `~/.config/opencode` is never mounted. |
| Desktop freezes / high host RAM            | Usually host + Docker `claude-context` both on — see [Claude Context indexing](#claude-context-indexing-host-vs-docker). Quit Desktop, `pkill -f claude-context-mcp`, set host `mcp.claude-context.enabled` to `false`. Run `./scripts/doctor-perf.sh` while glitching. |
| Claude Context fails                       | `OPENAI_API_KEY` set; Milvus healthy on `milvus-standalone:19530` inside network; `COMPOSE_PROFILES=milvus`                                                                      |
| Want lighter stack (no Milvus)             | Clear profile: `COMPOSE_PROFILES= docker compose up -d` (etcd/minio/milvus are under the `milvus` profile). Re-enable with `COMPOSE_PROFILES=milvus`. |
| Workspace create/delete times out     | Ensure `OPENCODE_EXPERIMENTAL_WORKSPACES=true` (compose default). Without it, OpenCode never emits `workspace.status` and the API fails after 5s. Rebuild/restart after changing. |
| Deleting a “sandbox” wiped the app repo | Delete-guard blocks DELETE under `OPENCODE_APPS_DIR`; only worktree-store paths are removable. |
| docs-mcp-server fails                      | Set `DOCS_MCP_URL` to a host the container can reach (`host.docker.internal` if on the Docker host, or LAN IP)                                  |
| localhost link 404 from agent              | Loopback rewrite is on by default; ensure the service is reachable from Docker via `host.docker.internal`; set `LOCALHOST_REWRITE=0` to disable |
| Projects not in picker                     | Run `./scripts/setup.sh projects local`; open via printed deep links or `+` with `$OPENCODE_APPS_DIR/...`                                         |
| Host cannot resolve OPENCODE_FQDN          | `./scripts/setup.sh bootstrap` or add `127.0.0.1 opencode.local` (or your FQDN) to `/etc/hosts`                                                  |
| MCP needs auth (Cloudflare etc.)           | Close Desktop; `./scripts/setup.sh preflight` and auth when prompted. Manual: `docker exec -it -e XDG_DATA_HOME=/var/opencode-xdg opencode-server opencode mcp auth <name>` then reconnect `/mcp/<name>/connect`. CSRF/state errors ⇒ serve held `:19876` or stale PKCE — re-run preflight (it clears + restarts). |
| Twingate can't reach server                | Resource = `OPENCODE_FQDN` (default `opencode.local`), TCP `4097`; do **not** set `TWINGATE_DNS` to public DNS; connector + OpenCode on `opencode-net` |
| Port conflict with Kilo                    | OpenCode uses **4097**; leave 4096 for Kilo                                                                                                     |
| Provider auth missing                      | Fresh `opencode-data` volume — set API keys in `.env`/Infisical or migrate auth data                                                            |
| Sessions missing after compose change      | Ensure `opencode-data` is still the named volume at `/var/lib/opencode-data` — never replace it with a host bind or use `docker compose down -v` |
| Local Git / Tower worktree disconnected    | Recreate the workspace after same-path upgrade; confirm gitdir/.git use `$OPENCODE_APPS_DIR` and `$OPENCODE_WORKTREES_DIR` only                 |
| Old workspace won't open                   | Re-run `projects local` and recreate that workspace on `$OPENCODE_APPS_DIR` paths                                                              |
| Sandbox probe unavailable on Mac           | Expected — leave `OPENCODE_SANDBOX_MODE=off`. Sysbox siblings are Ubuntu-only.                                                                 |
| Sandbox mode=on but setup fails            | Install Sysbox CE (see "Install Sysbox on the Ubuntu host"); confirm `sysbox-runc` in `docker info` runtimes; re-run `./scripts/setup.sh sandbox`                                              |
| `namespace {"time" ""} does not exist`     | Docker ≥ 29.5.0 injecting a time namespace; apply the `features.time-namespaces: false` workaround under "Time-namespace workaround" above ([nestybox/sysbox#1011](https://github.com/nestybox/sysbox/issues/1011)) |
| Sandbox enabled but no sock in container   | Ensure `COMPOSE_FILE` includes `docker-compose.sandbox.yml`, then `docker compose up -d`                                                      |
| Sandbox image missing                      | `./scripts/sandbox/build-image.sh` (tags `OPENCODE_SANDBOX_IMAGE`, default `opencode-sandbox:local`)                                           |
| Expose: Traefik network not found          | Set `OPENCODE_SANDBOX_TRAEFIK_NETWORK` to Traefik’s Docker network name; recreate OpenCode with sandbox overlay                                |
| Repo sandbox build lacks secrets           | `./scripts/setup.sh projects local` — create `.env` + paste Infisical vars (not `.env.example`)                                                |
| Cloudflare DNS write denied                | `./scripts/setup.sh mcp-auth cloudflare-api` and grant Zone DNS Edit                                                                           |

## Files

```
.
├── Dockerfile
├── docker-compose.yml
├── docker-compose.sandbox.yml   # Optional overlay (socket + ENABLED=1); Mac never loads by default
├── scripts/
│   ├── setup.sh                 # sandbox configure + mcp-auth + preflight + projects + .env paste
│   ├── doctor-perf.sh
│   ├── sandbox/
│   │   ├── sandbox              # probe|create|exec|status|destroy|expose|unexpose
│   │   ├── build-image.sh
│   │   └── smoke-test.sh
│   └── lib/                     # opencode-api, preflight, sandbox-enable, repo-env, …
├── docker/
│   ├── entrypoint.sh
│   ├── sandbox/
│   │   ├── Dockerfile
│   │   └── fixtures/compose-smoke/
│   ├── merge-config.py
│   └── plugins/
├── docs/
│   └── opencode-config-docker-sandbox-prompt.md
├── overrides/
│   ├── README.md
│   └── opencode.server.json
├── .env.example
```
